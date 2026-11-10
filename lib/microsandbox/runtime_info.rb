# frozen_string_literal: true

module Microsandbox
  # The host runtime pair (`msb` + `libkrunfw`) local sandboxes would launch
  # with, from {Microsandbox.runtime_info}. Resolution reads files and the
  # environment only: nothing is downloaded, created or executed.
  class RuntimeInfo
    # @return [String] the `msb` executable
    attr_reader :msb_path
    # @return [String] the matching `libkrunfw` shared library
    attr_reader :libkrunfw_path

    # @api private
    def initialize(data)
      @msb_path = data.fetch("msb_path")
      @libkrunfw_path = data.fetch("libkrunfw_path")
      @origin = data.fetch("origin")
      @version_read = false
    end

    # Where the pair came from:
    #
    # - `:environment` — `MSB_PATH` (with `MSB_LIBKRUNFW_PATH` or the library
    #   next to it);
    # - `:sdk_package` — the companion `microsandbox-rb-binaries` gem;
    # - `:configuration` — `runtime_path=` / `libkrunfw_path=`, or the paths in
    #   the config file;
    # - `:home` — the runtime home (`MSB_HOME`, default `~/.microsandbox`);
    # - `:installed` — an explicit installer source.
    #
    # Gem-classified: runtime v0.7.14 layers `MSB_PATH` and the SDK path slots
    # into the configuration before it resolves, so it reports both as
    # `:configuration`; the SDK tells `:environment` and `:sdk_package` apart
    # by the resolved path (see docs/runtime.md).
    # @return [Symbol]
    def origin
      @origin.to_sym
    end

    # The runtime version embedded in the `msb` executable, read on first use
    # (the file is inspected, never run). nil for a pre-0.7 `msb` or a wrapper
    # script, neither of which carries one.
    # @return [String, nil] e.g. "0.7.14"
    def version
      unless @version_read
        @version = Native.msb_version(@msb_path)
        @version_read = true
      end
      @version
    end

    # Whether the `msb` carries no embedded version (a pre-0.7 runtime or a
    # wrapper script). Such a runtime is refused at every local sandbox start.
    def legacy? = version.nil?

    # Whether the `msb` is exactly the runtime this SDK was built for — the only
    # version the launch contract accepts.
    def matches_sdk? = version == RUNTIME_VERSION.delete_prefix("v")

    def inspect
      "#<Microsandbox::RuntimeInfo origin=#{@origin} msb_path=#{@msb_path.inspect} " \
        "libkrunfw_path=#{@libkrunfw_path.inspect}>"
    end
  end
end
