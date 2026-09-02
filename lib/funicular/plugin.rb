# frozen_string_literal: true

require "fileutils"
require "pathname"

module Funicular
  module Plugin
    BUILD_DIR = "app/assets/builds/funicular/plugins"
    GROUP = :funicular

    class Error < StandardError; end

    class Project
      attr_reader :root

      def initialize(root)
        @root = Pathname(root).expand_path
      end

      def assets_dir
        root.join("assets")
      end

      def mruby_source_dir
        mrblib = root.join("mrblib")
        mrblib.directory? ? mrblib : root.join("lib")
      end

      alias source_dir mruby_source_dir

      def source_files
        nested = Dir.glob(source_dir.join("*", "**", "*.rb").to_s).sort
        top_level = Dir.glob(source_dir.join("*.rb").to_s).sort
        nested + top_level
      end

      def css_paths
        Dir.glob(assets_dir.join("*.css").to_s).sort.map { |path| Pathname(path) }
      end

      def js_paths
        Dir.glob(assets_dir.join("*.js").to_s).sort.map { |path| Pathname(path) }
      end

      def asset_paths
        css_paths + js_paths
      end
    end

    class Spec
      attr_reader :bundler_spec

      def initialize(bundler_spec)
        @bundler_spec = bundler_spec
      end

      def root
        @root ||= Pathname(bundler_spec.full_gem_path).expand_path
      end

      def project
        @project ||= Project.new(root)
      end

      def name
        bundler_spec.name
      end

      def css_paths
        project.css_paths
      end

      def js_paths
        project.js_paths
      end

      def asset_paths
        project.asset_paths
      end

      def validate!
        raise Error, "Missing Funicular plugin gem: #{root}" unless root.exist?
        raise Error, "No Ruby source files found in #{project.mruby_source_dir}" if project.source_files.empty?

        self
      end
    end

    class Registry
      attr_reader :rails_root

      def initialize(rails_root)
        @rails_root = Pathname(rails_root).expand_path
      end

      def specs
        @specs ||= funicular_specs.map { |spec| Spec.new(spec) }
      end

      def sync_assets
        asset_entries
        build_root = rails_root.join(BUILD_DIR)
        FileUtils.mkdir_p(build_root)

        validated_specs.each do |spec|
          target_dir = build_root.join(Plugin.safe_name(spec.name))
          FileUtils.rm_rf(target_dir)
          FileUtils.mkdir_p(target_dir)
          spec.asset_paths.each do |path|
            FileUtils.cp(path, target_dir.join(File.basename(path))) if path.exist?
          end
        end
      end

      def local_source_files
        validated_specs.flat_map { |spec| spec.project.source_files }
      end

      def asset_entries
        entries = validated_specs.flat_map do |spec|
          safe_name = Plugin.safe_name(spec.name)
          [["css", spec.css_paths], ["js", spec.js_paths]].flat_map do |type, paths|
            paths.map do |path|
              { "type" => type, "logical_path" => "funicular/plugins/#{safe_name}/#{path.basename}" }
            end
          end
        end

        duplicate = entries.map { |entry| entry["logical_path"] }.tally.find { |_path, count| count > 1 }
        raise Error, "Duplicate Funicular plugin asset: #{duplicate.first}" if duplicate

        entries
      end

      def validate!
        asset_entries
        specs
      end

      private

      def funicular_specs
        names = bundler_dependencies
                .select { |dependency| dependency.groups.include?(GROUP) }
                .map(&:name)
        return [] if names.empty?

        bundler_specs.select { |spec| names.include?(spec.name) }
      end

      def bundler_dependencies
        require "bundler"

        Bundler.definition.dependencies
      rescue LoadError
        raise Error, "Bundler is required to resolve Funicular plugin gems"
      end

      def bundler_specs
        require "bundler"

        Bundler.load.specs
      rescue LoadError
        raise Error, "Bundler is required to resolve Funicular plugin gems"
      end

      def validated_specs
        validated = specs.map(&:validate!)
        duplicate = validated.group_by { |spec| Plugin.safe_name(spec.name) }
                             .find { |_name, matches| matches.length > 1 }
        if duplicate
          raise Error, "Duplicate Funicular plugin name: #{duplicate.first}"
        end
        validated
      end
    end

    def self.safe_name(name)
      safe_name = name.to_s.split("/").last.to_s.gsub(/[^a-zA-Z0-9]+/, "_").gsub(/\A_+|_+\z/, "").downcase
      raise Error, "Unsafe Funicular plugin name: #{name.inspect}" if safe_name.empty?

      safe_name
    end
  end
end
