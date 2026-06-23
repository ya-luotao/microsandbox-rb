# frozen_string_literal: true

module Microsandbox
  # Metadata for a snapshot artifact, returned by {Snapshot.create}/{Snapshot.open}/
  # {Snapshot.get}/{Snapshot.list}/{Snapshot.list_dir}/{Snapshot.import}.
  #
  # `digest` and `path` are always present. The artifact-opening paths
  # (`create`/`open`/`list_dir`, and {SandboxHandle#snapshot}) carry the full
  # manifest — `size_bytes`, `image_ref`, `image_manifest_digest`, `format`,
  # `fstype`, `parent_digest`, `created_at`, `source_sandbox`, and `labels`. The
  # index paths (`get`/`list`/`import`) populate `name`, `parent_digest`,
  # `image_ref`, `format`, `size_bytes`, and `created_at` (manifest-only fields
  # such as `fstype`/`source_sandbox`/`labels` are nil/empty there).
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
    # @return [String, nil] OCI manifest digest of the pinned image (manifest paths)
    attr_reader :image_manifest_digest
    # @return [String, nil] upper-layer filesystem type, e.g. "ext4" (manifest paths)
    attr_reader :fstype
    # @return [String, nil] best-effort source-sandbox name, if recorded
    attr_reader :source_sandbox
    # @return [Hash{String=>String}] user labels ({} for index-only entries)
    attr_reader :labels
    # @return [Integer, nil] artifact size in bytes
    attr_reader :size_bytes

    def initialize(data)
      @digest = data["digest"]
      @path = data["path"]
      @name = data["name"]
      @parent_digest = data["parent_digest"]
      @image_ref = data["image_ref"]
      @image_manifest_digest = data["image_manifest_digest"]
      @fstype = data["fstype"]
      @source_sandbox = data["source_sandbox"]
      @labels = data["labels"] || {}
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

    # Re-open this snapshot's artifact (cheap metadata validation), returning a
    # fully-populated {SnapshotInfo}. Addresses by path, so it works even for
    # artifacts that were never added to the local index.
    # @return [SnapshotInfo]
    def open
      Snapshot.open(@path || @digest)
    end

    # Remove this snapshot's artifact and its index row.
    # @param force [Boolean] remove even if it has indexed children
    # @return [nil]
    def remove(force: false)
      Snapshot.remove(@path || @digest, force: force)
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

      # Open a snapshot artifact by bare name or path (cheap metadata
      # validation; does not read the upper layer). Unlike {get}, this also
      # works for artifacts addressed by path that were never indexed, and it
      # returns the full manifest.
      # @return [SnapshotInfo]
      def open(name_or_path)
        SnapshotInfo.new(Native::Snapshot.open(name_or_path.to_s))
      end

      # Metadata for a snapshot by name or digest.
      # @return [SnapshotInfo]
      def get(name_or_digest)
        SnapshotInfo.new(Native::Snapshot.get(name_or_digest.to_s))
      end

      # All snapshots indexed in the local cache.
      # @return [Array<SnapshotInfo>]
      def list
        Native::Snapshot.list.map { |info| SnapshotInfo.new(info) }
      end

      # Enumerate snapshot artifacts under a directory by parsing each
      # subdirectory's `manifest.json`, without touching the local index — for
      # inspecting external/un-imported collections (e.g. a mounted volume).
      # @return [Array<SnapshotInfo>]
      def list_dir(dir)
        Native::Snapshot.list_dir(dir.to_s).map { |info| SnapshotInfo.new(info) }
      end

      # Rebuild the local snapshot index from a directory (defaults to the
      # configured snapshots dir). The repair for index drift or out-of-band
      # imports that {list}/{get} can't otherwise see.
      # @param dir [String, nil]
      # @return [Integer] number of indexed snapshots
      def reindex(dir = nil)
        Native::Snapshot.reindex(dir&.to_s)
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
