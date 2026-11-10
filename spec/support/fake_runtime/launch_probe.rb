# frozen_string_literal: true

# Child process for launch_contract_spec: the local backend captures the msb
# path once per process, so each capability set the fake runtime advertises
# needs a process of its own.
# Usage: ruby -Ilib launch_probe.rb <home> <capability-variant> <sandbox-name> <create-opts-json>
#
# Sets up the fake runtime under <home> advertising <capability-variant>, tries
# `Sandbox.create(<sandbox-name>, **opts)`, and prints one JSON line with what
# happened (and the argv the fake runtime was launched with).
require "json"
require "microsandbox"
require_relative "fake_runtime"

home, variant, name, opts_json = ARGV
FakeRuntime.setup!(home, capabilities: variant)
# The runtime is the fake one; never try to provision a real one.
Microsandbox.define_singleton_method(:ensure_runtime!) { nil }

opts = JSON.parse(opts_json || "{}").transform_keys(&:to_sym)
report = {}
begin
  sandbox = Microsandbox::Sandbox.create(name, image: FakeRuntime.rootfs, **opts)
  report[:outcome] = "created"
  report[:echo] = sandbox.exec("echo", ["ok"]).stdout
  sandbox.stop
rescue Microsandbox::Error => e
  report[:outcome] = "error"
  report[:error_class] = e.class.name
  report[:message] = e.message
end
started = FakeRuntime.log_lines.find { |l| l.include?("started;") }
report[:relay_args] = started && JSON.parse(started[/args=(\[.*?\]) agent_sock=/, 1])
report[:lifecycle_lock_fd] = started && started[/lifecycle_lock_fd=(\w+)/, 1]
FakeRuntime.kill_relays!
puts JSON.generate(report)
