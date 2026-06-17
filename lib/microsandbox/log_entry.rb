# frozen_string_literal: true

module Microsandbox
  # A single captured log entry, returned by {Sandbox#logs}.
  class LogEntry
    # @return [Symbol] one of :stdout, :stderr, :output, :system
    attr_reader :source
    # @return [Integer, nil] relay-monotonic session id (nil for system markers)
    attr_reader :session_id
    # @return [String] opaque resume cursor token
    attr_reader :cursor
    # @return [String] raw captured bytes (ASCII-8BIT)
    attr_reader :data

    def initialize(entry)
      @timestamp_ms = entry["timestamp_ms"]
      @source = entry["source"].to_sym
      @session_id = entry["session_id"]
      @cursor = entry["cursor"]
      @data = entry["data"]
    end

    # @return [Time] wall-clock capture time
    def timestamp
      Time.at(@timestamp_ms / 1000.0)
    end

    # @return [String] the captured bytes decoded as UTF-8 (lenient)
    def text
      @data.dup.force_encoding(Encoding::UTF_8)
    end

    def inspect
      "#<Microsandbox::LogEntry source=#{@source} session_id=#{@session_id} " \
        "len=#{@data.bytesize}>"
    end
  end
end
