# frozen_string_literal: true

require_relative "fake_runtime_helper"
require "open3"
require "rbconfig"
require "timeout"
require "tmpdir"

# An interrupt (Thread#raise — what Timeout.timeout uses —, Thread#kill, or the
# main thread's SIGINT) that arrives while a native call is in flight must not
# lose the call's result. The native calls stay uninterruptible, so the
# interrupt is delivered only after the call has returned; what these examples
# pin is that the value the call produced is then either returned to Ruby or
# dropped by Rust — never abandoned with a sandbox, a guest session or a
# connection still attached to it.
#
# Every interrupted call runs in its own Thread so the example can observe it,
# every wait is bounded, and "the call is in flight" is established from the
# fake relay's log (a line the relay writes while the native call is blocked on
# it) rather than from a sleep.
RSpec.describe "interrupted native calls", :fake_runtime do
  # Seconds the fake relay holds a call up: long enough that the interrupt is
  # certainly sent while the call is blocked.
  def slow = "0.4"

  def rootfs = FakeRuntime.rootfs

  # Run the block in a thread. When +ready+ is given — a Queue the block pushes
  # `true` to once its setup is done — the thread also reports there when it
  # ends, however it ends: an unexpected error is pushed (and re-raised), then
  # a `:finished` marker. `await` can therefore never be left waiting on a
  # worker that failed, or returned, before it signalled readiness.
  def in_thread(ready = nil, &block)
    Thread.new do
      Thread.current.report_on_exception = false
      begin
        block.call
      rescue Exception => e # standard:disable Lint/RescueException -- handed to the observer, then re-raised
        ready&.push(e)
        raise
      ensure
        ready&.push(:finished)
      end
    end
  end

  # Bounded wait for a worker's readiness signal (see `in_thread`). Fails fast
  # with the worker's own error when its setup raised.
  def await(ready, what)
    signal = begin
      Timeout.timeout(10) { ready.pop }
    rescue Timeout::Error
      raise "#{what}: the worker did not signal readiness within 10s"
    end
    raise signal if signal.is_a?(Exception)
    expect(signal).to be(true), "#{what}: the worker finished before signalling readiness"
  end

  # Thread#join with a hard bound; a thread still alive after it is hung or spinning.
  def finish(thread, what)
    expect(thread.join(10)).to be(thread), "#{what} did not finish within 10s (hung or spinning)"
    thread
  end

  # Run a child process to completion with a hard bound; a child still running
  # after it is killed, not abandoned. Returns [stdout, stderr, status].
  def run_child(env, *command, timeout: 60)
    Open3.popen3(env, *command) do |stdin, stdout, stderr, waiter|
      stdin.close
      unless waiter.join(timeout)
        Process.kill("KILL", waiter.pid)
        waiter.join
        raise "child process did not finish within #{timeout}s (killed): #{stderr.read}"
      end
      [stdout.read, stderr.read, waiter.value]
    end
  end

  def without_gc
    GC.disable
    yield
  ensure
    GC.enable
  end

  # Wait for the relay of +name+ to log its start: the native create is then
  # blocked on the (delayed) boot handshake, i.e. provably in flight.
  def in_flight_relay(name)
    pid = FakeRuntime.wait_for_relay(name)
    expect(pid).not_to be_nil, "the fake runtime for #{name} never started; the call was not in flight"
    pid
  end

  # Wait for a new relay log line matching +pattern+ after +mark+.
  def wait_for_log(pattern, since:, timeout: 10)
    found = FakeRuntime.wait_until(timeout) { FakeRuntime.log_text(since: since)[pattern] }
    expect(found).not_to be_nil, "the relay never logged #{pattern.inspect}; the call was not in flight"
    found
  end

  def live_sandboxes(name)
    ObjectSpace.each_object(Microsandbox::Sandbox).count { |sb| sb.name == name }
  end

  def expect_torn_down(pid, within:, leak:, gc: false)
    done = FakeRuntime.wait_until(within) do
      FakeRuntime.gc!(1) if gc
      FakeRuntime.torn_down?(pid)
    end
    expect(done).to be(true), "LEAKED: #{leak} (relay #{pid} saw neither core.shutdown nor a parent-watchdog EOF " \
      "within #{within}s#{" of GC" if gc})"
  end

  describe "a call that returns normally (control)" do
    it "drops the sandbox when the only reference is collected" do
      name = unique_sandbox_name("fr-ctl")
      finish(in_thread do
        FakeRuntime.create(name)
        nil
      end, "create")
      pid = FakeRuntime.relay_pid_for(name)
      expect(pid).not_to be_nil
      expect_torn_down(pid, within: 3, gc: true, leak: "the collected sandbox #{name} is still attached")
    end
  end

  describe "an interrupt that is pending, but masked, when the call starts" do
    # NOTE: this proves "no hang, the call completes, the exception arrives
    # after the mask". Nothing in Ruby can deterministically force the native
    # loop's "an interrupt was pending at entry, the callback was skipped"
    # branch, so this example does not prove that branch ran.
    it "runs the call to completion without spinning and raises after the mask (does not prove the skipped-at-entry branch ran)" do
      name = unique_sandbox_name("fr-masked")
      ready = Queue.new
      go = Queue.new
      native = nil
      pending_at_entry = nil
      thread = in_thread(ready) do
        Thread.handle_interrupt(RuntimeError => :never) do
          ready << true
          Timeout.timeout(10) { go.pop }
          pending_at_entry = Thread.pending_interrupt?
          native = FakeRuntime.create(name)
        end
        :no_exception
      rescue RuntimeError => e
        e.message
      end
      await(ready, "masked create")
      thread.raise(RuntimeError, "queued before the call")
      go << true
      finish(thread, "masked create")

      expect(pending_at_entry).to be(true)
      expect(native).to be_a(Microsandbox::Native::Sandbox)
      expect(thread.value).to eq("queued before the call")
      native.stop # control: the test owns it, nothing leaked
      expect(FakeRuntime.shutdown_seen?(FakeRuntime.relay_pid_for(name))).to be(true)
    end
  end

  describe "an interrupt during Microsandbox::Sandbox.create" do
    around do |example|
      FakeRuntime.with_relay_env("FAKE_RELAY_BOOT_DELAY" => slow) { example.run }
    end

    it "Thread#raise: the caller sees the exception and the sandbox is stopped, without waiting for GC" do
      name = unique_sandbox_name("fr-raise")
      without_gc do
        thread = in_thread do
          Microsandbox::Sandbox.create(name, image: rootfs)
          :returned
        rescue RuntimeError => e
          e.message
        end
        pid = in_flight_relay(name)
        thread.raise(RuntimeError, "simulated interrupt")
        finish(thread, "interrupted create")
        expect(thread.value).to eq("simulated interrupt")
        expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
        expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
      end
      FakeRuntime.gc!
      expect(live_sandboxes(name)).to eq(0)
    end

    it "Timeout.timeout: Timeout::Error is raised once the create has finished, and the sandbox is stopped" do
      name = unique_sandbox_name("fr-timeout")
      without_gc do
        started = FakeRuntime.now
        thread = in_thread do
          Timeout.timeout(0.05) { Microsandbox::Sandbox.create(name, image: rootfs) }
          :returned
        rescue Timeout::Error
          :timeout
        end
        finish(thread, "create under Timeout.timeout")
        expect(thread.value).to eq(:timeout)
        # The native call is uninterruptible: the timeout cannot fire early.
        expect(FakeRuntime.now - started).to be >= slow.to_f
        pid = FakeRuntime.relay_pid_for(name)
        expect(pid).not_to be_nil, "the fake runtime for #{name} never started; the timeout fired before the call"
        expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
        expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
      end
      FakeRuntime.gc!
      expect(live_sandboxes(name)).to eq(0)
    end

    # A kill sent from another thread is queued like a Thread#raise, and
    # `handle_interrupt(Object => :never)` holds it back too — so the cleanup
    # in Sandbox.create is as deterministic as for an exception.
    it "Thread#kill: the thread dies and the sandbox is stopped, without waiting for GC" do
      name = unique_sandbox_name("fr-kill")
      without_gc do
        thread = in_thread do
          Microsandbox::Sandbox.create(name, image: rootfs)
          :returned
        end
        pid = in_flight_relay(name)
        thread.kill
        finish(thread, "killed create")
        expect(thread.status).to be(false)
        expect(thread.value).to be_nil
        expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
        expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
      end
      FakeRuntime.gc!
      expect(live_sandboxes(name)).to eq(0)
    end

    it "SIGINT on the main thread (separate process): Interrupt is raised and the sandbox is torn down" do
      Dir.mktmpdir("msb-rb-", "/tmp") do |home|
        name = unique_sandbox_name("fr-int")
        script = File.expand_path("../support/fake_runtime/sigint_create.rb", __dir__)
        env = {"MSB_HOME" => home, "MSB_PATH" => nil, "MSB_LIBKRUNFW_PATH" => nil,
               "FAKE_RELAY_LOG" => nil, "FAKE_RELAY_BOOT_DELAY" => slow}
        out, err, status = run_child(env, RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), script, home, name)
        expect(status).to be_success, "child failed: #{err}\n#{out}"
        report = JSON.parse(out.lines.last)
        expect(report["outcome"]).to eq("interrupt"), out
        expect(report["relay_started"]).to be(true), out
        expect(report["torn_down"]).to be(true),
          "LEAKED: sandbox #{name} was still attached after the Interrupt and GC\n#{out}\n#{err}"
        expect(report["live_sandboxes"]).to eq(0)
      end
    end

    it "still lets a caller-side Thread.handle_interrupt(Object => :never) keep the handle" do
      name = unique_sandbox_name("fr-mask")
      thread = in_thread do
        sandbox = nil
        begin
          Thread.handle_interrupt(Object => :never) do
            sandbox = Microsandbox::Sandbox.create(name, image: rootfs)
          end
          :no_interrupt
        rescue RuntimeError
          assigned = !sandbox.nil?
          sandbox&.stop
          [:stopped_in_rescue, assigned]
        end
      end
      pid = in_flight_relay(name)
      thread.raise(RuntimeError, "simulated interrupt")
      finish(thread, "masked create")
      expect(thread.value).to eq([:stopped_in_rescue, true])
      expect(FakeRuntime.shutdown_seen?(pid)).to be(true)
    end
  end

  describe "an interrupt during the native create itself (no Ruby-level cleanup involved)" do
    around do |example|
      FakeRuntime.with_relay_env("FAKE_RELAY_BOOT_DELAY" => slow) { example.run }
    end

    # Pins the native half on its own: nothing stops this sandbox explicitly,
    # so it is torn down only if the Rust value was handed to Ruby (and then
    # collected) instead of being abandoned by the interrupt.
    it "hands the sandbox to Ruby, so GC drops it" do
      name = unique_sandbox_name("fr-native")
      thread = in_thread do
        FakeRuntime.create(name)
        :returned
      rescue RuntimeError
        :interrupted
      end
      pid = in_flight_relay(name)
      thread.raise(RuntimeError, "simulated interrupt")
      finish(thread, "interrupted native create")
      expect(thread.value).to eq(:interrupted)
      expect_torn_down(pid, within: 5, gc: true, leak: "sandbox #{name} is running and no Ruby object owns it")
      expect(FakeRuntime.watchdog_eof_seen?(pid)).to be(true)
    end
  end

  describe "an interrupt during connect_or_create / start (ownership)" do
    it "connect_or_create leaves a sandbox it merely connected to running" do
      name = unique_sandbox_name("fr-conn")
      owner = FakeRuntime.with_relay_env("FAKE_RELAY_CONN_DELAY" => slow) do
        Microsandbox::Sandbox.create(name, image: rootfs)
      end
      pid = FakeRuntime.relay_pid_for(name)
      mark = FakeRuntime.log_mark
      thread = in_thread do
        Microsandbox::Sandbox.connect_or_create(name, image: rootfs)
        :returned
      rescue RuntimeError
        :interrupted
      end
      wait_for_log(/conn\d+: connected/, since: mark)
      thread.raise(RuntimeError, "simulated interrupt")
      finish(thread, "interrupted connect_or_create")
      expect(thread.value).to eq(:interrupted)
      FakeRuntime.gc!
      sleep 0.3
      expect(FakeRuntime.torn_down?(pid)).to be(false), "the interrupt stopped a sandbox this call did not own"
      expect(FakeRuntime.relay_running?(pid)).to be(true)
      expect(owner.exec("echo", ["still", "up"]).stdout).to eq("still up\n")
    ensure
      owner&.stop
    end

    it "connect_or_create stops a sandbox it created" do
      name = unique_sandbox_name("fr-coc")
      without_gc do
        pid = nil
        thread = FakeRuntime.with_relay_env("FAKE_RELAY_BOOT_DELAY" => slow) do
          t = in_thread do
            Microsandbox::Sandbox.connect_or_create(name, image: rootfs)
            :returned
          rescue RuntimeError
            :interrupted
          end
          pid = in_flight_relay(name)
          t
        end
        thread.raise(RuntimeError, "simulated interrupt")
        finish(thread, "interrupted connect_or_create")
        expect(thread.value).to eq(:interrupted)
        expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
        expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
      end
    end

    it "start stops the sandbox it restarted" do
      name = unique_sandbox_name("fr-start")
      Microsandbox::Sandbox.create(name, image: rootfs).stop
      first = FakeRuntime.relay_pid_for(name)
      expect(FakeRuntime.wait_until(5) { !FakeRuntime.relay_running?(first) }).to be(true)
      without_gc do
        pid = nil
        thread = FakeRuntime.with_relay_env("FAKE_RELAY_BOOT_DELAY" => slow) do
          t = in_thread do
            Microsandbox::Sandbox.start(name)
            :returned
          rescue RuntimeError
            :interrupted
          end
          pid = FakeRuntime.wait_until(10) do
            current = FakeRuntime.relay_pid_for(name)
            current if current != first
          end
          t
        end
        expect(pid).not_to be_nil, "the fake runtime for #{name} never restarted; the call was not in flight"
        thread.raise(RuntimeError, "simulated interrupt")
        finish(thread, "interrupted start")
        expect(thread.value).to eq(:interrupted)
        expect_torn_down(pid, within: 5, leak: "restarted sandbox #{name} is running and no Ruby object owns it")
        expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
      end
    end
  end

  # `Sandbox.acquire` masks interrupts around the native call only; the wrapper
  # — and so a subclass's `initialize` — is built afterwards with normal
  # interrupt handling, and the cleanup works on the bare native handle.
  describe "a Sandbox subclass (construction outside the interrupt mask)" do
    # A Sandbox subclass whose `initialize` calls `super`, then +hook+.
    def subclass_with(&hook)
      Class.new(Microsandbox::Sandbox) do
        define_method(:initialize) do |native|
          super(native)
          hook.call
        end
      end
    end

    it "builds an instance of the subclass, running its initialize (control)" do
      ran = Queue.new
      klass = subclass_with { ran << true }
      sandbox = klass.create(unique_sandbox_name("fr-subctl"), image: rootfs)
      expect(sandbox).to be_an_instance_of(klass)
      expect(ran.size).to eq(1)
      expect(sandbox.owns_lifecycle?).to be(true)
    ensure
      sandbox&.stop
    end

    it "Timeout.timeout fires inside a blocking initialize, promptly, and the sandbox is stopped" do
      name = unique_sandbox_name("fr-subto")
      entered = Queue.new
      gate = Queue.new
      # Bounded even if the mask regressed (the timeout would then wait for
      # this pop): `gate` is closed in the ensure below.
      klass = subclass_with do
        entered << FakeRuntime.now
        gate.pop
      end
      limit = 2.5
      without_gc do
        started = FakeRuntime.now
        thread = in_thread do
          Timeout.timeout(limit) { klass.create(name, image: rootfs) }
          :returned
        rescue Timeout::Error
          :timeout
        end
        finish(thread, "create under Timeout.timeout with a blocking initialize")
        elapsed = FakeRuntime.now - started
        expect(thread.value).to eq(:timeout)
        expect(entered.size).to eq(1), "initialize never ran: the timeout fired before the create returned"
        expect(entered.pop - started).to be < limit
        # The timeout is not held back by the blocked constructor: it lands at
        # its deadline, plus the cleanup stop.
        expect(elapsed).to be < limit + 2
        pid = FakeRuntime.relay_pid_for(name)
        expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
        expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
      end
    ensure
      gate&.close
    end

    it "Thread#kill lands inside a blocking initialize and the sandbox is stopped" do
      name = unique_sandbox_name("fr-subkill")
      entered = Queue.new
      gate = Queue.new
      klass = subclass_with do
        entered << true
        gate.pop
      end
      without_gc do
        thread = in_thread(entered) do
          klass.create(name, image: rootfs)
          :returned
        end
        await(entered, "blocking initialize")
        thread.kill
        finish(thread, "killed initialize")
        expect(thread.status).to be(false)
        pid = FakeRuntime.relay_pid_for(name)
        expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
        expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
      end
    ensure
      gate&.close
    end

    # An interrupt queued during the native call is delivered as the mask ends,
    # i.e. after the native call returned and before `new` ran: `initialize`
    # never runs, and only the bare native handle exists to clean up.
    describe "an interrupt between the native return and the wrapper" do
      it "stops a sandbox the call owns" do
        name = unique_sandbox_name("fr-subwin")
        ran = Queue.new
        klass = subclass_with { ran << true }
        without_gc do
          pid = nil
          thread = FakeRuntime.with_relay_env("FAKE_RELAY_BOOT_DELAY" => slow) do
            t = in_thread do
              klass.create(name, image: rootfs)
              :returned
            rescue RuntimeError
              :interrupted
            end
            pid = in_flight_relay(name)
            t
          end
          thread.raise(RuntimeError, "simulated interrupt")
          finish(thread, "interrupted subclass create")
          expect(thread.value).to eq(:interrupted)
          expect(ran.size).to eq(0), "initialize ran: the interrupt did not land before the wrapper existed"
          expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
          expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
        end
      end

      it "leaves a sandbox it merely connected to running" do
        name = unique_sandbox_name("fr-subconn")
        ran = Queue.new
        klass = subclass_with { ran << true }
        owner = FakeRuntime.with_relay_env("FAKE_RELAY_CONN_DELAY" => slow) do
          Microsandbox::Sandbox.create(name, image: rootfs)
        end
        pid = FakeRuntime.relay_pid_for(name)
        mark = FakeRuntime.log_mark
        thread = in_thread do
          klass.connect_or_create(name, image: rootfs)
          :returned
        rescue RuntimeError
          :interrupted
        end
        wait_for_log(/conn\d+: connected/, since: mark)
        thread.raise(RuntimeError, "simulated interrupt")
        finish(thread, "interrupted subclass connect_or_create")
        expect(thread.value).to eq(:interrupted)
        expect(ran.size).to eq(0), "initialize ran: the interrupt did not land before the wrapper existed"
        FakeRuntime.gc!
        sleep 0.3
        expect(FakeRuntime.torn_down?(pid)).to be(false), "the interrupt stopped a sandbox this call did not own"
        expect(FakeRuntime.relay_running?(pid)).to be(true)
        expect(owner.exec("echo", ["still", "up"]).stdout).to eq("still up\n")
      ensure
        owner&.stop
      end
    end

    # The caller gets no reference when `initialize` raises, exactly as when an
    # interrupt cuts in, so the same ownership-scoped cleanup applies.
    describe "an initialize that raises" do
      let(:failing) { subclass_with { raise ArgumentError, "bad subclass" } }

      it "stops a sandbox the call owns and propagates the error" do
        name = unique_sandbox_name("fr-subraise")
        without_gc do
          expect { failing.create(name, image: rootfs) }.to raise_error(ArgumentError, "bad subclass")
          pid = FakeRuntime.relay_pid_for(name)
          expect(pid).not_to be_nil
          expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
          expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
        end
      end

      it "leaves a sandbox it merely connected to running" do
        name = unique_sandbox_name("fr-subraisec")
        owner = Microsandbox::Sandbox.create(name, image: rootfs)
        pid = FakeRuntime.relay_pid_for(name)
        expect { failing.connect_or_create(name, image: rootfs) }.to raise_error(ArgumentError, "bad subclass")
        FakeRuntime.gc!
        sleep 0.3
        expect(FakeRuntime.torn_down?(pid)).to be(false), "the failed constructor stopped a sandbox this call did not own"
        expect(owner.exec("echo", ["still", "up"]).stdout).to eq("still up\n")
      ensure
        owner&.stop
      end
    end
  end

  describe "an interrupt during exec_stream" do
    it "closes every interrupted guest session once the handle is collected" do
      sandbox = FakeRuntime.with_relay_env("FAKE_RELAY_CONN_DELAY" => slow) do
        FakeRuntime.create(unique_sandbox_name("fr-exec"))
      end
      start = FakeRuntime.log_mark
      outcomes = Array.new(5) do
        mark = FakeRuntime.log_mark
        thread = in_thread do
          sandbox.exec_stream("hang", [], {}).class.name
        rescue RuntimeError
          :interrupted
        end
        wait_for_log(/conn\d+: connected/, since: mark)
        thread.raise(RuntimeError, "simulated interrupt")
        finish(thread, "interrupted exec_stream").value
      end
      expect(outcomes).to eq([:interrupted] * 5)

      leaked = nil
      FakeRuntime.wait_until(5) do
        FakeRuntime.gc!(1)
        opened = FakeRuntime.exec_sessions_opened(since: start)
        leaked = opened - FakeRuntime.exec_sessions_closed(since: start)
        opened == 5 && leaked.zero?
      end
      expect(FakeRuntime.exec_sessions_opened(since: start)).to eq(5)
      expect(leaked).to eq(0), "LEAKED: #{leaked} guest exec session(s) still open and unreachable after GC"
    ensure
      sandbox&.stop
    end
  end

  describe "an interrupt during FsWriteSink#close" do
    let(:sandbox) do
      FakeRuntime.with_relay_env("FAKE_RELAY_FS_ACK_DELAY" => slow) do
        Microsandbox::Sandbox.create(unique_sandbox_name("fr-fs"), image: rootfs)
      end
    end

    after { sandbox.stop }

    it "in flight: the close runs to completion before the exception is raised" do
      mark = FakeRuntime.log_mark
      sink = sandbox.fs.write_stream("/tmp/interrupted.bin")
      sink.write("payload")
      thread = in_thread do
        sink.close
        :closed
      rescue RuntimeError
        :interrupted
      end
      # The relay logs EOF and only then (after the delay) acknowledges it.
      wait_for_log(/fs\.write id=\d+ EOF after 7B/, since: mark)
      thread.raise(RuntimeError, "simulated interrupt")
      finish(thread, "interrupted close")
      expect(thread.value).to eq(:interrupted)
      done = FakeRuntime.wait_until(5) do
        log = FakeRuntime.log_text(since: mark)
        log[/fs\.close_handle/] && log[/client disconnected \(.*open fs write streams: \[\]\)/]
      end
      expect(done).not_to be_nil, "LEAKED: the write sink's file handle or connection is still open"
      expect(sink.close).to be_nil # idempotent: already closed
    end

    # `:on_blocking` defers an exception until the thread blocks. The native
    # call is that blocking point, and the exception must be raised BEFORE the
    # call has taken anything — otherwise the sink it took is closed by nobody.
    it "deferred with :on_blocking: raises before the close starts, leaving the sink usable" do
      mark = FakeRuntime.log_mark
      sink = sandbox.fs.write_stream("/tmp/deferred.bin")
      sink.write("payload")
      ready = Queue.new
      go = Queue.new
      thread = in_thread(ready) do
        Thread.handle_interrupt(RuntimeError => :on_blocking) do
          ready << true
          # No blocking operation while waiting: the exception stays deferred.
          deadline = FakeRuntime.now + 10
          Thread.pass until go.closed? || FakeRuntime.now > deadline
          raise Timeout::Error, "the observer never released the worker" unless go.closed?
          sink.close
          :closed
        end
      rescue RuntimeError
        :interrupted
      end
      await(ready, "deferred close")
      thread.raise(RuntimeError, "simulated interrupt")
      go.close
      finish(thread, "deferred close")
      expect(thread.value).to eq(:interrupted)
      expect(FakeRuntime.log_text(since: mark)).not_to match(/EOF/)

      expect(sink.close).to be_nil
      expect(FakeRuntime.wait_until(5) { FakeRuntime.log_text(since: mark)[/fs\.write id=\d+ EOF after 7B/] })
        .not_to be_nil, "LEAKED: the interrupted close consumed the sink without closing it"
    end
  end

  describe "an interrupt during PullSession#sandbox" do
    around do |example|
      FakeRuntime.with_relay_env("FAKE_RELAY_BOOT_DELAY" => slow) { example.run }
    end

    it "stops the sandbox the session produced, without waiting for GC" do
      name = unique_sandbox_name("fr-pull")
      without_gc do
        session = Microsandbox::Sandbox.create_with_progress(name, image: rootfs)
        entered = Queue.new
        thread = in_thread(entered) do
          entered << true
          session.sandbox
          :returned
        rescue RuntimeError
          :interrupted
        end
        await(entered, "PullSession#sandbox")
        pid = in_flight_relay(name)
        sleep 0.05 # the thread is now inside the native join of the create task
        thread.raise(RuntimeError, "simulated interrupt")
        finish(thread, "interrupted PullSession#sandbox")
        expect(thread.value).to eq(:interrupted)
        expect_torn_down(pid, within: 5, leak: "sandbox #{name} is running and no Ruby object owns it")
        expect(FakeRuntime.shutdown_seen?(pid)).to be(true), "expected an explicit stop, not a GC drop"
      end
    end

    it "native result: hands the sandbox to Ruby, so GC drops it" do
      name = unique_sandbox_name("fr-pulln")
      entered = Queue.new
      thread = in_thread(entered) do
        session = Microsandbox::Native::Sandbox.create_with_progress(name, FakeRuntime.native_opts)
        entered << true
        session.result
        :returned
      rescue RuntimeError
        :interrupted
      end
      await(entered, "PullSession#result")
      pid = in_flight_relay(name)
      sleep 0.05
      thread.raise(RuntimeError, "simulated interrupt")
      finish(thread, "interrupted PullSession#result")
      expect(thread.value).to eq(:interrupted)
      expect_torn_down(pid, within: 5, gc: true, leak: "sandbox #{name} is running and no Ruby object owns it")
    end
  end
end
