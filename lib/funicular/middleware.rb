# frozen_string_literal: true

module Funicular
  class Middleware
    class << self
      attr_accessor :last_mtime, :source_snapshot, :compiling, :mutex

      def reset!
        @last_mtime = nil
        @source_snapshot = nil
        @compiling = false
        @mutex = Mutex.new
      end
    end

    # Initialize class state
    reset!

    def initialize(app)
      @app = app
      @source_dir = Rails.root.join("app", "funicular")
      @output_file = Rails.root.join("app", "assets", "builds", "app.mrb")
    end

    def call(env)
      recompile_if_needed if should_check_recompile?
      @app.call(env)
    end

    private

    def should_check_recompile?
      Rails.env.development? && Dir.exist?(@source_dir)
    end

    def recompile_if_needed
      current_mtime = latest_source_mtime
      current_snapshot = source_snapshot

      # Skip if already compiling or if no changes detected
      return if self.class.compiling
      return if sources_unchanged?(current_mtime, current_snapshot)

      self.class.mutex.synchronize do
        # Double-check inside the lock
        return if self.class.compiling
        return if sources_unchanged?(current_mtime, current_snapshot)

        self.class.compiling = true
      end

      begin
        Rails.logger.info "Funicular: Source files changed, recompiling..."
        plugin_registry = build_plugins
        if Dir.exist?(@source_dir)
          compiler = Compiler.new(
            source_dir: @source_dir,
            output_file: @output_file,
            debug_mode: true,
            logger: Rails.logger,
            prepend_source_files: plugin_registry.local_source_files
          )
          compiler.compile
        end
        self.class.last_mtime = current_mtime
        self.class.source_snapshot = current_snapshot
        invalidate_asset_pipeline_cache
      rescue => e
        Rails.logger.error "Funicular compilation failed: #{e.message}"
      ensure
        self.class.compiling = false
      end
    end

    # Force the asset pipeline to drop its cached fingerprint for app.mrb.
    #
    # Propshaft caches Asset instances (and memoizes #digest / #compiled_content)
    # in LoadPath, and only refreshes them when its file watcher detects a change
    # in a file whose extension is registered in Mime::EXTENSION_LOOKUP. The .mrb
    # extension is not registered there, so when funicular rewrites app.mrb the
    # Propshaft cache is never invalidated and asset_path('app.mrb') keeps
    # returning the stale fingerprinted URL until the Rails process is restarted.
    #
    # We side-step that by invoking the cache sweeper directly after every
    # successful recompile. This is a no-op if Propshaft is not in use.
    def invalidate_asset_pipeline_cache
      return unless Rails.application.respond_to?(:assets)

      assets = Rails.application.assets
      return unless assets.respond_to?(:load_path)

      load_path = assets.load_path
      return unless load_path.respond_to?(:cache_sweeper)

      load_path.cache_sweeper.execute
    end

    def latest_source_mtime
      snapshot = source_snapshot
      return Time.at(0) if snapshot.empty?

      Time.at(snapshot.map { |_path, mtime| mtime }.max)
    end

    def source_snapshot
      source_files = Dir.glob(File.join(@source_dir, "**", "*.rb"))
      plugin_files = plugin_source_files
      (source_files + plugin_files).sort.map { |file| [file, File.mtime(file).to_f] }
    end

    def sources_unchanged?(current_mtime, current_snapshot)
      previous = self.class.source_snapshot
      return previous == current_snapshot if previous

      self.class.last_mtime && current_mtime <= self.class.last_mtime
    end

    def build_plugins
      registry = Plugin::Registry.new(Rails.root)
      return registry if registry.specs.empty?

      registry.validate!
      registry.sync_assets
      registry
    rescue Plugin::Error => e
      Rails.logger.error "Funicular plugin compilation failed: #{e.message}"
      Plugin::Registry.new(Rails.root)
    end

    def plugin_source_files
      registry = Plugin::Registry.new(Rails.root)
      registry.local_source_files + registry.specs.flat_map { |spec| spec.asset_paths.map(&:to_s) }
    rescue Plugin::Error
      []
    end
  end
end
