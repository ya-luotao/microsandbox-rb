# frozen_string_literal: true

module Microsandbox
  # A named persistent volume, from {Volume.create} / {Volume.get} / {Volume.list}.
  #
  # `path` is populated when returned from {Volume.create}; the storage stats
  # (`kind`, `used_bytes`, …) are populated when returned from {Volume.get}/{Volume.list}.
  class VolumeInfo
    attr_reader :name, :path, :quota_mib, :used_bytes, :capacity_bytes,
                :disk_format, :disk_fstype, :labels

    def initialize(data)
      @name = data["name"]
      @path = data["path"]
      @kind = data["kind"]
      @quota_mib = data["quota_mib"]
      @used_bytes = data["used_bytes"]
      @capacity_bytes = data["capacity_bytes"]
      @disk_format = data["disk_format"]
      @disk_fstype = data["disk_fstype"]
      @labels = data["labels"] || {}
      @created_at_ms = data["created_at_ms"]
    end

    # @return [Symbol, nil] :directory or :disk
    def kind
      @kind&.to_sym
    end

    # @return [Time, nil]
    def created_at
      @created_at_ms && Time.at(@created_at_ms / 1000.0)
    end

    def inspect
      "#<Microsandbox::VolumeInfo name=#{@name.inspect}#{@kind ? " kind=#{@kind}" : ""}>"
    end
  end

  # Management of named persistent volumes. Mount them into a sandbox via
  # `Sandbox.create(..., volumes: { "/data" => { named: "my-vol" } })`.
  class Volume
    class << self
      # Create a named volume.
      # @param name [String]
      # @param kind ["dir", "disk"] storage kind (default "dir")
      # @param size_mib [Integer, nil] required for kind "disk"
      # @param quota_mib [Integer, nil] optional quota
      # @param labels [Hash, nil]
      # @return [VolumeInfo]
      def create(name, kind: "dir", size_mib: nil, quota_mib: nil, labels: nil)
        opts = { "kind" => kind.to_s }
        opts["size_mib"] = Integer(size_mib) if size_mib
        opts["quota_mib"] = Integer(quota_mib) if quota_mib
        opts["labels"] = labels.each_with_object({}) { |(k, v), a| a[k.to_s] = v.to_s } if labels
        VolumeInfo.new(Native::Volume.create(name.to_s, opts))
      end

      # Metadata for a volume.
      # @return [VolumeInfo]
      def get(name)
        VolumeInfo.new(Native::Volume.get(name.to_s))
      end

      # All volumes.
      # @return [Array<VolumeInfo>]
      def list
        Native::Volume.list.map { |info| VolumeInfo.new(info) }
      end

      # Remove a volume.
      # @return [nil]
      def remove(name)
        Native::Volume.remove(name.to_s)
        nil
      end
    end
  end
end
