# frozen_string_literal: true

module Microsandbox
  # Collects sandbox VM processes that runtime v0.7.14 leaves unreaped on Linux
  # ([superradcompany/microsandbox#1950](https://github.com/superradcompany/microsandbox/issues/1950)).
  #
  # A sandbox VM is a direct child of the process that started it. Upstream
  # waits for attached VMs, but after a detached one stops (`detached: true`,
  # {Sandbox#detach}, a no-block {Sandbox.restore}) nobody calls `waitpid`, so
  # it stays `<defunct>` until this process exits. Upstream fixed it in #1953,
  # which shipped only with runtime v0.8; this is the v0.7 stopgap.
  #
  # A background thread scans this process's children every {INTERVAL}
  # seconds and collects one only when all of these hold:
  #
  # - it is a zombie (it has already exited, so collecting it signals nothing);
  # - its name is the VM's (`libkrun VM`, `VM:<hostname>`, or `msb` before
  #   libkrun renames it), so children the application spawned itself are left
  #   alone;
  # - it has stayed a zombie for at least {GRACE} seconds, so the runtime's own
  #   wait on a VM it still tracks (a retained handle's stop) gets there first.
  #
  # Each zombie is collected with `waitpid(pid, WNOHANG)` on its own pid, never
  # `waitpid(-1)`. Linux only: macOS reaps these children already. Set
  # `MICROSANDBOX_NO_CHILD_REAPER` to turn it off.
  #
  # @api private
  module ChildReaper
    # Seconds between scans.
    INTERVAL = 15
    # Seconds a VM child must stay a zombie before it is collected.
    GRACE = 30
    # `comm` values of a sandbox VM process.
    VM_COMMS = ["libkrun VM", "msb"].freeze
    # `comm` prefix libkrun uses when `HOSTNAME` is set.
    VM_COMM_PREFIX = "VM:"
    # Opt-out environment variable.
    DISABLE_ENV = "MICROSANDBOX_NO_CHILD_REAPER"

    LOCK = Mutex.new
    private_constant :LOCK

    @thread = nil
    @owner_pid = nil
    @first_seen = {}

    class << self
      # Start the reaper thread once per process (again after a fork). A no-op
      # off Linux or when {DISABLE_ENV} is set.
      # @return [Boolean] whether a reaper thread is running for this process
      def ensure_started
        return false unless enabled?
        return true if running?

        LOCK.synchronize do
          return true if running?

          @owner_pid = Process.pid
          @first_seen = {}
          @thread = Thread.new { run_loop }
          @thread.name = "microsandbox-child-reaper" if @thread.respond_to?(:name=)
          @thread.report_on_exception = false
        end
        true
      end

      # @return [Boolean]
      def enabled?
        linux? && ENV.fetch(DISABLE_ENV, "").empty?
      end

      # @return [Boolean]
      def running?
        @owner_pid == Process.pid && @thread&.alive? || false
      end

      # One scan: collect every VM zombie child that has been a zombie for
      # {GRACE} seconds. Remembers the others for the next scan.
      # @param now [Float] monotonic seconds
      # @param proc_root [String]
      # @return [Array<Integer>] the pids collected
      def reap_once(now: Process.clock_gettime(Process::CLOCK_MONOTONIC), proc_root: "/proc")
        zombies = vm_zombie_children(proc_root: proc_root)
        @first_seen.select! { |pid, _| zombies.include?(pid) }
        zombies.filter_map do |pid|
          seen = (@first_seen[pid] ||= now)
          next if now - seen < GRACE

          @first_seen.delete(pid)
          pid if collect(pid)
        end
      end

      # Zombie VM processes whose parent is this process.
      # @param proc_root [String]
      # @return [Array<Integer>]
      def vm_zombie_children(proc_root: "/proc", parent: Process.pid)
        child_pids(proc_root, parent).select do |pid|
          stat = read_stat(proc_root, pid)
          stat && stat[:state] == "Z" && stat[:ppid] == parent && vm_comm?(stat[:comm])
        end
      end

      # @param comm [String]
      # @return [Boolean]
      def vm_comm?(comm)
        VM_COMMS.include?(comm) || comm.start_with?(VM_COMM_PREFIX)
      end

      private

      def linux?
        RUBY_PLATFORM.include?("linux")
      end

      def run_loop
        loop do
          sleep INTERVAL
          break unless @owner_pid == Process.pid

          begin
            reap_once
          rescue => e
            warn "[microsandbox] child reaper scan failed: #{e.class}: #{e.message}"
          end
        end
      end

      def collect(pid)
        Process.waitpid(pid, Process::WNOHANG)
        true
      rescue Errno::ECHILD
        false # collected by someone else in the meantime
      end

      # Direct children of +parent+. `/proc/<pid>/task/*/children` lists them
      # without scanning every process; fall back to a scan when the kernel
      # lacks it (CONFIG_PROC_CHILDREN).
      def child_pids(proc_root, parent)
        files = Dir.glob(File.join(proc_root, parent.to_s, "task", "*", "children"))
        if files.empty?
          Dir.children(proc_root).filter_map { |e| Integer(e, exception: false) }
        else
          files.flat_map { |f| File.read(f).split.map { |p| Integer(p) } }.uniq
        end
      rescue SystemCallError
        []
      end

      # Parses `/proc/<pid>/stat`. `comm` sits in parentheses and may itself
      # contain spaces and parentheses, so split after the LAST `)`.
      def read_stat(proc_root, pid)
        raw = File.read(File.join(proc_root, pid.to_s, "stat"))
        open = raw.index("(")
        close = raw.rindex(")")
        return nil unless open && close

        fields = raw[(close + 2)..].split
        {comm: raw[(open + 1)...close], state: fields[0], ppid: Integer(fields[1])}
      rescue SystemCallError, ArgumentError, TypeError
        nil
      end
    end
  end
end
