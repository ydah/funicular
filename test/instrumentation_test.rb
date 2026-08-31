class InstrumentationPicoTest < Picotest::Test
  class Adapter
    attr_reader :calls

    def initialize
      @calls = []
    end

    def start(span, parent_state)
      @calls << [:start, span.name, parent_state]
      span.id
    end

    def finish(state, span)
      @calls << [:finish, state, span.status]
    end

    def event(event)
      @calls << [:event, event.name, event.parent_id]
    end
  end

  class FilterAdapter
    attr_reader :names

    def initialize(allowed)
      @allowed = allowed
      @names = []
    end

    def enabled?(name)
      @names << name
      @allowed
    end
  end

  class ActivationAdapter
    def initialize(name, calls)
      @name = name
      @calls = calls
      @invocation = 0
    end

    def start(_span, _parent)
      @name
    end

    def activate(_state)
      @invocation += 1
      token = "#{@name}-#{@invocation}"
      @calls << [:activate, token]
      token
    end

    def deactivate(token)
      @calls << [:deactivate, token]
    end
  end

  class BrokenAdapter
    attr_reader :attempts

    def initialize
      @attempts = 0
    end

    def start(_span, _parent)
      @attempts += 1
      raise "broken"
    end
  end

  class HeaderAdapter
    def inject_http_headers(_state, headers, _url)
      headers["Traceparent"] = "adapter"
      headers["tracestate"] = "vendor=value"
    end
  end

  def setup
    Funicular::Instrumentation.__reset
    $instrumentation_tick = 0
    Funicular::Instrumentation.clock = proc do
      $instrumentation_tick += 10
    end
    @adapter = Adapter.new
    Funicular::Instrumentation.register(:pico, @adapter)
  end

  def teardown
    Funicular::Instrumentation.__reset
  end

  def test_nested_span_and_event_lifecycle
    parent = Funicular::Instrumentation.start("parent")
    Funicular::Instrumentation.with_span(parent) do
      child = Funicular::Instrumentation.start("child")
      Funicular::Instrumentation.with_span(child) do
        Funicular::Instrumentation.event("inside")
      end
      Funicular::Instrumentation.finish(child)
      assert_equal(parent.id, child.parent_id)
    end
    Funicular::Instrumentation.finish(parent)

    child_start = @adapter.calls.select do |call|
      call[0] == :start && call[1] == "child"
    end[0]
    assert_equal(parent.id, child_start[2])
    assert_equal(:ok, parent.status)
    assert_equal(true, parent.finished?)
    assert_equal(40, parent.ended_at_us - parent.started_at_us)
    assert_equal(nil, Funicular::Instrumentation.current_span)
  end

  def test_no_adapter_does_not_read_clock
    Funicular::Instrumentation.__reset
    calls = 0
    Funicular::Instrumentation.clock = proc { calls += 1 }

    assert_equal(nil, Funicular::Instrumentation.start("disabled"))
    assert_equal(0, calls)
  end

  def test_instrument_preserves_return_and_error
    assert_equal(7, Funicular::Instrumentation.instrument("ok") { 7 })
    assert_raise(ArgumentError) do
      Funicular::Instrumentation.instrument("bad") { raise ArgumentError, "boom" }
    end
  end

  def test_registry_filter_duplicate_and_unregister
    Funicular::Instrumentation.__reset
    rejected = FilterAdapter.new(false)
    Funicular::Instrumentation.register(:filter, rejected)

    assert_equal(true, Funicular::Instrumentation.registered?(:filter))
    assert_equal(false, Funicular::Instrumentation.enabled?("hidden"))
    assert_equal(["hidden"], rejected.names)
    assert_raise(ArgumentError) do
      Funicular::Instrumentation.register(:filter, rejected)
    end

    Funicular::Instrumentation.unregister(:filter)
    assert_equal(false, Funicular::Instrumentation.registered?(:filter))
  end

  def test_double_finish_and_error_finish
    span = Funicular::Instrumentation.start("once")
    error = ArgumentError.new("boom")
    Funicular::Instrumentation.finish(span, nil, error: error)
    Funicular::Instrumentation.finish(span)

    finishes = @adapter.calls.select { |call| call[0] == :finish }
    assert_equal(1, finishes.length)
    assert_equal(:error, span.status)
    assert_equal(error, span.error)
  end

  def test_with_span_restores_and_deactivates_in_reverse_with_fresh_tokens
    Funicular::Instrumentation.__reset
    calls = []
    Funicular::Instrumentation.register(:first, ActivationAdapter.new("first", calls))
    Funicular::Instrumentation.register(:second, ActivationAdapter.new("second", calls))
    span = Funicular::Instrumentation.start("work")

    assert_raise(RuntimeError) do
      Funicular::Instrumentation.with_span(span) { raise RuntimeError, "failed" }
    end
    assert_equal(nil, Funicular::Instrumentation.current_span)
    Funicular::Instrumentation.with_span(span) { nil }

    assert_equal([
      [:activate, "first-1"], [:activate, "second-1"],
      [:deactivate, "second-1"], [:deactivate, "first-1"],
      [:activate, "first-2"], [:activate, "second-2"],
      [:deactivate, "second-2"], [:deactivate, "first-2"]
    ], calls)
  end

  def test_failure_isolation_circuit_breaker_and_multiple_adapters
    Funicular::Instrumentation.__reset
    Funicular::Instrumentation.reporter = proc { |_message| nil }
    broken = BrokenAdapter.new
    healthy = Adapter.new
    Funicular::Instrumentation.register(:broken, broken)
    Funicular::Instrumentation.register(:healthy, healthy)

    4.times { Funicular::Instrumentation.start("work") }

    diagnostic = Funicular::Instrumentation.diagnostics[0]
    assert_equal(true, diagnostic[:disabled])
    assert_equal(3, diagnostic[:failures])
    assert_equal(4, healthy.calls.select { |call| call[0] == :start }.length)
  end

  def test_silence_reentrancy_and_header_collision
    Funicular::Instrumentation.__reset
    starts = []
    adapter = Object.new
    adapter.define_singleton_method(:start) do |_span, _parent|
      starts << :start
      Funicular::Instrumentation.start("nested")
    end
    Funicular::Instrumentation.register(:reentrant, adapter)
    Funicular::Instrumentation.start("outer")
    assert_equal([:start], starts)

    Funicular::Instrumentation.__reset
    Funicular::Instrumentation.register(:headers, HeaderAdapter.new)
    span = Funicular::Instrumentation.start("http")
    headers = { "traceparent" => "existing" }
    Funicular::Instrumentation.inject_http_headers(span, headers, "/posts")
    assert_equal("existing", headers["traceparent"])
    assert_equal(false, headers.key?("Traceparent"))
    assert_equal("vendor=value", headers["tracestate"])

    Funicular::Instrumentation.silence do
      assert_equal(nil, Funicular::Instrumentation.start("silenced"))
      assert_equal(nil, Funicular::Instrumentation.event("silenced"))
    end
  end
end
