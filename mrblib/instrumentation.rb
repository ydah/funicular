module Funicular
  module Instrumentation
    SCHEMA_VERSION = 1
    FAILURE_LIMIT = 3

    class Span
      attr_reader :id, :parent_id, :name, :target, :started_at_us
      attr_reader :attributes, :adapter_states, :ended_at_us, :status, :error

      def initialize(id, parent_id, name, target, started_at_us, attributes, adapters)
        @id = id
        @parent_id = parent_id
        @name = name
        @target = target
        @started_at_us = started_at_us
        @attributes = attributes
        @adapters = adapters
        @adapter_states = {}
        @ended_at_us = nil
        @status = nil
        @error = nil
      end

      def finished?
        !@ended_at_us.nil?
      end

      def adapter_state(name)
        @adapter_states[name]
      end

      def __adapters
        @adapters
      end

      def __finish(ended_at_us, attributes, error)
        return false if finished?
        @attributes.merge!(attributes) if attributes
        @ended_at_us = ended_at_us
        @status = error ? :error : :ok
        @error = error
        true
      end
    end

    class Event
      attr_reader :sequence, :name, :target, :occurred_at_us
      attr_reader :attributes, :parent_id

      def initialize(sequence, name, target, occurred_at_us, attributes, parent_id)
        @sequence = sequence
        @name = name
        @target = target
        @occurred_at_us = occurred_at_us
        @attributes = attributes
        @parent_id = parent_id
      end
    end

    class << self
      attr_writer :clock, :reporter

      def register(name, adapter)
        raise ArgumentError, "instrumentation adapter name must be a Symbol" unless name.is_a?(Symbol)
        raise ArgumentError, "instrumentation adapter already registered: #{name}" if registered?(name)
        adapters << { name: name, adapter: adapter, failures: 0, disabled: false,
                      last_hook: nil, last_exception_class: nil }
        adapter
      end

      def unregister(name)
        adapters.delete_if { |entry| entry[:name] == name }
        nil
      end

      def registered?(name)
        adapters.any? { |entry| entry[:name] == name }
      end

      def enabled?(event_name = nil)
        return false if silenced?
        adapters.any? do |entry|
          next false if entry[:disabled]
          adapter = entry[:adapter]
          !adapter.respond_to?(:enabled?) || call_adapter(entry, :enabled?, event_name)
        end
      end

      def start(name, target = nil, attributes = nil)
        selected = enabled_adapters(name)
        return nil if selected.empty?
        attrs = validate_attributes(attributes)
        parent = current_span
        @sequence = (@sequence || 0) + 1
        span = Span.new(@sequence, parent&.id, name, target, now_us, attrs, selected)
        selected.each do |entry|
          adapter = entry[:adapter]
          parent_state = parent&.adapter_state(entry[:name])
          state = adapter.respond_to?(:start) ? call_adapter(entry, :start, span, parent_state) : nil
          span.adapter_states[entry[:name]] = state unless entry[:disabled]
        end
        span
      end

      def finish(span, attributes = nil, error: nil)
        return nil unless span
        return span if span.finished?
        attrs = validate_attributes(attributes)
        return span unless span.__finish(now_us, attrs, error)
        span.__adapters.each do |entry|
          next if entry[:disabled]
          adapter = entry[:adapter]
          next unless adapter.respond_to?(:finish)
          call_adapter(entry, :finish, span.adapter_state(entry[:name]), span)
        end
        span
      end

      def instrument(name, target = nil, attributes = nil)
        span = start(name, target, attributes)
        return yield(nil) unless span
        begin
          result = with_span(span) { yield(span) }
        rescue => error
          finish(span, nil, error: error)
          raise error
        else
          finish(span)
          result
        end
      end

      def event(name, target = nil, attributes = nil)
        selected = enabled_adapters(name)
        return nil if selected.empty?
        @event_sequence = (@event_sequence || 0) + 1
        parent = current_span
        item = Event.new(@event_sequence, name, target, now_us,
                         validate_attributes(attributes), parent&.id)
        selected.each do |entry|
          adapter = entry[:adapter]
          call_adapter(entry, :event, item) if adapter.respond_to?(:event)
        end
        item
      end

      def current_span
        context[:stack][-1]
      end

      def with_span(span)
        return yield unless span
        stack = context[:stack]
        activations = []
        stack << span
        begin
          span.__adapters.each do |entry|
            next if entry[:disabled]
            adapter = entry[:adapter]
            next unless adapter.respond_to?(:activate)
            activated, token = call_adapter_with_status(
              entry, :activate, span.adapter_state(entry[:name])
            )
            activations << [entry, token] if activated
          end
          yield
        ensure
          i = activations.length - 1
          while i >= 0
            entry, token = activations[i]
            adapter = entry[:adapter]
            call_adapter(entry, :deactivate, token) if adapter.respond_to?(:deactivate)
            i -= 1
          end
          stack.pop
        end
      end

      def silence
        state = context
        state[:silence] += 1
        begin
          yield
        ensure
          state[:silence] -= 1
        end
      end

      def inject_http_headers(span, headers, url = nil)
        return headers unless span
        span.__adapters.each do |entry|
          next if entry[:disabled]
          adapter = entry[:adapter]
          next unless adapter.respond_to?(:inject_http_headers)
          candidate = headers.dup
          injected, = call_adapter_with_status(
            entry, :inject_http_headers,
            span.adapter_state(entry[:name]), candidate, url
          )
          merge_new_headers(headers, candidate) if injected
        end
        headers
      end

      def flush
        dispatch_lifecycle(:flush)
      end

      def shutdown
        dispatch_lifecycle(:shutdown)
      end

      def diagnostics
        adapters.map do |entry|
          { name: entry[:name], failures: entry[:failures], disabled: entry[:disabled],
            last_hook: entry[:last_hook], last_exception_class: entry[:last_exception_class] }
        end
      end

      def __reset
        @adapters = []
        @sequence = 0
        @event_sequence = 0
        @clock = nil
        @reporter = nil
        @context = nil
        Thread.current[:funicular_instrumentation] = nil if defined?(Thread)
      end

      private

      def adapters
        @adapters ||= []
      end

      def enabled_adapters(event_name)
        return [] if silenced?
        adapters.select do |entry|
          next false if entry[:disabled]
          adapter = entry[:adapter]
          !adapter.respond_to?(:enabled?) || call_adapter(entry, :enabled?, event_name)
        end
      end

      def call_adapter(entry, hook, *args)
        result = dispatch_adapter(entry, hook, args)
        adapter_succeeded(entry)
        result
      rescue => error
        adapter_failed(entry, hook, error)
        nil
      end

      def call_adapter_with_status(entry, hook, *args)
        result = dispatch_adapter(entry, hook, args)
        adapter_succeeded(entry)
        [true, result]
      rescue => error
        adapter_failed(entry, hook, error)
        [false, nil]
      end

      def dispatch_adapter(entry, hook, args)
        result = nil
        silence { result = entry[:adapter].send(hook, *args) }
        result
      end

      def adapter_succeeded(entry)
        entry[:failures] = 0
        entry[:last_hook] = nil
      end

      def adapter_failed(entry, hook, error)
        entry[:failures] += 1
        entry[:last_hook] = hook
        entry[:last_exception_class] = error.class
        entry[:disabled] = true if entry[:failures] >= FAILURE_LIMIT
        report(entry, hook, error) if entry[:failures] == 1
      end

      def report(entry, hook, error)
        reporter = @reporter || ->(message) { puts message }
        reporter.call("[Funicular::Instrumentation] #{entry[:name]}.#{hook} raised #{error.class}: #{error.message}")
      rescue
        nil
      end

      def dispatch_lifecycle(hook)
        adapters.each do |entry|
          next if entry[:disabled]
          adapter = entry[:adapter]
          call_adapter(entry, hook) if adapter.respond_to?(hook)
        end
        nil
      end

      def validate_attributes(attributes)
        return {} unless attributes
        attributes.each do |key, value|
          unless key.is_a?(String)
            raise ArgumentError, "instrumentation attribute keys must be Strings"
          end
          unless value.nil? || value.is_a?(String) || value.is_a?(Integer) ||
                 value.is_a?(Float) || value == true || value == false
            raise ArgumentError, "unsupported instrumentation attribute value for #{key}"
          end
        end
        attributes.dup
      end

      def merge_new_headers(headers, candidate)
        existing = headers.keys.map { |key| key.to_s.downcase }
        candidate.each do |key, value|
          normalized = key.to_s.downcase
          next if existing.include?(normalized)
          headers[key] = value
          existing << normalized
        end
      end

      def silenced?
        context[:silence] > 0
      end

      def context
        if defined?(Thread) && Funicular.respond_to?(:server?) && Funicular.server?
          Thread.current[:funicular_instrumentation] ||= { stack: [], silence: 0 }
        else
          @context ||= { stack: [], silence: 0 }
        end
      end

      def now_us
        clock = @clock
        return clock.call if clock
        browser = !Funicular.respond_to?(:server?) || !Funicular.server?
        if browser && defined?(JS) && JS.respond_to?(:global)
          (JS.global[:performance].now.to_f * 1_000).to_i
        elsif defined?(Process::CLOCK_MONOTONIC)
          Process.clock_gettime(Process::CLOCK_MONOTONIC, :microsecond)
        else
          (Time.now.to_f * 1_000_000).to_i
        end
      rescue
        (Time.now.to_f * 1_000_000).to_i
      end
    end
  end
end
