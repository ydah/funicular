# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "../lib/funicular"

Funicular::SSR::Runtime.load_framework!

class BenchmarkComponent < Funicular::Component
  def render
    div { span { "small" } }
  end
end

class CountingAdapter
  attr_reader :callback_count

  def initialize
    reset!
  end

  def reset!
    @callback_count = 0
  end

  def start(_span, _parent_state)
    @callback_count += 1
    nil
  end

  def finish(_state, _span)
    @callback_count += 1
  end
end

class ProfilerLikeAdapter < CountingAdapter
  attr_reader :durations

  def reset!
    super
    @durations = []
  end

  def start(span, _parent_state)
    super
    span.started_at_us
  end

  def finish(started_at_us, span)
    super
    @durations << span.ended_at_us - started_at_us
  end
end

def tree(size, keyed:, reverse: false)
  ids = (0...size).to_a
  ids.reverse! if reverse
  children = ids.map do |id|
    props = keyed ? { key: id } : {}
    Funicular::VDOM::Element.new("li", props, [id.to_s])
  end
  Funicular::VDOM::Element.new("ul", {}, children)
end

def update_operation(before, after)
  lambda do
    Funicular::Instrumentation.instrument("funicular.component.update") do
      Funicular::Instrumentation.instrument("funicular.vdom.diff") do
        Funicular::VDOM::Differ.diff(before, after)
      end
    end
  end
end

def percentile(sorted, ratio)
  sorted[[(sorted.length * ratio).ceil - 1, 0].max]
end

def measure(operation, iterations)
  samples = []
  iterations.times do
    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    operation.call
    ended_at = Process.clock_gettime(Process::CLOCK_MONOTONIC, :nanosecond)
    samples << (ended_at - started_at) / 1_000.0
  end
  sorted = samples.sort
  total_seconds = samples.sum / 1_000_000.0
  {
    "median_us" => percentile(sorted, 0.50).round(2),
    "p95_us" => percentile(sorted, 0.95).round(2),
    "iterations_per_second" => (iterations / total_seconds).round(2)
  }
end

iterations = Integer(ENV.fetch("N", "200"))
small = BenchmarkComponent.new
empty = tree(3, keyed: false)
unkeyed_before = tree(100, keyed: false)
unkeyed_after = tree(100, keyed: false, reverse: true)
keyed_before = tree(100, keyed: true)
keyed_after = tree(100, keyed: true, reverse: true)

cases = {
  "build_vdom" => -> { small.build_vdom },
  "empty_diff_update" => update_operation(empty, empty),
  "100_unkeyed_children" => update_operation(unkeyed_before, unkeyed_after),
  "100_keyed_reorder" => update_operation(keyed_before, keyed_after)
}
adapters = {
  "no_adapter" => nil,
  "noop_adapter" => CountingAdapter.new,
  "profiler_like_adapter" => ProfilerLikeAdapter.new
}

artifact = {
  "schema_version" => 1,
  "ruby" => RUBY_DESCRIPTION,
  "iterations" => iterations,
  "results" => []
}

cases.each do |case_name, operation|
  adapters.each do |adapter_name, adapter|
    Funicular::Instrumentation.__reset
    Funicular::Instrumentation.register(:benchmark, adapter) if adapter
    10.times { operation.call }
    adapter.reset! if adapter
    result = measure(operation, iterations)
    result["case"] = case_name
    result["adapter"] = adapter_name
    result["callback_count"] = adapter ? adapter.callback_count : 0
    artifact["results"] << result
    puts format(
      "%-22s %-22s median=%8.2fus p95=%8.2fus ips=%10.2f callbacks=%d",
      case_name, adapter_name, result["median_us"], result["p95_us"],
      result["iterations_per_second"], result["callback_count"]
    )
  end
end

if (output = ENV["OUTPUT"])
  FileUtils.mkdir_p(File.dirname(output))
  File.write(output, JSON.pretty_generate(artifact) + "\n")
  puts "wrote #{output}"
end

if (baseline_path = ENV["BASELINE"])
  baseline = JSON.parse(File.read(baseline_path)).fetch("results")
  baseline.each do |old|
    current = artifact["results"].find do |item|
      item["case"] == old["case"] && item["adapter"] == old["adapter"]
    end
    next unless current
    delta = (current["median_us"] / old.fetch("median_us") - 1) * 100
    puts format("delta %-22s %-22s %+7.2f%%", old["case"], old["adapter"], delta)
  end
end
