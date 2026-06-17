# frozen_string_literal: true

module Microsandbox
  # The result of a completed `exec`/`shell` call.
  #
  # `stdout`/`stderr` return the captured bytes decoded as UTF-8 (lenient — the
  # bytes are preserved even if they are not valid UTF-8); use `stdout_bytes`/
  # `stderr_bytes` for the raw ASCII-8BIT bytes.
  class ExecOutput
    # @return [Integer] the process exit code
    attr_reader :exit_code
    # @return [String] raw stdout bytes (ASCII-8BIT)
    attr_reader :stdout_bytes
    # @return [String] raw stderr bytes (ASCII-8BIT)
    attr_reader :stderr_bytes

    # @param data [Hash] the native exec result hash
    def initialize(data)
      @exit_code = data["exit_code"]
      @success = data["success"]
      @stdout_bytes = data["stdout"]
      @stderr_bytes = data["stderr"]
    end

    # @return [Boolean] whether the process exited with status 0
    def success?
      @success
    end

    # @return [Boolean] whether the process exited non-zero
    def failure?
      !@success
    end

    # @return [String] stdout decoded as UTF-8
    def stdout
      @stdout ||= @stdout_bytes.dup.force_encoding(Encoding::UTF_8)
    end

    # @return [String] stderr decoded as UTF-8
    def stderr
      @stderr ||= @stderr_bytes.dup.force_encoding(Encoding::UTF_8)
    end

    # @return [String] stdout decoded as UTF-8 (alias for {#stdout})
    def to_s
      stdout
    end

    def inspect
      "#<Microsandbox::ExecOutput exit_code=#{@exit_code} success=#{@success} " \
        "stdout=#{stdout.bytesize}B stderr=#{stderr.bytesize}B>"
    end
  end
end
