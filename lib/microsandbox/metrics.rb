# frozen_string_literal: true

module Microsandbox
  # A point-in-time resource-usage snapshot for a sandbox, returned by
  # {Sandbox#metrics}.
  class Metrics
    # @return [Float] CPU usage as a percentage (0.0–100.0 * vCPUs)
    attr_reader :cpu_percent
    # @return [Integer] cumulative vCPU time in nanoseconds
    attr_reader :vcpu_time_ns
    # @return [Integer] memory currently used, in bytes
    attr_reader :memory_bytes
    # @return [Integer, nil] memory available to the guest, in bytes
    attr_reader :memory_available_bytes
    # @return [Integer, nil] host-resident memory for the VM, in bytes
    attr_reader :memory_host_resident_bytes
    # @return [Integer] memory limit, in bytes
    attr_reader :memory_limit_bytes
    # @return [Integer] cumulative bytes read from disk
    attr_reader :disk_read_bytes
    # @return [Integer] cumulative bytes written to disk
    attr_reader :disk_write_bytes
    # @return [Integer] cumulative bytes received over the network
    attr_reader :net_rx_bytes
    # @return [Integer] cumulative bytes transmitted over the network
    attr_reader :net_tx_bytes
    # @return [Float] sandbox uptime in seconds
    attr_reader :uptime_secs

    def initialize(data)
      @cpu_percent = data["cpu_percent"]
      @vcpu_time_ns = data["vcpu_time_ns"]
      @memory_bytes = data["memory_bytes"]
      @memory_available_bytes = data["memory_available_bytes"]
      @memory_host_resident_bytes = data["memory_host_resident_bytes"]
      @memory_limit_bytes = data["memory_limit_bytes"]
      @disk_read_bytes = data["disk_read_bytes"]
      @disk_write_bytes = data["disk_write_bytes"]
      @net_rx_bytes = data["net_rx_bytes"]
      @net_tx_bytes = data["net_tx_bytes"]
      @uptime_secs = data["uptime_secs"]
      @timestamp_ms = data["timestamp_ms"]
    end

    # @return [Time] when this snapshot was captured
    def timestamp
      Time.at(@timestamp_ms / 1000.0)
    end

    def inspect
      "#<Microsandbox::Metrics cpu=#{@cpu_percent.round(1)}% " \
        "mem=#{@memory_bytes}/#{@memory_limit_bytes}B uptime=#{@uptime_secs.round(1)}s>"
    end
  end
end
