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
      @default = data["default"]
      @quota_mib = data["quota_mib"]
      @used_bytes = data["used_bytes"]
      @capacity_bytes = data["capacity_bytes"]
      @disk_format = data["disk_format"]
      @disk_fstype = data["disk_fstype"]
      @labels = data["labels"] || {}
      @created_at_ms = data["created_at_ms"]
    end

    # @return [Symbol, nil] :dir or :disk (matches the {Volume.create} `kind:`
    #   input and the core's canonical names)
    def kind
      @kind&.to_sym
    end

    # Whether this is the backend's default volume (runtime v0.6.9, see
    # {Volume.get_default}).
    # @return [Boolean]
    def default?
      !!@default
    end

    # @return [Time, nil]
    def created_at
      Microsandbox.time_from_ms(@created_at_ms)
    end

    # A host-side filesystem view over this volume (read/write its contents
    # without a running sandbox).
    # @return [VolumeFs]
    def fs
      @fs ||= VolumeFs.new(Native::Volume.fs(@name.to_s))
    end

    def inspect
      "#<Microsandbox::VolumeInfo name=#{@name.inspect}#{" kind=#{@kind}" if @kind}>"
    end
  end

  # A host-side filesystem view over a named volume, from {Volume.fs} or
  # {VolumeInfo#fs}. Reads and writes the volume's contents directly on the host,
  # without booting a sandbox. All paths are relative to the volume root (a
  # leading `/` is the volume root) and may not contain a `..` segment — every
  # operation raises {FilesystemError} for one. Mirrors the `VolumeFs` of the
  # official Python/Node SDKs.
  class VolumeFs
    def initialize(native)
      @native = native
    end

    # Read a file as raw bytes (ASCII-8BIT).
    # @return [String]
    def read(path)
      @native.read(contained(path))
    end

    # Read a file as a UTF-8 string.
    # @return [String]
    def read_text(path)
      @native.read_text(contained(path))
    end

    # Write data to a file, creating parent directories as needed.
    # @param data [String] raw bytes (binary-safe)
    # @raise [TypeError] if +data+ is not a String
    # @return [nil]
    def write(path, data)
      bytes = Microsandbox.coerce_write_bytes(data)
      @native.write(contained(path), bytes)
      nil
    end

    # List the entries of a directory.
    # @return [Array<FsEntry>]
    def list(path)
      @native.list(contained(path)).map { |entry| FsEntry.new(entry) }
    end

    # Create a directory (and any missing parents).
    # @return [nil]
    def mkdir(path)
      @native.mkdir(contained(path))
      nil
    end

    # Remove a single file.
    # @return [nil]
    def remove_file(path)
      @native.remove_file(contained(path))
      nil
    end

    # Remove a directory recursively.
    # @return [nil]
    def remove_dir(path)
      @native.remove_dir(contained(path))
      nil
    end

    # @return [Boolean] whether the path exists in the volume
    def exists?(path)
      @native.exists(contained(path))
    end

    # Copy a file within the volume.
    # @return [nil]
    def copy(src, dst)
      @native.copy(contained(src), contained(dst))
      nil
    end

    # Rename/move a file or directory within the volume.
    # @return [nil]
    def rename(src, dst)
      @native.rename(contained(src), contained(dst))
      nil
    end

    # Stat a path.
    # @return [FsMetadata]
    def stat(path)
      FsMetadata.new(@native.stat(contained(path)))
    end

    private

    # Volume paths are relative to the volume root and never need a `..`
    # segment, so one is refused here with a clear message instead of being
    # handed to the resolver. The native layer enforces the same rule; this
    # check only exists so the error names the cause.
    def contained(path)
      s = path.to_s
      if s.split("/").include?("..")
        raise Microsandbox::FilesystemError,
          "path traversal outside volume root (`..` segments are not allowed in volume paths)"
      end
      s
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
        opts = {"kind" => kind.to_s}
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

      # The backend's default volume (runtime v0.6.9). Cloud backend only —
      # the full {VolumeInfo#fs} surface works against it; the local backend
      # raises {UnsupportedError} to avoid accidental host access.
      # @return [VolumeInfo]
      def get_default
        VolumeInfo.new(Native::Volume.get_default)
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

      # A host-side filesystem view over a named volume (read/write its contents
      # without a running sandbox). The volume need not be mounted.
      # @return [VolumeFs]
      def fs(name)
        VolumeFs.new(Native::Volume.fs(name.to_s))
      end
    end
  end
end
