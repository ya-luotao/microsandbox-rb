# frozen_string_literal: true

# Real-microVM fork probe for spec/integration/fork_safety_spec.rb, run in a
# process of its own (the rspec process must not fork: its children would run
# RSpec's exit hooks). Usage: ruby -Ilib fork_sandbox_probe.rb <name> <image>
#
# The parent boots a sandbox and forks. The child tries the inherited handle,
# lists sandboxes, boots and stops one of its own, and leaves through a normal
# `exit` (which frees the inherited native Sandbox). The parent then checks its
# sandbox still answers. Prints one JSON line.
require "json"
require "microsandbox"

name, image = ARGV

def attempt
  yield
rescue Microsandbox::Error => e
  {"error" => e.class.name, "message" => e.message}
end

def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

sandbox = Microsandbox::Sandbox.create(name, image: image)
before = attempt { sandbox.exec("echo", ["before"]).stdout }
reader, writer = IO.pipe

child = fork do
  reader.close
  report = {"pid" => Process.pid}
  report["name"] = attempt { sandbox.name }
  report["exec"] = attempt { sandbox.exec("echo", ["inherited"]).stdout }
  started = clock
  report["listed"] = attempt { Microsandbox::Sandbox.list.sandboxes.map(&:name) }
  report["list_seconds"] = (clock - started).round(3)
  report["own"] = attempt do
    Microsandbox::Sandbox.create("#{name}-child", image: image) do |own|
      own.exec("echo", ["from", "the", "child"]).stdout
    end
  end
  report["own_removed"] = attempt do
    Microsandbox::Sandbox.remove("#{name}-child")
    true
  end
  writer.puts JSON.generate(report)
  writer.close
  exit # not exit!: the inherited native Sandbox is freed on the way out
end

writer.close
child_report = reader.read
_, status = Process.wait2(child)
after = attempt { sandbox.exec("echo", ["after"]).stdout }
stopped = attempt do
  sandbox.stop
  Microsandbox::Sandbox.remove(name)
  "stopped"
end

puts JSON.generate(
  parent_pid: Process.pid, parent_exec_before: before,
  child: (JSON.parse(child_report) unless child_report.empty?),
  child_exit: status.exitstatus, child_signal: status.termsig,
  parent_exec_after: after, parent_stop: stopped
)
