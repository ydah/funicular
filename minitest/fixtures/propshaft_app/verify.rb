# frozen_string_literal: true

ENV["RAILS_ENV"] = "production"

require "json"
require "logger"
require "rails"
require "propshaft"
require "propshaft/railtie"

root, logical_path = ARGV
abort "usage: verify.rb ROOT LOGICAL_PATH" unless root && logical_path

class PropshaftPluginFixture < Rails::Application
  config.eager_load = false
  config.logger = Logger.new(IO::NULL)
  config.secret_key_base = "fixture-secret-key-base"
end

PropshaftPluginFixture.config.root = root
PropshaftPluginFixture.initialize!
PropshaftPluginFixture.assets.processor.process

manifest_path = PropshaftPluginFixture.config.assets.manifest_path
entry = JSON.parse(File.read(manifest_path)).fetch(logical_path)
digested_path = entry.is_a?(Hash) ? entry.fetch("digested_path") : entry
abort "precompiled asset missing" unless manifest_path.dirname.join(digested_path).file?

puts digested_path
