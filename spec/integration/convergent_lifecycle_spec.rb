# frozen_string_literal: true

# Real microVM coverage for the convergent lifecycle APIs (runtime v0.6.16,
# upstream #1462): `Sandbox.connect_or_create`, `#id`, `#wait_for_status`,
# `#restart`, `#destroy`, and `SandboxHandle#connect_or_start`.
# Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "convergent lifecycle", :integration do
  let(:image) { default_test_image }

  # Best-effort teardown: these examples deliberately destroy sandboxes mid-way,
  # so the cleanup must tolerate an already-gone name.
  def destroy_quietly(sandbox)
    sandbox&.destroy(force: true)
  rescue Microsandbox::Error
    nil
  end

  it "creates on the first call and converges on the same sandbox after that" do
    name = unique_sandbox_name
    first = Microsandbox::Sandbox.connect_or_create(name, image: image)
    begin
      expect(first.name).to eq(name)
      expect(first.id).to be_a(String)
      expect(first.id).not_to be_empty

      # Second call must NOT create a second sandbox — same persisted identity,
      # and the create-time kwargs are ignored for the existing one.
      second = Microsandbox::Sandbox.connect_or_create(name, image: image, memory: 1024)
      expect(second.name).to eq(name)
      expect(second.id).to eq(first.id)
      expect(second.exec("echo", ["converged"]).stdout).to include("converged")
    ensure
      destroy_quietly(first)
    end
  end

  # The block form stops only what the call owns, so connecting to a sandbox
  # someone else is running must not take it down on the way out of the block.
  it "leaves a merely-connected sandbox running after the block form" do
    name = unique_sandbox_name
    owner = Microsandbox::Sandbox.create(name, image: image)
    begin
      expect(owner.owns_lifecycle?).to be(true)

      connected_owns = nil
      Microsandbox::Sandbox.connect_or_create(name, image: image) do |sb|
        connected_owns = sb.owns_lifecycle?
        expect(sb.exec("echo", ["borrowed"]).stdout).to include("borrowed")
      end
      expect(connected_owns).to be(false)

      # The block returned without stopping it: still running, still usable.
      expect(Microsandbox::Sandbox.get(name).status).to eq(:running)
      expect(owner.exec("echo", ["still-here"]).stdout).to include("still-here")
    ensure
      destroy_quietly(owner)
    end
  end

  it "stops a sandbox it created itself when the block form returns" do
    name = unique_sandbox_name
    Microsandbox::Sandbox.connect_or_create(name, image: image) do |sb|
      expect(sb.owns_lifecycle?).to be(true)
    end
    expect(Microsandbox::Sandbox.get(name).status).not_to eq(:running)
  ensure
    begin
      Microsandbox::Sandbox.remove(name)
    rescue Microsandbox::Error
      nil
    end
  end

  # Identity scoping on the *live* Sandbox, not just on handles: the binding
  # routes #stop through the sandbox object (v0.6.16 scopes it to the object's
  # id), so a name that has been removed and recreated is refused rather than
  # terminated. Deterministic — the replacement is made sequentially, no race.
  it "refuses to stop a sandbox whose name was removed and recreated" do
    name = unique_sandbox_name
    original = Microsandbox::Sandbox.create(name, image: image)
    original.stop
    Microsandbox::Sandbox.remove(name)

    replacement = Microsandbox::Sandbox.create(name, image: image)
    begin
      expect(replacement.id).not_to eq(original.id)
      expect { original.stop }.to raise_error(Microsandbox::SandboxReplacedError)
      # The refusal is the point: the replacement is untouched.
      expect(Microsandbox::Sandbox.get(name).status).to eq(:running)
      expect(replacement.exec("echo", ["untouched"]).stdout).to include("untouched")
    ensure
      destroy_quietly(replacement)
    end
  end

  # The same guarantee reached through connect_or_create's block teardown, which
  # is where it actually bites: the ensure calls #stop on a sandbox this call
  # created, but the name was reused while the block ran.
  it "does not let the block-form teardown stop a replacement created mid-block" do
    name = unique_sandbox_name
    replacement = nil
    begin
      Microsandbox::Sandbox.connect_or_create(name, image: image) do |sb|
        expect(sb.owns_lifecycle?).to be(true)
        sb.stop
        Microsandbox::Sandbox.remove(name)
        replacement = Microsandbox::Sandbox.create(name, image: image)
      end
      # The ensure ran, tried to stop `sb`, and was refused (the error is
      # swallowed as a best-effort teardown failure) — so this survives.
      expect(Microsandbox::Sandbox.get(name).id).to eq(replacement.id)
      expect(Microsandbox::Sandbox.get(name).status).to eq(:running)
      expect(replacement.exec("echo", ["survived"]).stdout).to include("survived")
    ensure
      destroy_quietly(replacement)
    end
  end

  it "starts a stopped sandbox instead of failing on the name" do
    name = unique_sandbox_name
    created = Microsandbox::Sandbox.create(name, image: image)
    id = created.id
    created.stop

    reconnected = nil
    begin
      reconnected = Microsandbox::Sandbox.connect_or_create(name, image: image)
      expect(reconnected.id).to eq(id)
      expect(reconnected.status).to eq(:running)
      expect(reconnected.exec("echo", ["restarted"]).stdout).to include("restarted")
    ensure
      destroy_quietly(reconnected)
    end
  end

  # Converging on a sandbox and replacing it are opposites, so the core rejects
  # the combination outright — the kwargs are accepted for `.create` parity.
  it "rejects replace:/replace_with_timeout: on connect_or_create" do
    expect do
      Microsandbox::Sandbox.connect_or_create(unique_sandbox_name, image: image, replace: true)
    end.to raise_error(Microsandbox::InvalidConfigError, /connect_or_create/)

    expect do
      Microsandbox::Sandbox.connect_or_create(
        unique_sandbox_name, image: image, replace_with_timeout: 1
      )
    end.to raise_error(Microsandbox::InvalidConfigError, /connect_or_create/)
  end

  it "observes a status with wait_for_status, on both the sandbox and a handle" do
    name = unique_sandbox_name
    sandbox = Microsandbox::Sandbox.create(name, image: image)
    begin
      # Already running, so this returns immediately (wait_for_status has no
      # built-in timeout — only ever wait for a reachable state).
      handle = sandbox.wait_for_status(:running)
      expect(handle).to be_a(Microsandbox::SandboxHandle)
      expect(handle.status).to eq(:running)
      expect(handle.id).to eq(sandbox.id)

      sandbox.stop
      stopped = handle.wait_for_status("stopped")
      expect(stopped.status).to eq(:stopped)
    ensure
      destroy_quietly(sandbox)
    end
  end

  it "restarts in place, keeping the sandbox identity" do
    name = unique_sandbox_name
    sandbox = Microsandbox::Sandbox.create(name, image: image)
    begin
      id = sandbox.id
      sandbox = sandbox.restart
      expect(sandbox).to be_a(Microsandbox::Sandbox)
      expect(sandbox.name).to eq(name)
      expect(sandbox.id).to eq(id)
      expect(sandbox.status).to eq(:running)
      expect(sandbox.exec("echo", ["after-restart"]).stdout).to include("after-restart")
    ensure
      destroy_quietly(sandbox)
    end
  end

  it "destroys a running sandbox, leaving nothing to look up" do
    name = unique_sandbox_name
    sandbox = Microsandbox::Sandbox.create(name, image: image)
    expect(sandbox.destroy).to be_nil
    expect { Microsandbox::Sandbox.get(name) }
      .to raise_error(Microsandbox::SandboxNotFoundError)
    expect(Microsandbox::Sandbox.list.map(&:name)).not_to include(name)
  end

  it "connects to a running sandbox and starts a stopped one via connect_or_start" do
    name = unique_sandbox_name
    sandbox = Microsandbox::Sandbox.create(name, image: image)
    begin
      connected = Microsandbox::Sandbox.get(name).connect_or_start
      expect(connected).to be_a(Microsandbox::Sandbox)
      expect(connected.id).to eq(sandbox.id)
      expect(connected.exec("echo", ["connected"]).stdout).to include("connected")

      sandbox.stop
      started = Microsandbox::Sandbox.get(name).connect_or_start
      expect(started.status).to eq(:running)
      expect(started.exec("echo", ["started"]).stdout).to include("started")
      sandbox = started
    ensure
      destroy_quietly(sandbox)
    end
  end
end
