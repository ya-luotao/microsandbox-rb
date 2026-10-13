# frozen_string_literal: true

# Standalone fork probe, run by spec/unit/fork_safety_spec.rb in a process of
# its own (`ruby -I lib spec/support/fork_probe.rb <scenario>`): the rspec
# process has long since used the SDK, so it cannot be the "parent that forks".
#
# It talks to the spec through stdout, one JSON object per line:
#
#   {"step": "child.list1", "ok": true, "elapsed": 0.004, "value": 0}
#   {"step": "child.status", "ok": true, "exit": 0, "signal": null}
#
# and exits 0 only when the forked child did. The child always leaves through a
# plain `exit`, never `exit!`: Ruby then frees every wrapped native object,
# which is where a handle inherited from the parent would be destroyed.
#
# Only catalog reads and writes are used (volumes), so no `msb` runtime is
# needed and nothing is ever provisioned.

require "json"
require "microsandbox"

$stdout.sync = true

module ForkProbe
  module_function

  def clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Run the block and time it: what it returned, or what it raised.
  def measure
    started = clock
    outcome = begin
      {ok: true, value: yield}
    rescue => e
      {ok: false, error: e.class.name, message: e.message}
    end
    outcome.merge(elapsed: (clock - started).round(3))
  end

  def emit(name, outcome)
    puts JSON.generate({step: name, pid: Process.pid}.merge(outcome))
    outcome[:ok]
  end

  # Run the block, time it, and report what happened under +name+.
  def step(name, &block)
    emit(name, measure(&block))
  end

  def volumes
    Microsandbox::Volume.list.size
  end

  # Wait for +pid+, report how it ended, and leave with its verdict (after the
  # optional block, which runs in the parent once the child is gone).
  def reap(pid, name = "child.status")
    _, status = Process.wait2(pid)
    puts JSON.generate(step: name, ok: status.success?, exit: status.exitstatus, signal: status.termsig)
    yield if block_given?
    exit(status.success? ? 0 : 1)
  end

  # What every child does: two catalog reads, then a normal exit.
  def child_reads(prefix = "child")
    ok = step("#{prefix}.list1") { volumes }
    ok &= step("#{prefix}.list2") { volumes }
    exit(ok ? 0 : 1)
  end

  SCENARIOS = {
    # (f) control: the parent has not touched the SDK when it forks.
    "fresh" => lambda do
      reap(fork { child_reads })
    end,

    # (a) + (e): the parent warms the backend, forks, and keeps working after
    # the child is gone.
    "warm" => lambda do
      step("parent.warm") { volumes }
      reap(fork { child_reads }) { step("parent.after") { volumes } }
    end,

    # (b): a catalog write and a live handle in the parent. The child must be
    # refused the inherited handle, get its own instantly, and survive
    # destroying the inherited one (GC here, everything else at exit).
    "handle" => lambda do
      name = "fork-probe-#{Process.pid}"
      step("parent.create") { Microsandbox::Volume.create(name).name }
      fs = Microsandbox::Volume.fs(name)
      step("parent.write") { fs.write("hello.txt", "from the parent") }
      pid = fork do
        ok = step("child.inherited") { fs.list("").size }
        ok = !ok # it must have raised
        ok &= step("child.own_fs") { Microsandbox::Volume.fs(name).read_text("hello.txt") }
        ok &= step("child.list") { volumes }
        fs = nil
        ok &= step("child.gc") do
          GC.start
          true
        end
        exit(ok ? 0 : 1)
      end
      reap(pid) { step("parent.after") { fs.read_text("hello.txt") } }
    end,

    # The inherited handle is the ONLY owner of a backend with a warm pool (the
    # parent has since selected another default). Destroying that handle in
    # the child would destroy the backend with it, which is what must not
    # happen: the child drops its reference, collects garbage and exits.
    "sole_owner" => lambda do
      name = "fork-probe-#{Process.pid}"
      step("parent.create") { Microsandbox::Volume.create(name).name } # warms the first backend
      fs = Microsandbox::Volume.fs(name) # holds the first backend
      Microsandbox.set_default_backend(:local) # the default no longer does
      step("parent.warm") { volumes }
      pid = fork do
        ok = step("child.list1") { volumes }
        fs = nil
        ok &= step("child.gc") do
          3.times { GC.start(full_mark: true, immediate_sweep: true) }
          true
        end
        exit(ok ? 0 : 1)
      end
      reap(pid) { step("parent.after") { fs.exists?("nothing-here") } }
    end,

    # (c): the fork happens inside a with_backend block, so the child's first
    # native call is the pop that closes a scope the parent opened.
    "with_backend" => lambda do
      step("parent.warm") { volumes } # the backend the scope saves for its restore
      pid = :unset
      closed = measure do
        Microsandbox.with_backend(:local) do
          step("parent.scoped") { volumes } # the scoped backend, warm too
          pid = fork
        end
        true
      end
      # Both processes get here, each having closed the scope on its own.
      if pid.nil?
        ok = emit("child.close", closed)
        ok &= step("child.kind") { Microsandbox.default_backend_kind.to_s }
        ok &= step("child.list1") { volumes }
        ok &= step("child.list2") { volumes }
        exit(ok ? 0 : 1)
      end
      emit("parent.close", closed)
      reap(pid) { step("parent.after") { volumes } }
    end,

    # (d): a child that used the SDK forks again.
    "grandchild" => lambda do
      step("parent.warm") { volumes }
      pid = fork do
        ok = step("child.list1") { volumes }
        grandchild = fork { child_reads("grandchild") }
        _, status = Process.wait2(grandchild)
        puts JSON.generate(step: "grandchild.status", ok: status.success?, exit: status.exitstatus, signal: status.termsig)
        exit((ok && status.success?) ? 0 : 1)
      end
      reap(pid)
    end,

    # The child's first native call selects a backend. Replacing the default
    # is what used to destroy the inherited one.
    "select_first" => lambda do
      Microsandbox.set_default_backend(:local)
      step("parent.warm") { volumes }
      pid = fork do
        ok = step("child.select") do
          Microsandbox.set_default_backend(:local)
          true
        end
        ok &= step("child.list1") { volumes }
        exit(ok ? 0 : 1)
      end
      reap(pid) { step("parent.after") { volumes } }
    end,

    # The way the parent's backend was chosen (the environment ladder) no
    # longer resolves in the child. Plain calls fail there until that is
    # repaired, but selecting a backend explicitly must not depend on it.
    "select_recovers" => lambda do
      step("parent.warm") { volumes }
      pid = fork do
        ENV["MSB_BACKEND"] = "cloud" # and no API key
        ok = !step("child.broken") { volumes } # it must have raised
        ok &= step("child.select") do
          Microsandbox.set_default_backend(:local)
          true
        end
        ok &= step("child.list1") { volumes }
        ok &= step("child.kind") { Microsandbox.default_backend_kind.to_s }
        exit(ok ? 0 : 1)
      end
      reap(pid) { step("parent.after") { volumes } }
    end,

    # The child leaves a with_backend block its parent opened by raising, and
    # the backend the scope should restore (chosen by the ladder) cannot be
    # chosen again in the child. The block's exception must win, and the
    # temporary backend stays selected.
    "scope_restore_fails" => lambda do
      step("parent.warm") { volumes }
      pid = :unset
      left = measure do
        Microsandbox.with_backend(:local) do
          step("parent.scoped") { volumes }
          pid = fork
          if pid.nil?
            ENV["MSB_BACKEND"] = "cloud" # and no API key
            raise "sentinel"
          end
          true
        end
      end
      if pid.nil?
        emit("child.block", left)
        ok = left[:error] == "RuntimeError" && left[:message] == "sentinel"
        ok &= step("child.kind") { Microsandbox.default_backend_kind.to_s }
        ok &= step("child.list1") { volumes }
        exit(ok ? 0 : 1)
      end
      emit("parent.close", left)
      reap(pid) { step("parent.after") { volumes } }
    end,

    # The reverse: the TEMPORARY backend of a scope the parent opened (a cloud
    # profile from the config file) cannot be chosen again in the child, while
    # the backend the scope restores (ladder, local) can. Leaving the block
    # must restore it all the same — the child never needs the temporary one.
    "scope_selection_gone" => lambda do
      config = File.join(ENV.fetch("MSB_HOME"), "config.json")
      File.write(config, JSON.generate("profiles" => {"probe" => {
        "backend" => "cloud", "url" => "https://cloud.invalid", "api_key_ref" => "inline:msb_live_probe"
      }}))
      step("parent.warm") { volumes }
      pid = :unset
      left = measure do
        Microsandbox.with_backend(:cloud, profile: "probe") do
          step("parent.scoped") { Microsandbox.default_backend_kind.to_s }
          pid = fork
          # The child loses the profile: its config file is somewhere else now.
          ENV["MSB_CONFIG_PATH"] = File.join(ENV.fetch("MSB_HOME"), "no-such-config.json") if pid.nil?
          true
        end
      end
      if pid.nil?
        ok = emit("child.close", left)
        ok &= step("child.kind") { Microsandbox.default_backend_kind.to_s }
        ok &= step("child.list1") { volumes }
        exit(ok ? 0 : 1)
      end
      emit("parent.close", left)
      reap(pid) { step("parent.after") { volumes } }
    end
  }.freeze
end

scenario = ForkProbe::SCENARIOS.fetch(ARGV.fetch(0)) do |name|
  abort "unknown scenario #{name.inspect} (#{ForkProbe::SCENARIOS.keys.join(", ")})"
end
scenario.call
