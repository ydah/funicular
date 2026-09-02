# frozen_string_literal: true

require_relative "test_helper"
require_relative "../mrblib/instrumentation"

class InstrumentationTest < Minitest::Test
  Adapter = Struct.new(:calls, :enabled) do
    def enabled?(name)
      calls << [:enabled, name]
      enabled != false
    end

    def start(span, parent_state)
      calls << [:start, span.name, parent_state]
      "state-#{span.id}"
    end

    def finish(state, span)
      calls << [:finish, state, span.status]
    end

    def activate(state)
      calls << [:activate, state]
      "token-#{state}"
    end

    def deactivate(token)
      calls << [:deactivate, token]
    end

    def event(event)
      calls << [:event, event.name, event.parent_id]
    end

    def inject_http_headers(_state, headers, _url)
      headers["Traceparent"] = "new"
      headers["tracestate"] = "vendor=value"
    end
  end

  def setup
    Funicular::Instrumentation.__reset
    @ticks = [100, 175, 200, 260, 300]
    Funicular::Instrumentation.clock = -> { @ticks.shift }
    Funicular::Instrumentation.reporter = ->(_message) {}
  end

  def teardown
    Funicular::Instrumentation.__reset
  end

  def test_no_adapter_skips_clock_and_span_allocation
    calls = 0
    Funicular::Instrumentation.clock = -> { calls += 1 }

    assert_nil Funicular::Instrumentation.start("none")
    assert_equal 0, calls
  end

  def test_registry_duplicate_order_filter_and_unregister
    order = []
    first = Object.new
    first.define_singleton_method(:enabled?) { |name| order << [:first, name]; true }
    second = Object.new
    second.define_singleton_method(:enabled?) { |name| order << [:second, name]; false }

    Funicular::Instrumentation.register(:first, first)
    Funicular::Instrumentation.register(:second, second)
    assert Funicular::Instrumentation.registered?(:first)
    assert_raises(ArgumentError) { Funicular::Instrumentation.register(:first, first) }
    assert Funicular::Instrumentation.enabled?("work")
    assert_equal [[:first, "work"]], order

    Funicular::Instrumentation.unregister(:first)
    refute Funicular::Instrumentation.registered?(:first)
    refute Funicular::Instrumentation.enabled?("work")
    assert_equal [:second, "work"], order.last
  end

  def test_lifecycle_parent_state_context_and_event
    calls = []
    adapter = Adapter.new(calls, true)
    Funicular::Instrumentation.register(:probe, adapter)

    parent = Funicular::Instrumentation.start("parent", nil, { "a" => 1 })
    result = Funicular::Instrumentation.with_span(parent) do
      child = Funicular::Instrumentation.start("child")
      Funicular::Instrumentation.with_span(child) do
        Funicular::Instrumentation.event("inside")
      end
      Funicular::Instrumentation.finish(child)
      :returned
    end
    Funicular::Instrumentation.finish(parent, { "a" => 2 })

    assert_equal :returned, result
    assert_equal 2, calls.find { |call| call[0] == :event }[2]
    assert_includes calls, [:start, "child", "state-#{parent.id}"]
    assert_equal 2, parent.attributes["a"]
    assert_equal :ok, parent.status
    assert_equal 200, parent.ended_at_us - parent.started_at_us
    assert_nil Funicular::Instrumentation.current_span
    assert_operator calls.index([:activate, "state-#{parent.id}"]), :<,
                    calls.index([:deactivate, "token-state-#{parent.id}"])
  end

  def test_instrument_preserves_result_and_original_error
    adapter = Adapter.new([], true)
    Funicular::Instrumentation.register(:probe, adapter)

    assert_equal 42, Funicular::Instrumentation.instrument("ok") { 42 }
    error = assert_raises(ArgumentError) do
      Funicular::Instrumentation.instrument("bad") { raise ArgumentError, "boom" }
    end
    assert_equal "boom", error.message
    failed = adapter.calls.reverse.find { |call| call[0] == :finish }
    assert_equal :error, failed[2]
  end

  def test_with_span_restores_on_raise_and_deactivates_in_reverse_with_fresh_tokens
    calls = []
    build = ->(name) do
      adapter = Object.new
      invocation = 0
      adapter.define_singleton_method(:start) { |_span, _parent| name }
      adapter.define_singleton_method(:activate) do |_state|
        invocation += 1
        token = "#{name}-#{invocation}"
        calls << [:activate, token]
        token
      end
      adapter.define_singleton_method(:deactivate) { |token| calls << [:deactivate, token] }
      adapter
    end
    Funicular::Instrumentation.register(:first, build.call("first"))
    Funicular::Instrumentation.register(:second, build.call("second"))
    span = Funicular::Instrumentation.start("work")

    assert_raises(RuntimeError) do
      Funicular::Instrumentation.with_span(span) { raise "block failed" }
    end
    assert_nil Funicular::Instrumentation.current_span
    Funicular::Instrumentation.with_span(span) { nil }

    assert_equal [
      [:activate, "first-1"], [:activate, "second-1"],
      [:deactivate, "second-1"], [:deactivate, "first-1"],
      [:activate, "first-2"], [:activate, "second-2"],
      [:deactivate, "second-2"], [:deactivate, "first-2"]
    ], calls
  end

  def test_adapter_callback_cannot_reenter_instrumentation
    starts = 0
    adapter = Object.new
    adapter.define_singleton_method(:start) do |_span, _parent|
      starts += 1
      Funicular::Instrumentation.start("nested")
    end
    Funicular::Instrumentation.register(:probe, adapter)

    Funicular::Instrumentation.start("outer")

    assert_equal 1, starts
  end

  def test_double_finish_is_a_no_op
    adapter = Adapter.new([], true)
    Funicular::Instrumentation.register(:probe, adapter)
    span = Funicular::Instrumentation.start("once")
    Funicular::Instrumentation.finish(span)
    Funicular::Instrumentation.finish(span)

    assert_equal 1, adapter.calls.count { |call| call[0] == :finish }
  end

  def test_header_injection_preserves_existing_case_insensitively
    adapter = Adapter.new([], true)
    Funicular::Instrumentation.register(:probe, adapter)
    span = Funicular::Instrumentation.start("http")
    headers = { "traceparent" => "existing" }

    Funicular::Instrumentation.inject_http_headers(span, headers, "/posts")

    assert_equal "existing", headers["traceparent"]
    assert_equal "vendor=value", headers["tracestate"]
    refute headers.key?("Traceparent")
  end

  def test_header_injection_is_optional_origin_aware_and_failure_isolated
    assert_equal({}, Funicular::Instrumentation.inject_http_headers(nil, {}))

    broken = Object.new
    broken.define_singleton_method(:inject_http_headers) do |_state, headers, _url|
      headers["broken-trace"] = "must-not-leak"
      raise "broken"
    end
    allowed = Object.new
    allowed.define_singleton_method(:inject_http_headers) do |_state, headers, url|
      headers["traceparent"] = "allowed" if url.start_with?("/")
    end
    later = Object.new
    later.define_singleton_method(:inject_http_headers) do |_state, headers, url|
      headers["Traceparent"] = "later" if url.start_with?("/")
      headers["tracestate"] = "later-state"
    end
    Funicular::Instrumentation.register(:broken, broken)
    Funicular::Instrumentation.register(:allowed, allowed)
    Funicular::Instrumentation.register(:later, later)
    span = Funicular::Instrumentation.start("http")

    cross_origin = {}
    Funicular::Instrumentation.inject_http_headers(span, cross_origin, "https://example.com")
    refute cross_origin.key?("broken-trace")
    refute cross_origin.key?("traceparent")
    refute cross_origin.key?("Traceparent")
    assert_equal "later-state", cross_origin["tracestate"]

    same_origin = {}
    Funicular::Instrumentation.inject_http_headers(span, same_origin, "/posts")
    assert_equal "allowed", same_origin["traceparent"]
    refute same_origin.key?("Traceparent")
    assert_equal "later-state", same_origin["tracestate"]
  end

  def test_adapter_failure_isolated_and_circuit_breaker_resets_on_success
    broken = Object.new
    attempts = 0
    broken.define_singleton_method(:enabled?) do |_name|
      attempts += 1
      raise "broken" if attempts != 2
      true
    end
    healthy = Adapter.new([], true)
    Funicular::Instrumentation.register(:broken, broken)
    Funicular::Instrumentation.register(:healthy, healthy)

    4.times { Funicular::Instrumentation.start("work") }

    assert_equal 4, healthy.calls.count { |call| call[0] == :start }
    diagnostic = Funicular::Instrumentation.diagnostics.first
    assert_equal false, diagnostic[:disabled]
    assert_equal 2, diagnostic[:failures]
  end

  def test_repeated_failure_of_one_hook_disables_only_that_adapter
    broken = Object.new
    broken.define_singleton_method(:start) { |_span, _parent| raise "broken" }
    healthy = Adapter.new([], true)
    Funicular::Instrumentation.register(:broken, broken)
    Funicular::Instrumentation.register(:healthy, healthy)

    4.times { Funicular::Instrumentation.start("work") }

    diagnostic = Funicular::Instrumentation.diagnostics.first
    assert_equal true, diagnostic[:disabled]
    assert_equal 3, diagnostic[:failures]
    assert_equal 4, healthy.calls.count { |call| call[0] == :start }
  end

  def test_failures_from_alternating_hooks_disable_the_adapter
    broken = Object.new
    broken.define_singleton_method(:start) { |_span, _parent| raise "start broke" }
    broken.define_singleton_method(:finish) { |_state, _span| raise "finish broke" }
    healthy = Adapter.new([], true)
    Funicular::Instrumentation.register(:broken, broken)
    Funicular::Instrumentation.register(:healthy, healthy)

    first = Funicular::Instrumentation.start("first")
    Funicular::Instrumentation.finish(first)
    Funicular::Instrumentation.start("second")

    diagnostic = Funicular::Instrumentation.diagnostics.first
    assert_equal true, diagnostic[:disabled]
    assert_equal 3, diagnostic[:failures]
    assert_equal :start, diagnostic[:last_hook]
  end

  def test_activation_failure_does_not_skip_block_or_other_adapter
    calls = []
    broken_deactivations = []
    broken = Object.new
    broken.define_singleton_method(:activate) { |_state| raise "broken" }
    broken.define_singleton_method(:deactivate) { |token| broken_deactivations << token }
    healthy = Adapter.new(calls, true)
    Funicular::Instrumentation.register(:broken, broken)
    Funicular::Instrumentation.register(:healthy, healthy)
    span = Funicular::Instrumentation.start("work")

    ran = Funicular::Instrumentation.with_span(span) { :yes }

    assert_equal :yes, ran
    assert_empty broken_deactivations
    assert_includes calls, [:activate, "state-#{span.id}"]
    assert_includes calls, [:deactivate, "token-state-#{span.id}"]
  end

  def test_deactivation_failure_preserves_the_block_error_and_other_adapter_cleanup
    calls = []
    healthy = Object.new
    healthy.define_singleton_method(:activate) { |_state| calls << :healthy_activate; :healthy }
    healthy.define_singleton_method(:deactivate) { |token| calls << [:healthy_deactivate, token] }
    broken = Object.new
    broken.define_singleton_method(:activate) { |_state| calls << :broken_activate; :broken }
    broken.define_singleton_method(:deactivate) do |token|
      calls << [:broken_deactivate, token]
      raise "deactivate failed"
    end
    Funicular::Instrumentation.register(:healthy, healthy)
    Funicular::Instrumentation.register(:broken, broken)
    span = Funicular::Instrumentation.start("work")
    original = ArgumentError.new("block failed")

    raised = assert_raises(ArgumentError) do
      Funicular::Instrumentation.with_span(span) { raise original }
    end

    assert_same original, raised
    assert_equal [
      :healthy_activate, :broken_activate,
      [:broken_deactivate, :broken], [:healthy_deactivate, :healthy]
    ], calls
    assert_nil Funicular::Instrumentation.current_span
  end

  def test_server_context_is_thread_local
    Funicular::SSR::Runtime.load_framework!
    adapter = Adapter.new([], true)
    Funicular::Instrumentation.register(:probe, adapter)
    span = Funicular::Instrumentation.start("parent")
    seen = nil

    Funicular::Instrumentation.with_span(span) do
      thread = Thread.new { seen = Funicular::Instrumentation.current_span }
      thread.join
      assert_same span, Funicular::Instrumentation.current_span
    end

    assert_nil seen
  end

  def test_silence_prevents_reentrant_instrumentation
    adapter = Adapter.new([], true)
    Funicular::Instrumentation.register(:probe, adapter)

    Funicular::Instrumentation.silence do
      refute Funicular::Instrumentation.enabled?("nested")
      assert_nil Funicular::Instrumentation.start("nested")
      assert_nil Funicular::Instrumentation.event("nested")
    end
  end

  def test_attributes_reject_objects_at_the_boundary
    Funicular::Instrumentation.register(:probe, Adapter.new([], true))
    error = assert_raises(ArgumentError) do
      Funicular::Instrumentation.start("bad", nil, { "secret" => Object.new })
    end
    assert_match(/unsupported instrumentation attribute/, error.message)
  end
end
