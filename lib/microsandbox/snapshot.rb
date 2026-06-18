# frozen_string_literal: true

module Microsandbox
  # Metadata for a snapshot artifact, returned by {Snapshot.create}/{Snapshot.get}/
  # {Snapshot.list}/{Snapshot.import}.
  #
  # `digest` and `path` are always present. `create` additionally populates
  # `size_bytes`; `get`/`list`/`import` additionally populate `name`,
  # `parent_digest`, `image_ref`, `format`, and `created_at`.
  class SnapshotInfo
    # @return [String] manifest digest ("sha256:…") — the canonical identity
    attr_reader :digest
    # @return [String] artifact directory path
    attr_reader :path
    # @return [String, nil] name alias (nil for digest-only entries)
    attr_reader :name
    # @return [String, nil] parent snapshot digest
    attr_reader :parent_digest
    # @return [String, nil] source OCI image reference
    attr_reader :image_ref
    # @return [Integer, nil] artifact size in bytes
    attr_reader :size_bytes

    def initialize(data)
      @digest = data["digest"]
      @path = data["path"]
      @name = data["name"]
      @parent_digest = data["parent_digest"]
      @image_ref = data["image_ref"]
      @format = data["format"]
      @size_bytes = data["size_bytes"]
      @created_at_ms = data["created_at_ms"]
    end

    # @return [Symbol, nil] disk format (:raw or :qcow2)
    def format
      @format&.to_sym
    end

    # @return [Time, nil]
    def created_at
      @created_at_ms && Time.at(@created_at_ms / 1000.0)
    end

    def inspect
      "#<Microsandbox::SnapshotInfo digest=#{@digest.inspect}#{" name=#{@name.inspect}" if @name}>"
    end
  end

  # The result of {Snapshot.verify}.
  class SnapshotVerifyReport
    # @return [String] manifest digest
    attr_reader :digest
    # @return [String] artifact directory path
    attr_reader :path
    # @return [Symbol] :not_recorded or :verified
    attr_reader :status
    # @return [String, nil] digest algorithm (when :verified)
    attr_reader :algorithm
    # @return [String, nil] matched content digest (when :verified)
    attr_reader :content_digest

    def initialize(data)
      @digest = data["digest"]
      @path = data["path"]
      @status = data["upper_status"].to_sym
      @algorithm = data["upper_algorithm"]
      @content_digest = data["upper_digest"]
    end

    # @return [Boolean] whether content integrity was recorded and matched
    def verified? = @status == :verified
    # @return [Boolean] whether no integrity descriptor was recorded
    def not_recorded? = @status == :not_recorded
  end

  # Creation and management of sandbox snapshots. A snapshot captures a stopped
  # sandbox's upper layer into a portable artifact; boot from it with
  # `Sandbox.create(from_snapshot: "name-or-digest")`.
  class Snapshot
    class << self
      # Create a snapshot of a stopped sandbox.
      #
      # @param source_sandbox [String] name of the (stopped) source sandbox
      # @param name [String, nil] destination name under the snapshots dir
      # @param path [String, nil] explicit destination directory (alternative to name)
      # @param labels [Hash, nil] user labels
      # @param force [Boolean] overwrite an existing artifact at the destination
      # @param record_integrity [Boolean] compute + record upper-layer integrity
      # @return [SnapshotInfo]
      def create(source_sandbox, name: nil, path: nil, labels: nil, force: false, record_integrity: false)
        opts = {}
        opts["name"] = name.to_s if name
        opts["path"] = path.to_s if path
        opts["labels"] = stringify(labels) if labels
        opts["force"] = true if force
        opts["record_integrity"] = true if record_integrity
        SnapshotInfo.new(Native::Snapshot.create(source_sandbox.to_s, opts))
      end

      # Metadata for a snapshot by name or digest.
      # @return [SnapshotInfo]
      def get(name_or_digest)
        SnapshotInfo.new(Native::Snapshot.get(name_or_digest.to_s))
      end

      # All snapshots.
      # @return [Array<SnapshotInfo>]
      def list
        Native::Snapshot.list.map { |info| SnapshotInfo.new(info) }
      end

      # Remove a snapshot artifact by name or path.
      # @param force [Boolean] remove even if referenced
      # @return [nil]
      def remove(name_or_path, force: false)
        Native::Snapshot.remove(name_or_path.to_s, force)
        nil
      end

      # Verify a snapshot's recorded upper-layer integrity.
      # @return [SnapshotVerifyReport]
      def verify(name_or_path)
        SnapshotVerifyReport.new(Native::Snapshot.verify(name_or_path.to_s))
      end

      # Bundle a snapshot into a `.tar.zst` (or plain `.tar`) archive.
      # @param with_parents [Boolean] include ancestor snapshots
      # @param with_image [Boolean] include OCI image artifacts (boots offline)
      # @param plain_tar [Boolean] write an uncompressed `.tar`
      # @return [nil]
      def export(name_or_path, out_path, with_parents: false, with_image: false, plain_tar: false)
        opts = {}
        opts["with_parents"] = true if with_parents
        opts["with_image"] = true if with_image
        opts["plain_tar"] = true if plain_tar
        Native::Snapshot.export(name_or_path.to_s, out_path.to_s, opts)
        nil
      end

      # Unpack a snapshot archive into the snapshots dir.
      # @param dest [String, nil] explicit destination directory
      # @return [SnapshotInfo]
      def import(archive_path, dest: nil)
        SnapshotInfo.new(Native::Snapshot.import(archive_path.to_s, dest&.to_s))
      end

      private

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      end
    end
  end
end
