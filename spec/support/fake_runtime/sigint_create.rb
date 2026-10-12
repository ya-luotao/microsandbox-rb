# frozen_string_literal: true

# Child process for interrupt_safety_spec's SIGINT case: Ctrl-C can only be
# delivered to a process's MAIN thread, and the spec process must not receive
# one. Usage: ruby -Ilib sigint_create.rb <home> <sandbox-name>
#
# Sets up its own fake runtime under <home>, sends itself SIGINT while
# `Sandbox.create` is in flight, and prints one JSON line with what happened.
require "json"
require "microsandbox"
require_relative "fake_runtime"

home, name = ARGV
FakeRuntime.setup!(home)
# The runtime is the fake one; never try to provision a real one.
Microsandbox.define_singleton_method(:ensure_runtime!) { nil }

# In a method, so nothing in this frame keeps the sandbox alive afterwards.
def interrupted_create(name)
  Microsandbox::Sandbox.create(name, image: FakeRuntime.rootfs)
  "returned"
rescue Interrupt
  "interrupt"
end

relay_started = false
Thread.new do
  # The relay logs its start while the native create is blocked on the boot
  # handshake (FAKE_RELAY_BOOT_DELAY), so the signal lands mid-call.
  relay_started = !FakeRuntime.wait_for_relay(name).nil?
  Process.kill("INT", Process.pid)
end

outcome = interrupted_create(name)
pid = FakeRuntime.relay_pid_for(name)
torn_down = pid && FakeRuntime.wait_until(5) do
  FakeRuntime.gc!(1)
  FakeRuntime.torn_down?(pid)
end
FakeRuntime.gc!
live = ObjectSpace.each_object(Microsandbox::Sandbox).count
FakeRuntime.kill_relays!
puts JSON.generate(outcome: outcome, relay_started: relay_started, relay_pid: pid,
  torn_down: torn_down ? true : false, live_sandboxes: live)
