# frozen_string_literal: true

module Microsandbox
  # A live stream of {LogEntry}s, returned by {Sandbox#log_stream}. Enumerable:
  # iterate to consume entries as they are appended. With `follow: true` the
  # iteration blocks for new entries until the sandbox stops; otherwise it ends
  # once the historical log is drained.
  #
  # @example
  #   sb.log_stream(follow: true).each { |entry| print entry.text }
  class LogStream
    include Enumerable

    def initialize(native)
      @native = native
    end

    # @yieldparam entry [LogEntry]
    # @return [self, Enumerator]
    def each
      return enum_for(:each) unless block_given?

      while (entry = @native.recv)
        yield LogEntry.new(entry)
      end
      self
    end
  end

  # A live stream of {Metrics} snapshots, returned by {Sandbox#metrics_stream}.
  # Enumerable: iteration yields one snapshot per interval tick until the
  # sandbox stops.
  #
  # @example
  #   sb.metrics_stream(interval: 0.5).each { |m| puts m.cpu_percent }
  class MetricsStream
    include Enumerable

    def initialize(native)
      @native = native
    end

    # @yieldparam metrics [Metrics]
    # @return [self, Enumerator]
    def each
      return enum_for(:each) unless block_given?

      while (snapshot = @native.recv)
        yield Metrics.new(snapshot)
      end
      self
    end
  end
end
