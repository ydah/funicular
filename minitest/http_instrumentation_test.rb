# frozen_string_literal: true

require_relative "test_helper"

module JS; end unless defined?(JS)

class HTTPInstrumentationTest < Minitest::Test
  class Adapter
    attr_reader :finished, :events, :injected_headers

    def initialize
      @finished = []
      @events = []
    end

    def start(span, _parent_state)
      span
    end

    def finish(_state, span)
      @finished << span
    end

    def event(event)
      @events << event
    end

    def inject_http_headers(_state, headers, _url)
      headers["traceparent"] = "injected"
      @injected_headers = headers
    end
  end

  HeaderBag = Struct.new(:epoch) do
    def get(_name)
      epoch
    end
  end

  FetchResponse = Struct.new(:status, :body, :headers) do
    def [](key)
      key == :headers ? headers : nil
    end

    def to_binary
      body
    end
  end

  class FetchGlobal
    attr_reader :calls

    def initialize(response: nil, error: nil)
      @response = response
      @error = error
      @calls = []
    end

    def fetch(url, options)
      @calls << [url, options]
      raise @error if @error
      yield @response
    end
  end

  def setup
    Funicular::SSR::Runtime.load_framework!
    Funicular::Instrumentation.__reset
    Funicular::Instrumentation.reporter = ->(_message) {}
    @adapter = Adapter.new
    Funicular::Instrumentation.register(:test, @adapter)
  end

  def teardown
    Funicular::Instrumentation.__reset
  end

  def with_request_stubs(global, terminated: false, epoch_ok: true, &block)
    original_verbose = $VERBOSE
    original_global = JS.method(:global) if JS.respond_to?(:global)
    original_terminated = Funicular::DB.method(:session_terminated?)
    original_epoch = Funicular::DB.method(:__session_epoch_ok?)
    $VERBOSE = nil
    JS.define_singleton_method(:global) { global }
    Funicular::DB.define_singleton_method(:session_terminated?) { terminated }
    Funicular::DB.define_singleton_method(:__session_epoch_ok?) { |_value| epoch_ok }
    block.call
  ensure
    if original_global
      JS.define_singleton_method(:global) { original_global.call }
    elsif JS.respond_to?(:global)
      JS.singleton_class.send(:remove_method, :global)
    end
    Funicular::DB.define_singleton_method(:session_terminated?) { original_terminated.call }
    Funicular::DB.define_singleton_method(:__session_epoch_ok?) { |value| original_epoch.call(value) }
    $VERBOSE = original_verbose
  end

  def test_response_finish_and_callback_context
    span = Funicular::Instrumentation.start(
      "funicular.http.request", nil, { "http.request.method" => "GET" }
    )
    response = Funicular::HTTP::Response.new(204, nil)
    Funicular::HTTP.send(:finish_http_span, span, response, "response")
    current = nil

    Funicular::HTTP.send(:deliver_response, span, "GET", "/safe", response) do
      current = Funicular::Instrumentation.current_span
    end

    assert_same span, current
    assert_equal 204, span.attributes["http.response.status_code"]
    assert_equal "response", span.attributes["funicular.http.result"]
    refute span.attributes.key?("url")
    assert_equal 1, @adapter.finished.length
  end

  def test_callback_error_emits_event_and_preserves_exception
    span = Funicular::Instrumentation.start("funicular.http.request")
    response = Funicular::HTTP::Response.new(200, {})
    Funicular::HTTP.send(:finish_http_span, span, response, "response")

    _out, _err = capture_io do
      error = assert_raises(ArgumentError) do
        Funicular::HTTP.send(:deliver_response, span, "GET", "/safe", response) do
          raise ArgumentError, "callback bug"
        end
      end
      assert_equal "callback bug", error.message
    end

    event = @adapter.events.last
    assert_equal "funicular.error", event.name
    assert_equal span.id, event.parent_id
    assert_equal "http_callback", event.attributes["funicular.error.source"]
    assert_equal "ArgumentError", event.attributes["error.type"]
    assert_equal 1, @adapter.finished.length
  end

  def test_request_injects_headers_and_finishes_a_response_once
    broken = Object.new
    broken.define_singleton_method(:inject_http_headers) do |_state, headers, _url|
      headers["broken-trace"] = "must-not-leak"
      raise "broken adapter"
    end
    Funicular::Instrumentation.register(:broken, broken)
    response = FetchResponse.new(201, '{"ok":true}', HeaderBag.new("same"))
    global = FetchGlobal.new(response: response)
    delivered = []
    callback_parent = nil

    with_request_stubs(global) do
      Funicular::HTTP.get("/private?token=secret") do |item|
        delivered << item
        callback_parent = Funicular::Instrumentation.current_span
      end
    end

    assert_equal 1, delivered.length
    assert_equal "injected", global.calls.first[1][:headers]["traceparent"]
    refute global.calls.first[1][:headers].key?("broken-trace")
    span = @adapter.finished.last
    assert_same span, callback_parent
    assert_equal "response", span.attributes["funicular.http.result"]
    assert_equal 201, span.attributes["http.response.status_code"]
    refute_includes span.attributes.values, "/private?token=secret"
  end

  def test_request_classifies_session_change_network_error_and_terminal_refusal
    response = FetchResponse.new(500, 'not json', HeaderBag.new("changed"))
    response_global = FetchGlobal.new(response: response)
    parsed = nil
    with_request_stubs(response_global) do
      Funicular::HTTP.get("/http-error") { |item| parsed = item }
    end
    assert_equal "response", @adapter.finished.last.attributes["funicular.http.result"]
    assert_equal 500, parsed.status
    assert_equal "not json", parsed.data

    changed_global = FetchGlobal.new(response: response)
    changed = nil
    with_request_stubs(changed_global, epoch_ok: false) do
      Funicular::HTTP.get("/changed") { |item| changed = item }
    end
    assert_equal "session_changed", @adapter.finished.last.attributes["funicular.http.result"]
    assert_equal 0, changed.status

    failed_global = FetchGlobal.new(error: IOError.new("offline"))
    failed = nil
    with_request_stubs(failed_global) do
      Funicular::HTTP.get("/failed") { |item| failed = item }
    end
    assert_equal "network_error", @adapter.finished.last.attributes["funicular.http.result"]
    assert_equal :error, @adapter.finished.last.status
    assert_equal 0, failed.status

    terminal_global = FetchGlobal.new
    terminal = nil
    with_request_stubs(terminal_global, terminated: true) do
      Funicular::HTTP.get("/terminal") { |item| terminal = item }
    end
    assert_equal "session_terminated", @adapter.finished.last.attributes["funicular.http.result"]
    assert_equal 0, terminal.status
    assert_empty terminal_global.calls
  end

  def test_body_serialization_error_finishes_and_settles_once_without_fetching
    global = FetchGlobal.new
    cyclic = {}
    cyclic["self"] = cyclic
    delivered = []

    with_request_stubs(global) do
      Funicular::HTTP.post("/serialize", cyclic) { |item| delivered << item }
    end

    assert_equal 1, delivered.length
    assert_equal 0, delivered.first.status
    assert_empty global.calls
    span = @adapter.finished.last
    assert_equal "network_error", span.attributes["funicular.http.result"]
    assert_equal :error, span.status
    assert_equal 1, @adapter.finished.length
  end

  def test_callback_raise_is_not_reclassified_as_a_network_error
    response = FetchResponse.new(200, '{}', HeaderBag.new("same"))
    global = FetchGlobal.new(response: response)

    _out, _err = capture_io do
      error = assert_raises(ArgumentError) do
        with_request_stubs(global) do
          Funicular::HTTP.get("/callback") { raise ArgumentError, "callback bug" }
        end
      end
      assert_equal "callback bug", error.message
    end

    assert_equal 1, @adapter.finished.length
    assert_equal "response", @adapter.finished.first.attributes["funicular.http.result"]
    assert_equal :ok, @adapter.finished.first.status
    assert_equal "http_callback", @adapter.events.last.attributes["funicular.error.source"]
  end
end
