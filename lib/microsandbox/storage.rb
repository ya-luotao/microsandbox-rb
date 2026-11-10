# frozen_string_literal: true

require "json"

module Microsandbox
  # One complete disk view a storage inspection found, for an explicit
  # {Sandbox.recover_storage} selection. The id is opaque and is revalidated
  # under locks when used.
  class StorageCandidate
    # @return [String] the candidate id to pass in `selections:`
    attr_reader :id
    # @return [String] `"root"` or the owned-volume mount id
    attr_reader :disk_id
    # @return [Integer] number of authorized layers
    attr_reader :layers
    # @return [Integer] guest-visible capacity in bytes
    attr_reader :virtual_size
    # @return [Integer] conservative bytes a recovery would stage
    attr_reader :estimated_bytes

    # @api private
    def initialize(data)
      @id = data["id"]
      @disk_id = data["disk_id"]
      @layers = data["layers"]
      @virtual_size = data["virtual_size"]
      @estimated_bytes = data["estimated_bytes"]
    end

    def inspect
      "#<Microsandbox::StorageCandidate id=#{@id.inspect} disk_id=#{@disk_id.inspect}>"
    end
  end

  # The storage engine's (provisional) inspection of one sandbox.
  class StorageInspection
    # @return [Symbol, nil] the engine's migration classification
    attr_reader :status
    # @return [Array<String>] actionable reasons
    attr_reader :reasons
    # @return [Array<StorageCandidate>]
    attr_reader :candidates
    # @return [Integer, nil] conservative bytes a recovery would stage
    attr_reader :estimated_bytes

    # @api private
    def initialize(data)
      @status = data["status"]&.to_sym
      @reasons = Array(data["reasons"])
      @candidates = Array(data["candidates"]).map { |c| StorageCandidate.new(c) }
      @estimated_bytes = data["estimated_bytes"]
      @preview_available = data["preview_available"] == true
    end

    # Whether a recovery preview is available.
    def preview_available? = @preview_available

    def inspect
      "#<Microsandbox::StorageInspection status=#{@status.inspect} candidates=#{@candidates.size}>"
    end
  end

  # One requested sandbox's storage diagnosis.
  class StorageSandboxDiagnosis
    # @return [String]
    attr_reader :name
    # @return [Symbol] `:ready`, `:eligible`, `:maintenance_required`,
    #   `:recovery_required`, `:in_progress` or `:unavailable`
    attr_reader :status
    # @return [Symbol, nil] why the check could not finish: `:not_found`,
    #   `:invalid_configuration`, `:incomplete_creation` or
    #   `:storage_unavailable`
    attr_reader :reason
    # @return [StorageInspection, nil]
    attr_reader :inspection
    # @return [Hash{String=>String}] guest mount path per disk id
    attr_reader :guest_mounts

    # @api private
    def initialize(data)
      @name = data["name"]
      @status = data["status"]&.to_sym
      @running = data["running"] == true
      @protection_registered = data["protection_registered"] == true
      @reason = data["reason"]&.to_sym
      @inspection = data["inspection"] && StorageInspection.new(data["inspection"])
      @guest_mounts = data["guest_mounts"] || {}
    end

    # Whether the catalog records a running VM (the report is then provisional).
    def running? = @running

    # Whether the sandbox's storage is registered for protection.
    def protection_registered? = @protection_registered

    def inspect
      "#<Microsandbox::StorageSandboxDiagnosis name=#{@name.inspect} status=#{@status.inspect}" \
        "#{" reason=#{@reason.inspect}" if @reason}>"
    end
  end

  # The result of {Microsandbox.diagnose_storage}.
  class StorageDiagnosis
    # @return [String] the runtime home that was inspected
    attr_reader :home
    # @return [Array<StorageSandboxDiagnosis>]
    attr_reader :sandboxes
    # @return [String] the runtime capability a protected start requires
    attr_reader :required_runtime_capability

    # @api private
    def initialize(data)
      @home = data["home"]
      @sandboxes = Array(data["sandboxes"]).map { |item| StorageSandboxDiagnosis.new(item) }
      @required_runtime_capability = data["required_runtime_capability"]
    end

    def inspect
      "#<Microsandbox::StorageDiagnosis home=#{@home.inspect} sandboxes=#{@sandboxes.map(&:name).inspect}>"
    end
  end

  # The result of {Sandbox.recover_storage}.
  class StorageRecovery
    # @return [String]
    attr_reader :name

    # @api private
    def initialize(data)
      @name = data["name"]
      @ready = data["ready"] == true
      @originals_retained = data["originals_retained"] == true
    end

    # Whether the sandbox's storage is now in the protected layout.
    def ready? = @ready

    # Whether the original legacy disks were kept (the runtime always keeps them).
    def originals_retained? = @originals_retained

    def inspect
      "#<Microsandbox::StorageRecovery name=#{@name.inspect} ready=#{@ready}>"
    end
  end

  class << self
    # Inspect the runtime-`v0.7` storage state of sandboxes in the local
    # runtime home. Never starts, stops, repairs or migrates anything; the
    # report is provisional (a recovery revalidates under locks). Pick exactly
    # one scope.
    #
    # @param names [Array<String>, nil] sandboxes to inspect
    # @param all_sandboxes [Boolean] inspect every sandbox in the catalog
    # @param home [String, nil] runtime home to inspect (default: the
    #   configured one)
    # @return [StorageDiagnosis]
    def diagnose_storage(names: nil, all_sandboxes: false, home: nil)
      unless (all_sandboxes == true) ^ !names.nil?
        raise ArgumentError, "diagnose_storage: pass names: or all_sandboxes: true (exactly one)"
      end
      unless all_sandboxes
        names = Array(names).map(&:to_s)
        raise ArgumentError, "diagnose_storage: names: must not be empty" if names.empty?
      end
      scope = all_sandboxes ? "all" : {"named" => names}
      config = home.nil? ? {} : {"home" => home.to_s}
      StorageDiagnosis.new(JSON.parse(Native::Storage.diagnose_json(JSON.generate(config), JSON.generate(scope))))
    end
  end

  class Sandbox
    class << self
      # Import or resume a **stopped** sandbox's storage into the runtime
      # `v0.7` protected layout without booting it (runtime `v0.7`). On Linux
      # an older sandbox migrates on its next start; on macOS, or when
      # {Microsandbox.diagnose_storage} reports `:recovery_required`, run this
      # first. The original legacy disks are kept.
      #
      # @param name [String] the stopped sandbox
      # @param selections [Hash{String=>String}] for ambiguous or damaged
      #   legacy metadata: disk id (`"root"` or an owned-volume mount id) =>
      #   candidate id from {Microsandbox.diagnose_storage}
      # @param accept_selected_view [Boolean] required with `selections:`:
      #   acknowledge that the selected view may omit later writes
      # @param legacy_writers_stopped [Boolean] macOS: confirm that every
      #   pre-0.18 VM in every runtime home has stopped and that no older tool
      #   will touch this storage until recovery finishes. Never inferred.
      # @return [StorageRecovery]
      def recover_storage(name, selections: {}, accept_selected_view: false, legacy_writers_stopped: false)
        unless selections.is_a?(Hash)
          raise ArgumentError, "recover_storage: selections: must be a Hash of disk id => candidate id"
        end
        options = {
          "selections" => selections.map { |disk, candidate| {"disk_id" => disk.to_s, "candidate_id" => candidate.to_s} },
          "accept_selected_view" => accept_selected_view == true,
          "legacy_writers_stopped" => legacy_writers_stopped == true
        }
        sandbox_name = name.to_s
        # The recovery checks the runtime's launch contract, like a start.
        Microsandbox.ensure_runtime!
        StorageRecovery.new(JSON.parse(Native::Storage.recover_json(sandbox_name, JSON.generate(options))))
      end
    end
  end
end
