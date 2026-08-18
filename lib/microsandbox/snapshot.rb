# frozen_string_literal: true

module Microsandbox
  # Metadata for a snapshot artifact, returned by {Snapshot.create}/{Snapshot.open}/
  # {Snapshot.get}/{Snapshot.list}/{Snapshot.list_dir}/{Snapshot.load}.
  #
  # `digest` and `path` are always present. The artifact-opening paths
  # (`create`/`open`/`list_dir`, and {SandboxHandle#snapshot}) carry the full
  # descriptor — `size_bytes`, `image_ref`, `image_manifest_digest`, `format`,
  # `fstype`, `parent_digest`, `created_at`, `source_sandbox`, and `labels`. The
  # index paths (`get`/`list`/`load`) populate `name`, `parent_digest`,
  # `image_ref`, `format`, `size_bytes`, `created_at`, and the index-only
  # `locality`/`availability`/`migration_state` columns (descriptor-only fields
  # such as `source_sandbox`/`labels` are nil/empty there).
  #
  # Snapshots come in two state families (see {#state_kind}): `"file"` — a
  # concrete disk payload, where {#format}/{#fstype}/{#size_bytes} are set — and
  # `"checkpoint"` — a manifest-backed state, where those are nil and the
  # `checkpoint_*` fields are set instead.
  class SnapshotInfo
    # @return [String] descriptor digest ("sha256:…") — the canonical identity
    attr_reader :digest
    # @return [String] artifact directory path
    attr_reader :path
    # @return [String, nil] name alias (nil for digest-only entries)
    attr_reader :name
    # @return [String, nil] parent snapshot digest
    attr_reader :parent_digest
    # @return [String, nil] source OCI image reference
    attr_reader :image_ref
    # @return [String, nil] OCI manifest digest of the pinned image (descriptor paths)
    attr_reader :image_manifest_digest
    # @return [String, nil] payload filesystem type, e.g. "ext4" (file state only)
    attr_reader :fstype
    # @return [String, nil] best-effort source-sandbox name, if recorded
    attr_reader :source_sandbox
    # @return [Hash{String=>String}] user labels ({} for index-only entries)
    attr_reader :labels
    # @return [Integer, nil] payload size in bytes (nil for checkpoint state)
    attr_reader :size_bytes
    # @return [String, nil] stable checkpoint id (checkpoint state only)
    attr_reader :checkpoint_id
    # @return [String, nil] checkpoint-manifest digest (checkpoint state only)
    attr_reader :checkpoint_manifest_digest
    # @return [String, nil] index locality: "embedded" or "linked" (index paths)
    attr_reader :locality
    # @return [String, nil] index availability, normally "ready" (index paths)
    attr_reader :availability
    # @return [String, nil] descriptor-migration state, normally "canonical"
    #   ("reverse_complete" after downgrade tooling ran; index paths)
    attr_reader :migration_state
    # @return [String, nil] stable failure code when a v0.6.6→v0.6.7 descriptor
    #   migration was blocked (index paths)
    attr_reader :migration_error_code

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
      @scope = data["scope"]
      @state_kind = data["state_kind"]
      @checkpoint_id = data["checkpoint_id"]
      @checkpoint_manifest_digest = data["checkpoint_manifest_digest"]
      @locality = data["locality"]
      @availability = data["availability"]
      @migration_state = data["migration_state"]
      @migration_error_code = data["migration_error_code"]
    end

    # @return [Symbol, nil] disk format (:raw or :qcow2; nil for checkpoint state)
    def format
      @format&.to_sym
    end

    # @return [Symbol, nil] payload scope — :disk today, :resumable once VM
    #   pause/resume lands upstream
    def scope
      @scope&.to_sym
    end

    # @return [String, nil] state family: "file" or "checkpoint"
    attr_reader :state_kind

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

  # The result of {Snapshot.verify}. Since runtime v0.6.9 payload integrity is
  # recorded only when the snapshot was created with `record_integrity: true`:
  # such snapshots report `:verified` (an integrity mismatch raises
  # {SnapshotIntegrityError} instead of returning), snapshots without recorded
  # integrity report `:not_recorded` with `algorithm`/`content_digest` nil.
  class SnapshotVerifyReport
    # @return [String] descriptor digest
    attr_reader :digest
    # @return [String] artifact directory path
    attr_reader :path
    # @return [Symbol] :verified or :not_recorded
    attr_reader :status
    # @return [String, nil] digest algorithm (nil when :not_recorded)
    attr_reader :algorithm
    # @return [String, nil] matched content digest (nil when :not_recorded)
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
  end

  # Creation and management of sandbox snapshots. A snapshot captures a stopped
  # sandbox's disk state into a portable artifact; boot from it with
  # `Sandbox.create(from_snapshot: "name-or-digest")`.
  #
  # v0.6.7 descriptor contract: artifacts are identified by their own name and
  # live at `dest_dir/<name>`; the descriptor file is `snapshot.json`. Artifacts
  # written by ≤0.10.x gems (`manifest.json`) are migrated automatically by the
  # runtime on first use — after which older gem versions can no longer read
  # them (downgrade requires the `msb self downgrade` tooling).
  class Snapshot
    class << self
      # Create a snapshot named `name` from a stopped sandbox.
      #
      # @param name [String] the snapshot's own name (its identity)
      # @param from_sandbox [String] name of the (stopped) source sandbox
      # @param dest_dir [String, nil] parent directory override — the artifact
      #   is written at `dest_dir/<name>` (default: the snapshots dir)
      # @param labels [Hash, nil] user labels
      # @param force [Boolean] overwrite an existing artifact at the destination
      # @param record_integrity [Boolean] record persistent payload integrity
      #   (a Merkle content digest) in the artifact — opt-in since runtime
      #   v0.6.9 because hashing large allocated uppers is expensive; without
      #   it {Snapshot.verify} reports `:not_recorded`
      # @param resumable [Boolean] request a resumable (memory+device) snapshot;
      #   raises {UnsupportedError} until VM pause/resume lands upstream
      # @return [SnapshotInfo]
      def create(name, from_sandbox:, dest_dir: nil, labels: nil, force: false,
        record_integrity: false, resumable: false)
        opts = {"from_sandbox" => from_sandbox.to_s}
        opts["dest_dir"] = dest_dir.to_s if dest_dir
        opts["labels"] = stringify(labels) if labels
        opts["force"] = true if force
        opts["record_integrity"] = true if record_integrity
        opts["resumable"] = true if resumable
        SnapshotInfo.new(Native::Snapshot.create(name.to_s, opts))
      end

      # Open a snapshot artifact by bare name or path (cheap metadata
      # validation; does not read the payload). Unlike {get}, this also
      # works for artifacts addressed by path that were never indexed, and it
      # returns the full descriptor.
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
      # subdirectory's `snapshot.json`, without touching the local index — for
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

      # Verify a snapshot's recorded payload integrity.
      # @return [SnapshotVerifyReport]
      def verify(name_or_path)
        SnapshotVerifyReport.new(Native::Snapshot.verify(name_or_path.to_s))
      end

      # Bundle a snapshot into a `.tar.zst` (or plain `.tar`) archive.
      # Renamed from `export` in 0.11.0, mirroring the v0.6.7 SDKs.
      # @param with_parents [Boolean] include ancestor snapshots
      # @param with_image [Boolean] include OCI image artifacts (boots offline)
      # @param plain_tar [Boolean] write an uncompressed `.tar`
      # @return [nil]
      def save(name_or_path, out_path, with_parents: false, with_image: false, plain_tar: false)
        opts = {}
        opts["with_parents"] = true if with_parents
        opts["with_image"] = true if with_image
        opts["plain_tar"] = true if plain_tar
        Native::Snapshot.save(name_or_path.to_s, out_path.to_s, opts)
        nil
      end

      # Unpack a snapshot archive into the snapshots dir. Renamed from
      # `import` in 0.11.0, mirroring the v0.6.7 SDKs.
      # @param dest [String, nil] explicit destination directory
      # @return [SnapshotInfo]
      def load(archive_path, dest: nil)
        SnapshotInfo.new(Native::Snapshot.load(archive_path.to_s, dest&.to_s))
      end

      private

      def stringify(hash)
        hash.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      end
    end
  end
end
