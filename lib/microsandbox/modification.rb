# frozen_string_literal: true

module Microsandbox
  # The result of {Sandbox#ping} / {SandboxHandle#ping}: a lightweight health
  # check that confirms the guest agent is reachable without refreshing the
  # sandbox idle timer. Mirrors the official SDKs' `SandboxPingResult`.
  #
  # The native layer reports latency as seconds; {#latency} is the canonical
  # value and {#latency_ms} the convenience the Python/Node SDKs expose.
  class PingResult
    # @return [String] the sandbox name that was pinged
    attr_reader :name
    # @return [Float] round-trip latency in seconds
    attr_reader :latency

    def initialize(data)
      @name = data["name"]
      @latency = data["latency_secs"]
    end

    # @return [Float] round-trip latency in milliseconds
    def latency_ms
      @latency * 1000.0
    end

    def inspect
      "#<Microsandbox::PingResult name=#{@name.inspect} latency_ms=#{format("%.3f", latency_ms)}>"
    end
  end

  # The result of {Sandbox#touch} / {SandboxHandle#touch}: an explicit refresh of
  # the sandbox idle-activity timer. Mirrors the official SDKs' `SandboxTouchResult`.
  class TouchResult
    # @return [String] the sandbox name that was touched
    attr_reader :name
    # @return [Integer] the agent activity sequence after this touch was recorded
    attr_reader :activity_seq

    def initialize(data)
      @name = data["name"]
      @activity_seq = data["activity_seq"]
    end

    def inspect
      "#<Microsandbox::TouchResult name=#{@name.inspect} activity_seq=#{@activity_seq}>"
    end
  end

  # The plan produced by {Sandbox#modify} / {SandboxHandle#modify}: the classified
  # set of changes a modification requested, and (for a non-dry-run apply) whether
  # they were applied plus any live-resize convergence outcomes. Mirrors the
  # official SDKs' `SandboxModificationPlan`.
  #
  # The nested collections ({#changes}, {#conflicts}, {#warnings},
  # {#resize_status}) are frozen Arrays of frozen, symbol-keyed Hashes carrying
  # the canonical snake_case fields verbatim (e.g. a config change is
  # `{ kind: "config", field:, change:, before:, after:, disposition:, reason: }`;
  # a secret change adds `name:`, `before_ref:`, `after_ref:`, `allow_hosts:`).
  # Enum values stay as the runtime's strings (e.g. a `disposition` of
  # `"next start"`, a `state` of `"guest-refused"`).
  class ModificationPlan
    # @return [String] the sandbox the plan applies to
    attr_reader :sandbox
    # @return [String] the sandbox status used to classify the changes
    attr_reader :status
    # @return [Symbol] :no_restart, :next_start, or :restart
    attr_reader :policy
    # @return [Array<Hash>] the planned changes (config and secret)
    attr_reader :changes
    # @return [Array<Hash>] conflicts that must be resolved before applying
    attr_reader :conflicts
    # @return [Array<Hash>] non-fatal warnings about the patch
    attr_reader :warnings
    # @return [Array<Hash>] live resource-resize outcomes (populated by an apply)
    attr_reader :resize_status

    def initialize(data)
      @sandbox = data["sandbox"]
      @status = data["status"]
      @applied = data["applied"]
      @policy = data["policy"]&.to_sym
      @changes = freeze_items(data["changes"])
      @conflicts = freeze_items(data["conflicts"])
      @warnings = freeze_items(data["warnings"])
      @resize_status = freeze_items(data["resize_status"])
    end

    # @return [Boolean] whether the changes were applied (false for a dry run)
    def applied?
      @applied
    end

    def inspect
      "#<Microsandbox::ModificationPlan sandbox=#{@sandbox.inspect} applied=#{@applied} " \
        "policy=#{@policy} changes=#{@changes.size} conflicts=#{@conflicts.size} " \
        "warnings=#{@warnings.size}>"
    end

    private

    # Convert a JSON array of plan entries (string-keyed Hashes) into a frozen
    # Array of frozen, symbol-keyed Hashes. The entries are shallow (all values
    # are scalars or string arrays), so a single `transform_keys` suffices.
    def freeze_items(items)
      Array(items).map { |item| item.transform_keys(&:to_sym).freeze }.freeze
    end
  end
end
