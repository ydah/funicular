# frozen_string_literal: true

require_relative "test_helper"

class BootInstrumentationTest < Minitest::Test
  class Adapter
    attr_reader :spans

    def initialize
      @spans = []
    end

    def start(span, _parent_state)
      span
    end

    def finish(_state, span)
      @spans << span
    end
  end

  def setup
    Funicular::SSR::Runtime.load_framework!
    Funicular::Instrumentation.__reset
    @adapter = Adapter.new
    Funicular::Instrumentation.register(:test, @adapter)
  end

  def teardown
    Funicular::Instrumentation.__reset
    Funicular::SSR::Runtime.reset_app!
  end

  def test_server_start_records_boot_without_browser_work
    result = Funicular.start do |router|
      router.get("/", to: Class.new(Funicular::Component))
    end
    span = @adapter.spans.find { |item| item.name == "funicular.boot" }

    assert_instance_of Funicular::Router, result
    assert_equal false, span.attributes["funicular.local_database.enabled"]
    assert_equal "started", span.attributes["funicular.boot.result"]
    assert_equal :ok, span.status
  end

  def test_server_start_survives_filter_change_before_span_creation
    checks = 0
    adapter = Object.new
    adapter.define_singleton_method(:enabled?) do |_name|
      checks += 1
      checks == 1
    end
    Funicular::Instrumentation.unregister(:test)
    Funicular::Instrumentation.register(:test, adapter)

    result = Funicular.start do |router|
      router.get("/", to: Class.new(Funicular::Component))
    end

    assert_instance_of Funicular::Router, result
    assert_equal 2, checks
  end
end
