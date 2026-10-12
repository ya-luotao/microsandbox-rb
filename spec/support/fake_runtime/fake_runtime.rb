# frozen_string_literal: true

require "fileutils"
require "json"
require "rbconfig"

# Points the SDK's LOCAL backend at a fake `msb` (no microVM): a shell script
# that prints the startup JSON the core waits for and then becomes the fake
# agent relay in relay.rb. Everything above the process boundary is the real
# thing — the native extension, the core crate's spawn/connect/exec/stop paths,
# the parent-watchdog pipe — so a spec can observe what the Rust side actually
# did (a sandbox dropped, a connection closed) from the relay's log.
#
# This file has no RSpec dependency on purpose: a spec that needs a separate
# process (see interrupt_safety_spec's SIGINT case) requires it from a script.
#
# NOTE: `setup!` rewrites MSB_PATH / MSB_LIBKRUNFW_PATH for the whole process.
# The fake-runtime specs therefore run in their OWN rspec process
# (`rake spec:fake_runtime`), never alongside spec/unit, whose offline specs
# assert what happens when no runtime can be found.
module FakeRuntime
  RELAY = File.expand_path("relay.rb", __dir__)

  class << self
    attr_reader :home, :log_path, :rootfs

    # Prepare +home+ (an existing, SHORT directory: the agent socket lives under
    # it and Unix socket paths are limited to ~104 bytes) and point the SDK at
    # the fake runtime. Must run before the first native call.
    def setup!(home = ENV.fetch("MSB_HOME"))
      @home = home
      @rootfs = File.join(home, "rootfs")
      @log_path = File.join(home, "relay.log")
      FileUtils.mkdir_p(File.join(home, "lib"))
      # An empty directory is a valid "directory image" for the local backend.
      FileUtils.mkdir_p(@rootfs)
      # Metrics sampling off => the core never creates the POSIX shm metrics registry.
      File.write(File.join(home, "config.json"),
        JSON.generate({"sandbox_defaults" => {"metrics_sample_interval_ms" => 0}}))
      firmware = File.join(home, "lib", "libkrunfw.fake")
      File.write(firmware, "not a real libkrunfw\n")
      msb = File.join(home, "fake_msb")
      File.write(msb, msb_script)
      File.chmod(0o755, msb)
      FileUtils.touch(@log_path)
      ENV["MSB_HOME"] = home
      ENV["MSB_PATH"] = msb
      ENV["MSB_LIBKRUNFW_PATH"] = firmware
      ENV["FAKE_RELAY_LOG"] = @log_path
      self
    end

    # A booted (fake) local sandbox: the real Native::Sandbox over the fake relay.
    def create(name, **opts)
      Microsandbox::Native::Sandbox.create(name, native_opts(**opts))
    end

    # The string-keyed options Hash the native layer expects.
    def native_opts(**opts)
      {"image" => rootfs}.merge(opts.transform_keys(&:to_s))
    end

    # Run the block with the relay's timing knobs set (they are read by the relay
    # when it starts, i.e. by whatever sandbox boots inside the block).
    def with_relay_env(vars)
      saved = vars.keys.to_h { |k| [k, ENV[k]] }
      vars.each { |k, v| ENV[k] = v&.to_s }
      yield
    ensure
      saved&.each { |k, v| ENV[k] = v }
    end

    def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Poll until the block is truthy; returns its value, or nil on timeout.
    def wait_until(timeout, interval: 0.02)
      deadline = now + timeout
      loop do
        value = yield
        return value if value
        return nil if now >= deadline
        sleep interval
      end
    end

    def gc!(rounds = 3)
      rounds.times do
        GC.start(full_mark: true, immediate_sweep: true)
        sleep 0.05
      end
    end

    # ---- relay log --------------------------------------------------------

    # Current size of the relay log: pass it later as `since:` to look only at
    # what was logged after this point.
    def log_mark = File.size(log_path)

    def log_text(since: 0)
      File.binread(log_path, nil, since) || ""
    end

    def log_lines(since: 0) = log_text(since: since).lines

    # The pid of the relay serving sandbox +name+ (the most recent one), or nil
    # when no runtime was ever started for it. The relay logs its argv, which
    # carries the sandbox name; matching the quoted form keeps one name from
    # matching a longer one.
    def relay_pid_for(name)
      line = log_lines.reverse.find { |l| l.include?("started;") && l.include?(name.inspect) }
      line && line[/\[relay (\d+) /, 1].to_i
    end

    def wait_for_relay(name, timeout: 10)
      wait_until(timeout) { relay_pid_for(name) }
    end

    # The structural "the Rust Sandbox value was dropped" signal: the core closed
    # the parent-watchdog pipe, which only happens when the owning handle goes away.
    def watchdog_eof_seen?(pid) = relay_logged?(pid, "parent-watchdog EOF")

    # The relay was asked to shut down over the wire (an explicit stop).
    def shutdown_seen?(pid) = relay_logged?(pid, "core.shutdown")

    def torn_down?(pid) = watchdog_eof_seen?(pid) || shutdown_seen?(pid)

    def relay_logged?(pid, text)
      prefix = "[relay #{pid} "
      log_lines.any? { |l| l.start_with?(prefix) && l.include?(text) }
    end

    # `hang` exec sessions the relay opened / connections that closed while
    # still carrying one (each exec_stream owns one agent connection, so a
    # dropped ExecHandle shows up as exactly one such disconnect).
    def exec_sessions_opened(since: 0)
      log_text(since: since).scan(/exec\.request id=\d+ cmd="hang"/).size
    end

    def exec_sessions_closed(since: 0)
      log_text(since: since).scan(/client disconnected \(live exec sessions at disconnect: \[\d+\]/).size
    end

    # ---- processes --------------------------------------------------------

    # Zombie-proof liveness: `kill(pid, 0)` also succeeds for an exited child
    # nobody reaped yet, so ask ps for the state instead.
    def relay_running?(pid)
      state = IO.popen(["ps", "-o", "stat=", "-p", pid.to_s], err: File::NULL, &:read).strip
      !state.empty? && !state.start_with?("Z")
    end

    def relay_pids
      log_lines.filter_map { |l| l[/\[relay (\d+) .*started;/, 1]&.to_i }.uniq
    end

    # Kill every relay this process started that is still alive (spec cleanup,
    # and the safety net when an example fails before stopping its sandbox).
    def kill_relays!
      relay_pids.each do |pid|
        next unless relay_running?(pid)
        begin
          Process.kill("TERM", pid)
        rescue Errno::ESRCH, Errno::EPERM
          nil
        end
      end
    end

    private

    # The fake `msb`. `--version` must report the runtime version this gem pins
    # (the SDK checks it); anything else prints the startup JSON — the pid must
    # be the spawned child's own pid — and then becomes the relay. Bundler's
    # environment is dropped so the relay starts fast and needs only stdlib.
    def msb_script
      version = Microsandbox::RUNTIME_VERSION.delete_prefix("v")
      <<~SH
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "msb #{version}"; exit 0; fi
        echo "{\\"pid\\": $$}"
        unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLER_SETUP
        exec "#{RbConfig.ruby}" "#{RELAY}" "$@"
      SH
    end
  end
end
