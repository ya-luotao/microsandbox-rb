# frozen_string_literal: true

# Child process for spec/fake_runtime/fork_safety_spec.rb: the spec process has
# used the SDK and must not fork. Usage: ruby -Ilib fork_sandbox.rb <home> <name>
#
# Boots a (fake) sandbox, forks, lets the forked child try the inherited handle,
# open its own and leave through a normal `exit` (which frees the inherited
# native Sandbox), then checks that the parent's sandbox was not touched.
# Prints one JSON line.
require "json"
require "microsandbox"
require_relative "fake_runtime"

home, name = ARGV
FakeRuntime.setup!(home)
# The runtime is the fake one; never try to provision a real one.
Microsandbox.define_singleton_method(:ensure_runtime!) { nil }

def attempt
  yield
rescue Microsandbox::Error => e
  {"error" => e.class.name, "message" => e.message}
end

sandbox = Microsandbox::Sandbox.create(name, image: FakeRuntime.rootfs)
relay = FakeRuntime.relay_pid_for(name)
reader, writer = IO.pipe

child = fork do
  reader.close
  report = {"pid" => Process.pid}
  report["name"] = attempt { sandbox.name }
  report["exec"] = attempt { sandbox.exec("echo", ["inherited"]).stdout }
  report["stop"] = attempt do
    sandbox.stop
    "stopped"
  end
  started = FakeRuntime.now
  report["listed"] = attempt { Microsandbox::Sandbox.list.sandboxes.map(&:name) }
  report["list_seconds"] = (FakeRuntime.now - started).round(3)
  report["own_exec"] = attempt do
    own = Microsandbox::Sandbox.get(name).connect_or_start
    own.exec("echo", ["from", "the", "child"]).stdout
  end
  writer.puts JSON.generate(report)
  writer.close
  exit # not exit!: the inherited native Sandbox is freed on the way out
end

writer.close
child_report = reader.read
_, status = Process.wait2(child)
# Give a teardown the child might have triggered time to reach the relay's log.
sleep 0.3
untouched = FakeRuntime.relay_running?(relay) && !FakeRuntime.torn_down?(relay)
after = attempt { sandbox.exec("echo", ["after"]).stdout }
stopped = attempt do
  sandbox.stop
  "stopped"
end
gone = !FakeRuntime.wait_until(5) { !FakeRuntime.relay_running?(relay) }.nil?
FakeRuntime.kill_relays!

puts JSON.generate(
  parent_pid: Process.pid, child: (JSON.parse(child_report) unless child_report.empty?),
  child_exit: status.exitstatus, child_signal: status.termsig,
  untouched_after_child: untouched, parent_exec_after: after, parent_stop: stopped,
  relay_gone_after_stop: gone, shutdown_seen: FakeRuntime.shutdown_seen?(relay)
)
