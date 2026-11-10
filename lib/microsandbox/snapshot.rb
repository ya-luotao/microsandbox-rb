# frozen_string_literal: true

module Microsandbox
  # Metadata for a snapshot artifact, returned by {Snapshot.create}/{Snapshot.open}/
  # {Snapshot.get}/{Snapshot.list}/{Snapshot.list_dir}/{Snapshot.load}.
  #
  # `digest` is always present, and `path` for every local artifact (nil for a
  # cloud one). The artifact-opening paths (`create`/`open`/`list_dir`, and
  # {SandboxHandle#snapshot}) carry the full descriptor — `parent_id`,
  # `size_bytes`, `image_ref`, `image_manifest_digest`, `format`, `fstype`,
  # `created_at`, `source_sandbox`, and `labels` (`parent_digest` is nil there:
  # runtime v0.7 descriptors link their parent by id). The index paths
  # (`get`/`list`/`load`) populate `name`, `parent_digest`,
  # `image_ref`, `format`, `size_bytes`, `created_at`, and the index-only
  # `locality`/`availability`/`migration_state` columns (descriptor-only fields
  # such as `source_sandbox`/`labels` are nil/empty there).
  #
  # Snapshots come in two state families (see {#state_kind}): `"file"` — a
  # concrete disk payload, where {#format}/{#fstype}/{#size_bytes} are set — and
  # `"checkpoint"` — a manifest-backed state, where those are nil and the
  # `checkpoint_*` fields are set instead.
  class SnapshotInfo
    # @return [String] descriptor digest ("sha256:…")
    attr_reader :digest
    # @return [String, nil] stable snapshot id (`snap_…`), independent of the
    #   descriptor digest. Set on every local path; it is a selector on its own
    #   for {Snapshot.open}/{Snapshot.get}/{Snapshot.verify}/{Snapshot.save}/
    #   {Snapshot.remove}, unlike {#name}.
    attr_reader :id
    # @return [String, nil] the backend-neutral reference to pass back to
    #   {Sandbox.restore} (runtime v0.7): for a local artifact, its absolute
    #   path. {Sandbox.restore} given this {SnapshotInfo} uses it with its kind
    #   (see {#reference_kind}).
    attr_reader :reference
    # @return [String, nil] how the backend reads {#reference}: "path", "id"
    #   or "auto"
    attr_reader :reference_kind
    # @return [String, nil] artifact directory path (nil for a cloud artifact).
    #   Since runtime v0.7 the core chooses this directory; it is no longer
    #   `dest_dir/<name>`.
    attr_reader :path
    # @return [String, nil] the member name alias inside its snapshot group
    #   (index paths only; nil for digest-only entries). Since runtime v0.7 a
    #   bare name selects a group head, not a member — address a member as
    #   `"<group>:<name>"` or by {#id}/{#path}/{#digest}.
    attr_reader :name
    # @return [String, nil] parent snapshot digest (index paths only)
    attr_reader :parent_digest
    # @return [String, nil] parent snapshot id (descriptor paths)
    attr_reader :parent_id
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
      @id = data["id"]
      @reference = data["reference"]
      @reference_kind = data["reference_kind"]
      @path = data["path"]
      @name = data["name"]
      @parent_digest = data["parent_digest"]
      @parent_id = data["parent_id"]
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

    # @return [Symbol, nil] payload scope — :disk (file-backed disk state) or
    #   :full (a composite checkpoint, see {Snapshot.create}'s `full:`).
    #   Runtime v0.7 renamed `:resumable` to `:full`.
    def scope
      @scope&.to_sym
    end

    # @return [String, nil] state family: "file" or "checkpoint"
    attr_reader :state_kind

    # @return [Time, nil]
    def created_at
      Microsandbox.time_from_ms(@created_at_ms)
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
  # {Sandbox.restore}.
  #
  # Runtime v0.7 descriptor contract: an artifact carries its own stable
  # {SnapshotInfo#id}, and the core chooses its directory (read it from
  # {SnapshotInfo#path}; it is no longer `dest_dir/<name>`). Artifacts written
  # by older gems are migrated automatically by the runtime on first use —
  # after which older gem versions can no longer read them.
  #
  # Snapshot groups (runtime v0.7): {create} publishes the artifact into a
  # group named after the source sandbox, as a member aliased `name`, and makes
  # it the group's head. Selectors passed to {open}/{get}/{verify}/{save}/
  # {remove} resolve as follows:
  #
  # - `"<group>"` (a bare name) — the group's current head;
  # - `"<group>:<member>"` — that member, e.g. `"#{from_sandbox}:#{name}"`;
  # - a snapshot id (`snap_…`) or descriptor digest (`sha256:…`);
  # - a path (anything containing `/` or starting with `.`).
  #
  # So the `name` given to {create} is NOT a selector on its own. Keep the
  # returned {SnapshotInfo#id} (or {SnapshotInfo#path}) instead. A {load}ed
  # archive lands in a fresh generated group with no head selected, so address
  # it by its {SnapshotInfo#id} or {SnapshotInfo#path}. Binding the group
  # surface itself (`group:`, head selection) is planned for a later release.
  class Snapshot
    class << self
      # Create a snapshot named `name` from a stopped sandbox.
      #
      # @param name [String] the member name alias inside the snapshot group
      #   (the group is named after `from_sandbox`; see the class notes on
      #   selectors — select it later as `"#{from_sandbox}:#{name}"` or by the
      #   returned {SnapshotInfo#id})
      # @param from_sandbox [String] name of the (stopped) source sandbox
      # @param dest_dir [String, nil] parent directory override (default: the
      #   snapshots dir); the core picks the artifact directory beneath it
      # @param labels [Hash, nil] user labels
      # @param force [Boolean] runtime v0.7 rejects it: grouped snapshots are
      #   immutable, so `force: true` raises {InvalidConfigError} — choose
      #   another name or {remove} the existing member first
      # @param record_integrity [Boolean] record persistent payload integrity
      #   (a Merkle content digest) in the artifact — opt-in since runtime
      #   v0.6.9 because hashing large allocated uppers is expensive; without
      #   it {Snapshot.verify} reports `:not_recorded`
      # @param full [Boolean] capture a full (memory + device) checkpoint
      #   instead of disk state only (runtime v0.7; the backend rejects it with
      #   {UnsupportedError} where full checkpoints are not available)
      # @param guest_flush [Symbol, String, nil] optional guest filesystem
      #   writeback before capture (runtime v0.7): `:auto` (the default:
      #   required for a live disk-only capture), `:required`, or `:skip`.
      #   Mandatory storage barriers apply either way; it does not flush
      #   application buffers. A stopped source cannot satisfy `:required`.
      # @param resumable [nil] removed in 0.18.0 — renamed to `full:` upstream;
      #   passing it raises ArgumentError
      # @return [SnapshotInfo]
      def create(name, from_sandbox:, dest_dir: nil, labels: nil, force: false,
        record_integrity: false, full: false, guest_flush: nil, resumable: nil)
        unless resumable.nil?
          raise ArgumentError, "Snapshot.create(resumable:) was renamed to full: in 0.18.0 (runtime v0.7)"
        end
        flush = normalize_guest_flush(guest_flush)
        opts = {"from_sandbox" => from_sandbox.to_s}
        opts["dest_dir"] = dest_dir.to_s if dest_dir
        opts["labels"] = stringify(labels) if labels
        opts["force"] = true if force
        opts["record_integrity"] = true if record_integrity
        opts["full"] = true if full
        opts["guest_flush"] = flush if flush
        SnapshotInfo.new(Native::Snapshot.create(name.to_s, opts))
      end

      # Open a snapshot artifact by selector or path (cheap metadata
      # validation; does not read the payload). Unlike {get}, this also
      # works for artifacts addressed by path that were never indexed, and it
      # returns the full descriptor.
      # @return [SnapshotInfo]
      def open(name_or_path)
        SnapshotInfo.new(Native::Snapshot.open(name_or_path.to_s))
      end

      # Index metadata for a snapshot by selector (see the class notes), id or
      # digest.
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

      # Remove a snapshot artifact by selector or path (see the class notes).
      # Removing a group's head leaves the group with no head selected.
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

      GUEST_FLUSH = %w[auto required skip].freeze
      private_constant :GUEST_FLUSH

      def normalize_guest_flush(value)
        return nil if value.nil?
        flush = (value.is_a?(Symbol) || value.is_a?(String)) ? value.to_s : nil
        return flush if GUEST_FLUSH.include?(flush)
        raise ArgumentError, "guest_flush: must be :auto, :required or :skip, got #{value.inspect}"
      end
    end
  end
end
