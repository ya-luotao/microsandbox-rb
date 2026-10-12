# frozen_string_literal: true

require_relative "fake_runtime_helper"

# Proves the rig itself before anything depends on it: the real native
# extension boots a "sandbox" against the fake msb, talks the agent protocol to
# the fake relay, and tears it down.
RSpec.describe "fake runtime (smoke)", :fake_runtime do
  it "boots a sandbox over the fake relay, runs a scripted command and stops it" do
    name = unique_sandbox_name("fr-smoke")
    sandbox = Microsandbox::Sandbox.create(name, image: FakeRuntime.rootfs)
    pid = FakeRuntime.relay_pid_for(name)
    expect(pid).to be_a(Integer), "the fake relay never logged a start for #{name}"
    expect(FakeRuntime.relay_running?(pid)).to be(true)

    output = sandbox.exec("echo", ["hello", "fake"])
    expect(output.stdout).to eq("hello fake\n")
    expect(output.exit_code).to eq(0)

    sandbox.stop
    expect(FakeRuntime.wait_until(5) { !FakeRuntime.relay_running?(pid) }).to be(true),
      "relay #{pid} is still running after Sandbox#stop"
    expect(FakeRuntime.shutdown_seen?(pid)).to be(true)
  end
end
