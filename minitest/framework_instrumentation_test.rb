# frozen_string_literal: true

require "test_helper"

module JS
  class Object
    def self.removeEventListener(_callback_id); end
  end

  class Element < Object; end

  class << self
    attr_accessor :document
  end
end

Funicular::SSR::Runtime.load_framework!

class FrameworkInstrumentationTest < Minitest::Test
  class Nodes < JS::Object
    def initialize(items)
      @items = items
    end

    def to_a
      @items
    end
  end

  class TextNode < JS::Object
    attr_accessor :parent_element

    def initialize(content)
      @content = content
    end

    def parentElement
      @parent_element
    end
  end

  class Element < JS::Element
    attr_accessor :parent_element
    attr_reader :tag, :nodes

    def initialize(tag)
      @tag = tag.to_s
      @nodes = []
      @attributes = {}
      @next_listener_id = 0
    end

    def [](key)
      case key.to_s
      when "tagName" then @tag.upcase
      when "childNodes" then Nodes.new(@nodes)
      when "firstElementChild" then @nodes.find { |node| node.is_a?(Element) }
      else @attributes[key.to_s]
      end
    end

    def []=(key, value)
      @attributes[key.to_s] = value
    end

    def children
      Nodes.new(@nodes.select { |node| node.is_a?(Element) })
    end

    def parentElement
      @parent_element
    end

    def parentNode
      @parent_element
    end

    def appendChild(child)
      @nodes << child
      child.parent_element = self
      child
    end

    def removeChild(child)
      @nodes.delete(child)
      child.parent_element = nil
      child
    end

    def replaceChild(fresh, stale)
      @nodes[@nodes.index(stale)] = fresh
      fresh.parent_element = self
      stale.parent_element = nil
      fresh
    end

    def insertBefore(fresh, reference)
      index = @nodes.index(reference) || @nodes.length
      @nodes.insert(index, fresh)
      fresh.parent_element = self
      fresh
    end

    def setAttribute(key, value)
      @attributes[key.to_s] = value
    end

    def removeAttribute(key)
      @attributes.delete(key.to_s)
    end

    def addEventListener(_name)
      @next_listener_id += 1
    end
  end

  class Document
    def createElement(tag)
      Element.new(tag)
    end

    def createTextNode(content)
      TextNode.new(content)
    end

    def [](_key)
      nil
    end
  end

  class Adapter
    attr_reader :started, :finished, :events

    def initialize(disabled = [])
      @disabled = disabled
      @started = []
      @finished = []
      @events = []
    end

    def enabled?(name)
      !@disabled.include?(name)
    end

    def start(span, _parent_state)
      @started << span
      span.id
    end

    def finish(_state, span)
      @finished << span
    end

    def event(event)
      @events << event
    end
  end

  class RouteComponent
    attr_accessor :runtime

    def initialize(_params); end
    def seed_state(_state); self; end
    def mount(_container); end
    def unmount; end
  end

  class HydrateFailureRouteComponent < Funicular::Component
    class << self
      attr_accessor :fail_hydrate, :mount_count
    end

    def render
      if self.class.fail_hydrate
        self.class.fail_hydrate = false
        raise RuntimeError, "hydrate failed"
      end
      div { "recovered" }
    end

    def mount(container)
      self.class.mount_count = self.class.mount_count.to_i + 1
      super
    end
  end

  def setup
    JS.document = Document.new
    Funicular::Instrumentation.__reset
    @tick = 0
    Funicular::Instrumentation.clock = -> { @tick += 1 }
    @adapter = Adapter.new
    Funicular::Instrumentation.register(:test, @adapter)
  end

  def teardown
    Funicular::Instrumentation.__reset
  end

  def component_class(stable: false, error: nil)
    Class.new(Funicular::Component) do
      define_method(:initialize_state) { { count: 0, secret: "never-record-me" } }
      define_method(:render) do
        raise error if error
        div { stable ? "stable" : state[:count].to_s }
      end
    end
  end

  def span(name)
    @adapter.finished.reverse.find { |item| item.name == name }
  end

  def test_mount_and_update_form_one_privacy_safe_span_tree
    component = component_class.new(secret_prop: "also-private")
    component.mount(Element.new("main"))

    mount = span("funicular.component.mount")
    render = span("funicular.component.render")
    assert_equal mount.id, render.parent_id
    assert_equal 0, mount.attributes["funicular.component.child_count"]

    component.patch(count: 1)

    update = span("funicular.component.update")
    names = %w[funicular.component.render funicular.vdom.diff funicular.dom.patch]
    names.each { |name| assert_equal update.id, span(name).parent_id }
    rebinds = @adapter.finished.select { |item| item.name == "funicular.events.rebind" }
    assert_equal %w[cleanup bind], rebinds.map { |item| item.attributes["funicular.events.phase"] }
    rebinds.each { |item| assert_equal update.id, item.parent_id }
    assert_equal 0, rebinds.last.attributes["funicular.event_listener.count"]
    assert_equal "state_patch", update.attributes["funicular.update.reason"]
    assert_equal 1, update.attributes["funicular.update.changed_key_count"]
    assert_equal false, update.attributes["funicular.diff.empty"]
    assert_equal 1, update.attributes["funicular.patch.count"]
    refute @adapter.finished.flat_map { |item| item.attributes.values }.include?("never-record-me")
    refute @adapter.finished.flat_map { |item| item.attributes.values }.include?("also-private")
  end

  def test_lifecycle_order_is_unchanged
    calls = []
    klass = component_class
    klass.define_method(:component_will_mount) { calls << :will_mount }
    klass.define_method(:component_mounted) { calls << :mounted }
    klass.define_method(:component_will_update) { calls << :will_update }
    klass.define_method(:component_updated) { calls << :updated }
    original_render = klass.instance_method(:render)
    klass.define_method(:render) do
      calls << :render
      original_render.bind_call(self)
    end
    component = klass.new

    component.mount(Element.new("main"))
    component.patch(count: 1)

    assert_equal %i[will_mount render mounted will_update render updated], calls
  end

  def test_suspense_callback_update_uses_suspense_reason
    klass = component_class
    klass.use_suspense(
      :item,
      ->(resolve, _reject) { resolve.call("loaded") },
      on_resolve: ->(_value) { patch(count: 1) }
    )

    klass.new.mount(Element.new("main"))

    assert_equal "suspense_resolve", span("funicular.component.update").attributes["funicular.update.reason"]
  end

  def test_empty_update_skips_dom_patch_and_reports_zero
    component = component_class(stable: true).new
    component.mount(Element.new("main"))
    patch_finishes = @adapter.finished.count { |item| item.name == "funicular.dom.patch" }

    component.patch(unused: true)

    update = span("funicular.component.update")
    assert_equal true, update.attributes["funicular.diff.empty"]
    assert_equal 0, update.attributes["funicular.patch.count"]
    assert_equal patch_finishes, @adapter.finished.count { |item| item.name == "funicular.dom.patch" }
  end

  def test_render_error_is_preserved_on_the_render_span
    error = ArgumentError.new("render failed")
    raised = assert_raises(ArgumentError) { component_class(error: error).new.build_vdom }

    assert_same error, raised
    assert_same error, span("funicular.component.render").error
    assert_equal :error, span("funicular.component.render").status
  end

  def test_mount_lifecycle_error_is_preserved_and_reported_once
    error = RuntimeError.new("will mount failed")
    reported = []
    klass = component_class
    klass.define_method(:component_will_mount) { raise error }
    klass.define_method(:component_raised) { |raised| reported << raised }

    raised = assert_raises(RuntimeError) { klass.new.mount(Element.new("main")) }

    assert_same error, raised
    assert_equal [error], reported
    assert_same error, span("funicular.component.mount").error
  end

  def test_event_cleanup_error_finishes_rebind_span_and_preserves_error
    error = RuntimeError.new("cleanup failed")
    klass = component_class
    klass.define_method(:cleanup_events) { raise error }
    component = klass.new
    component.mount(Element.new("main"))

    raised = assert_raises(RuntimeError) { component.patch(count: 1) }

    assert_same error, raised
    assert_same error, span("funicular.events.rebind").error
    assert_equal :error, span("funicular.events.rebind").status
    assert_equal "cleanup", span("funicular.events.rebind").attributes["funicular.events.phase"]
  end

  def test_hydration_reuse_and_structural_fallback
    container = Element.new("main")
    reused_root = container.appendChild(Element.new("div"))
    component_class.new.hydrate(reused_root)
    assert_equal "reused", span("funicular.component.hydrate").attributes["funicular.hydration.result"]

    stale_root = Element.new("span")
    container = Element.new("main")
    container.appendChild(stale_root)
    capture_io { component_class.new.hydrate(stale_root) }

    hydrate = span("funicular.component.hydrate")
    assert_equal "full_render_fallback", hydrate.attributes["funicular.hydration.result"]
    fallback = @adapter.events.last
    assert_equal "funicular.hydration.fallback", fallback.name
    assert_equal "structural_mismatch", fallback.attributes["error.type"]
  end

  def test_adapter_filter_removes_verbose_update_children
    Funicular::Instrumentation.__reset
    disabled = %w[funicular.vdom.diff funicular.dom.patch funicular.events.rebind]
    @adapter = Adapter.new(disabled)
    Funicular::Instrumentation.register(:test, @adapter)
    component = component_class.new
    component.mount(Element.new("main"))
    component.patch(count: 1)

    names = @adapter.finished.map(&:name)
    assert_includes names, "funicular.component.update"
    disabled.each { |name| refute_includes names, name }
  end

  def test_no_adapter_render_does_not_read_the_clock
    calls = 0
    Funicular::Instrumentation.__reset
    Funicular::Instrumentation.clock = -> { calls += 1 }

    component_class.new.build_vdom

    assert_equal 0, calls
  end

  def test_navigation_records_kind_pattern_and_match_without_raw_path
    router = Funicular::Router.new(Element.new("main"))
    router.get("/posts/:id", to: RouteComponent)
    router.define_singleton_method(:current_location_path) { @test_path }
    router.instance_variable_set(:@test_path, "/posts/secret-id")

    router.send(:handle_route_change, :push)
    navigation = span("funicular.navigation")

    assert_equal "push", navigation.attributes["funicular.navigation.kind"]
    assert_equal "/posts/:id", navigation.attributes["funicular.route.pattern"]
    assert_equal true, navigation.attributes["funicular.route.matched"]
    refute_includes navigation.attributes.values, "/posts/secret-id"

    router.instance_variable_set(:@test_path, "/missing/private")
    router.send(:handle_route_change, :pop)
    navigation = span("funicular.navigation")
    assert_equal "pop", navigation.attributes["funicular.navigation.kind"]
    assert_equal false, navigation.attributes["funicular.route.matched"]
    refute navigation.attributes.key?("funicular.route.pattern")

    router.instance_variable_set(:@test_path, "/posts/initial")
    router.send(:handle_route_change)
    assert_equal "initial", span("funicular.navigation").attributes["funicular.navigation.kind"]

    router.instance_variable_set(:@test_path, "/posts/hydrated")
    router.send(:handle_route_change, :hydrate_initial)
    assert_equal "hydrate_initial", span("funicular.navigation").attributes["funicular.navigation.kind"]
  end

  def test_recursive_patch_count_handles_indexed_and_keyed_patches
    component = component_class.new
    patches = [
      [0, [[:replace, :new, :old]]],
      [:keyed_children,
       [[:keep, 0, 0, [[:props, { class: "new" }]]], [:insert, 1, :node]],
       [[2, :old]]]
    ]

    assert_equal 4, component.send(:instrumentation_patch_count, patches)
  end

  def test_router_hydration_error_emits_fallback_and_remounts
    HydrateFailureRouteComponent.fail_hydrate = true
    HydrateFailureRouteComponent.mount_count = 0
    container = Element.new("main")
    container.appendChild(Element.new("div"))
    router = Funicular::Router.new(container)
    router.get("/hydrated", to: HydrateFailureRouteComponent)
    router.define_singleton_method(:current_location_path) { "/hydrated" }
    router.instance_variable_set(:@hydrate_initial, true)

    capture_io { router.send(:handle_route_change, :hydrate_initial) }

    assert_equal 1, HydrateFailureRouteComponent.mount_count
    fallback = @adapter.events.last
    assert_equal "funicular.hydration.fallback", fallback.name
    assert_equal "RuntimeError", fallback.attributes["error.type"]
    assert_equal "failed_then_remounted",
                 span("funicular.component.hydrate").attributes["funicular.hydration.result"]
    assert_equal :ok, span("funicular.navigation").status
  end
end
