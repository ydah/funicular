# frozen_string_literal: true

require_relative "test_helper"

class SSRInstrumentationTest < Minitest::Test
  APP_DIR = File.expand_path("fixtures/funicular_app", __dir__)

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
    Funicular::SSR::Runtime.reset_app!
    Funicular::Instrumentation.__reset
    @adapter = Adapter.new
    Funicular::Instrumentation.register(:test, @adapter)
  end

  def teardown
    Funicular::Instrumentation.__reset
  end

  def test_route_render_records_safe_attributes
    result = Funicular::SSR.render(path: "/greet", source_dir: APP_DIR)
    span = @adapter.spans.find { |item| item.name == "funicular.ssr.render" }

    assert_includes result[:html], "Default Title"
    assert_equal "route", span.attributes["funicular.ssr.mode"]
    assert_equal true, span.attributes["funicular.route.matched"]
    assert_equal "GreetingComponent", span.attributes["funicular.component.class"]
    refute span.attributes.key?("path")
  end

  def test_unmatched_route_finishes_normally
    result = Funicular::SSR.render(path: "/private/raw/path", source_dir: APP_DIR)
    span = @adapter.spans.find { |item| item.name == "funicular.ssr.render" }

    assert_equal "", result[:html]
    assert_equal false, span.attributes["funicular.route.matched"]
    assert_equal :ok, span.status
  end

  def test_component_render_records_class
    html = Funicular::SSR.render_component("GreetingComponent", source_dir: APP_DIR)
    span = @adapter.spans.find { |item| item.name == "funicular.ssr.render" }

    assert_includes html, "Default Title"
    assert_equal "component", span.attributes["funicular.ssr.mode"]
    assert_equal "GreetingComponent", span.attributes["funicular.component.class"]
  end

  def test_component_resolution_error_finishes_the_span_with_the_original_error
    error = assert_raises(NameError) do
      Funicular::SSR.render_component("MissingInstrumentationComponent", source_dir: APP_DIR)
    end
    span = @adapter.spans.find { |item| item.name == "funicular.ssr.render" }

    assert_same error, span.error
    assert_equal :error, span.status
    assert_equal "component", span.attributes["funicular.ssr.mode"]
  end
end
