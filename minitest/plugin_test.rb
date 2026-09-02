# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

require_relative "test_helper"

class PluginTest < Minitest::Test
  def test_mrblib_is_preferred_and_source_dir_remains_compatible
    Dir.mktmpdir do |dir|
      legacy_root = File.join(dir, "legacy")
      write File.join(legacy_root, "lib", "legacy.rb")
      legacy = Funicular::Plugin::Project.new(legacy_root)
      assert_equal Pathname(File.join(legacy_root, "lib")), legacy.mruby_source_dir
      assert_equal legacy.mruby_source_dir, legacy.source_dir
      assert_equal [File.join(legacy_root, "lib", "legacy.rb")], legacy.source_files

      modern_root = File.join(dir, "modern")
      write File.join(modern_root, "mrblib", "client.rb")
      write File.join(modern_root, "lib", "modern", "railtie.rb")
      modern = Funicular::Plugin::Project.new(modern_root)
      assert_equal Pathname(File.join(modern_root, "mrblib")), modern.mruby_source_dir
      assert_equal [File.join(modern_root, "mrblib", "client.rb")], modern.source_files
    end
  end

  def test_empty_selected_source_reports_the_selected_root
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p File.join(dir, "mrblib")
      write File.join(dir, "lib", "rails_only.rb")

      error = assert_raises(Funicular::Plugin::Error) { plugin_spec("empty", dir).validate! }
      assert_includes error.message, File.join(dir, "mrblib")
    end
  end

  def test_assets_are_top_level_sorted_synced_and_stale_files_are_removed
    Dir.mktmpdir do |dir|
      rails_root = File.join(dir, "app")
      gem_root = File.join(dir, "funicular-datepicker")
      write File.join(gem_root, "lib", "date_picker.rb")
      write File.join(gem_root, "assets", "z.css"), "z"
      write File.join(gem_root, "assets", "a.css"), "a"
      write File.join(gem_root, "assets", "z.js"), "z"
      write File.join(gem_root, "assets", "a.js"), "a"
      write File.join(gem_root, "assets", "nested", "ignored.js"), "ignored"

      target = File.join(rails_root, Funicular::Plugin::BUILD_DIR, "funicular_datepicker")
      write File.join(target, "stale.css"), "stale"
      registry = registry_for(rails_root, plugin_spec("funicular-datepicker", gem_root))
      registry.sync_assets

      assert_equal %w[a.css a.js z.css z.js], Dir.children(target).sort
      assert_equal [
        { "type" => "css", "logical_path" => "funicular/plugins/funicular_datepicker/a.css" },
        { "type" => "css", "logical_path" => "funicular/plugins/funicular_datepicker/z.css" },
        { "type" => "js", "logical_path" => "funicular/plugins/funicular_datepicker/a.js" },
        { "type" => "js", "logical_path" => "funicular/plugins/funicular_datepicker/z.js" }
      ], registry.asset_entries
    end
  end

  def test_css_only_and_js_only_plugins_keep_bundler_order
    Dir.mktmpdir do |dir|
      css_root = File.join(dir, "css-plugin")
      js_root = File.join(dir, "js-plugin")
      write File.join(css_root, "lib", "css.rb")
      write File.join(css_root, "assets", "only.css")
      write File.join(js_root, "mrblib", "js.rb")
      write File.join(js_root, "assets", "only.js")

      entries = registry_for(
        dir,
        plugin_spec("css-plugin", css_root),
        plugin_spec("js-plugin", js_root)
      ).asset_entries

      assert_equal %w[css js], entries.map { |entry| entry["type"] }
      assert_equal %w[css_plugin js_plugin], entries.map { |entry| entry["logical_path"].split("/")[2] }
    end
  end

  def test_safe_name_collision_is_rejected_even_when_filenames_differ
    Dir.mktmpdir do |dir|
      dash_root = File.join(dir, "dash")
      underscore_root = File.join(dir, "underscore")
      write File.join(dash_root, "lib", "plugin.rb")
      write File.join(dash_root, "assets", "a.js")
      write File.join(underscore_root, "lib", "plugin.rb")
      write File.join(underscore_root, "assets", "b.js")
      registry = registry_for(
        dir,
        plugin_spec("same-name", dash_root),
        plugin_spec("same_name", underscore_root)
      )

      error = assert_raises(Funicular::Plugin::Error) { registry.sync_assets }
      assert_includes error.message, "same_name"
      refute Dir.exist?(File.join(dir, Funicular::Plugin::BUILD_DIR))
    end
  end

  def test_safe_name_cannot_traverse_out_of_the_build_root
    assert_equal "plugin_name", Funicular::Plugin.safe_name("../../Plugin Name")
    assert_raises(Funicular::Plugin::Error) { Funicular::Plugin.safe_name("///") }
  end

  def test_propshaft_precompile_resolves_synced_plugin_javascript
    Dir.mktmpdir do |dir|
      gem_root = File.join(dir, "fixture-plugin")
      write File.join(gem_root, "mrblib", "fixture.rb")
      write File.join(gem_root, "assets", "bridge.js"), "globalThis.fixturePlugin = true;"
      registry_for(dir, plugin_spec("fixture-plugin", gem_root)).sync_assets
      logical_path = "funicular/plugins/fixture_plugin/bridge.js"
      fixture = File.expand_path("fixtures/propshaft_app/verify.rb", __dir__)

      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, fixture, dir, logical_path
      )

      assert status.success?, stderr
      assert_match %r{funicular/plugins/fixture_plugin/bridge-[0-9a-f]+\.js}, stdout
    end
  end

  private

  def write(path, content = "# fixture\n")
    FileUtils.mkdir_p File.dirname(path)
    File.write path, content
  end

  def plugin_spec(name, root)
    spec = Gem::Specification.new do |gem|
      gem.name = name
      gem.version = "0.1.0"
    end
    spec.full_gem_path = root
    Funicular::Plugin::Spec.new(spec)
  end

  def registry_for(rails_root, *specs)
    registry = Funicular::Plugin::Registry.new(rails_root)
    registry.define_singleton_method(:specs) { specs }
    registry
  end
end
