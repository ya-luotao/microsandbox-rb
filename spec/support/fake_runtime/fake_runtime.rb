# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "shellwords"
require "tmpdir"

# Points the SDK's LOCAL backend at a fake `msb` (no microVM) that speaks the
# v0.7 machine launch contract: a tiny compiled stub (fake_msb) carrying the
# `.msbver` section the core reads the runtime version from, which execs a
# shell script (fake_msb.sh) that answers `__launch-protocol`, prints the
# startup JSON the core waits for and then becomes the fake agent relay in
# relay.rb. Everything above the process boundary is the real
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

    # Capability sets `fake_msb __launch-protocol` can advertise. :default is
    # what a real v0.7.14 msb reports on a host without nested virtualization;
    # the others each withdraw one capability the SDK checks before launch.
    CAPABILITIES = {
      "storage_reader" => true, "protected_guest_state" => true, "protocols" => [2, 1],
      "required_restore_backing" => true, "tcp_accept_queue_size" => true,
      "max_inbound_tcp_connections" => true, "http_deny_message" => true,
      "http_deny_json" => true, "http_connect_proxy" => true,
      "http_connect_proxy_auth" => true, "guest_clock" => true, "fs_state_limit" => true,
      "nested_virt" => false, "exec_limits" => true
    }.freeze
    CAPABILITY_VARIANTS = {
      default: {},
      no_protected: {"protected_guest_state" => false},
      no_http_json: {"http_deny_json" => false},
      no_http_text: {"http_deny_message" => false}
    }.freeze

    # Prepare +home+ (an existing, SHORT directory: the agent socket lives under
    # it and Unix socket paths are limited to ~104 bytes) and point the SDK at
    # the fake runtime. Must run before the first native call: the local
    # backend captures MSB_PATH once, so a different capability set needs a
    # separate process (see launch_probe.rb).
    def setup!(home = ENV.fetch("MSB_HOME"), capabilities: :default)
      @home = home
      @rootfs = File.join(home, "rootfs")
      @log_path = File.join(home, "relay.log")
      FileUtils.mkdir_p(File.join(home, "lib"))
      # An empty directory is a valid "directory image" for the local backend.
      FileUtils.mkdir_p(@rootfs)
      # Runtime v0.7.14 creates <home>/sandboxes/<name> with a non-recursive
      # mkdir; only the OCI path creates <home>/sandboxes first. A fresh home
      # with a directory image therefore fails with ENOENT, so lay it out here.
      FileUtils.mkdir_p(File.join(home, "sandboxes"))
      # Metrics sampling off => the core never creates the POSIX shm metrics registry.
      File.write(File.join(home, "config.json"),
        JSON.generate({"sandbox_defaults" => {"metrics_sample_interval_ms" => 0}}))
      firmware = File.join(home, "lib", "libkrunfw.fake")
      File.write(firmware, "not a real libkrunfw\n")
      msb = install_msb(home, capabilities: capabilities)
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

    # Write the fake runtime into +dir+ and return the executable's path.
    def install_msb(dir, capabilities: :default)
      overrides = CAPABILITY_VARIANTS.fetch(capabilities.to_sym) do
        raise ArgumentError, "unknown capability variant #{capabilities.inspect}"
      end
      File.write(File.join(dir, "fake_msb.sh"), msb_script(CAPABILITIES.merge(overrides)))
      msb = File.join(dir, "fake_msb")
      FileUtils.cp(stub_binary, msb)
      File.chmod(0o755, msb)
      msb
    end

    # The compiled stub, built once per stub source and reused across homes and
    # child processes (keyed by a digest of the source, which embeds the version).
    def stub_binary
      source = stub_source
      digest = Digest::SHA256.hexdigest(source + RbConfig::CONFIG["CC"].to_s)[0, 16]
      out = File.join(stub_cache_dir, "fake_msb-#{digest}")
      return out if File.executable?(out)
      FileUtils.mkdir_p(stub_cache_dir)
      src = "#{out}.#{Process.pid}.c"
      tmp = "#{out}.#{Process.pid}.tmp"
      File.write(src, source)
      cc = Shellwords.split(RbConfig::CONFIG["CC"].to_s)
      cc = ["cc"] if cc.empty?
      _o, err, status = Open3.capture3(*cc, "-O0", "-o", tmp, src)
      raise "fake runtime: compiling the msb stub failed (#{cc.join(" ")}):\n#{err}" unless status.success?
      File.rename(tmp, out) # atomic: a concurrent builder never sees a partial binary
      out
    ensure
      FileUtils.rm_f([src, tmp].compact) if src
    end

    def stub_cache_dir = File.join(File.realpath(Dir.tmpdir), "msb-rb-fake-stub")

    # A C program whose only jobs are to carry the runtime version in the
    # section the core reads it from (`__TEXT,__msbver` on Mach-O, `.msbver` on
    # ELF: exactly the version bytes, no NUL), and to exec /bin/sh on the
    # fake_msb.sh next to its own executable. A plain `#!` script would be
    # treated as a version-less wrapper, which takes a different launch path.
    def stub_source
      version = Microsandbox::RUNTIME_VERSION.delete_prefix("v")
      <<~C
        #include <limits.h>
        #include <stdio.h>
        #include <stdlib.h>
        #include <string.h>
        #include <unistd.h>
        #ifdef __APPLE__
        #include <mach-o/dyld.h>
        #define MSBVER_SECTION "__TEXT,__msbver"
        #else
        #define MSBVER_SECTION ".msbver"
        #endif

        __attribute__((used, section(MSBVER_SECTION)))
        static const char msbver[#{version.bytesize}] = "#{version}";

        static int self_path(char *out) {
          char raw[PATH_MAX];
        #ifdef __APPLE__
          uint32_t size = sizeof raw;
          if (_NSGetExecutablePath(raw, &size) != 0) return -1;
        #else
          ssize_t n = readlink("/proc/self/exe", raw, sizeof raw - 1);
          if (n < 0) return -1;
          raw[n] = 0;
        #endif
          return realpath(raw, out) ? 0 : -1;
        }

        int main(int argc, char **argv) {
          char exe[PATH_MAX], script[PATH_MAX + 4];
          if (self_path(exe) != 0) { perror("fake msb: own path"); return 127; }
          snprintf(script, sizeof script, "%s.sh", exe);
          char **args = calloc((size_t)argc + 2, sizeof *args);
          if (!args) return 127;
          args[0] = "/bin/sh";
          args[1] = script;
          for (int i = 1; i < argc; i++) args[i + 1] = argv[i];
          execv("/bin/sh", args);
          perror("fake msb: execv /bin/sh");
          return 127;
        }
      C
    end

    # The fake `msb`'s behaviour. `--version` and `__launch-protocol` answer the
    # core's launch-contract probes; anything else is a `msb machine` launch:
    # print the startup JSON — the pid must be the spawned child's own pid — on
    # the startup fd when the core passed one (detached launches) or on stdout,
    # then become the relay. Bundler's environment is dropped so the relay
    # starts fast and needs only stdlib.
    def msb_script(capabilities)
      version = Microsandbox::RUNTIME_VERSION.delete_prefix("v")
      <<~SH
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo "msb #{version}"; exit 0; fi
        if [ "$1" = "__launch-protocol" ]; then echo '#{JSON.generate(capabilities)}'; exit 0; fi
        startup_fd=""
        prev=""
        for arg in "$@"; do
          if [ "$prev" = "--startup-fd" ]; then startup_fd="$arg"; fi
          prev="$arg"
        done
        if [ -n "$startup_fd" ]; then
          printf '{"pid": %s}\\n' "$$" >&"$startup_fd"
        else
          printf '{"pid": %s}\\n' "$$"
        fi
        unset RUBYOPT RUBYLIB BUNDLE_GEMFILE BUNDLER_SETUP
        exec "#{RbConfig.ruby}" "#{RELAY}" "$@"
      SH
    end
  end
end
