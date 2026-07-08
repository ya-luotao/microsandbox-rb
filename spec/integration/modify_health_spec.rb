# frozen_string_literal: true

# Real-microVM integration coverage for the v0.6.6 parity surface: ping/touch
# health checks and live modify (plan + apply). Opt-in via
# MICROSANDBOX_INTEGRATION=1. This is the ONLY place the new native bindings
# run against a real guest — the unit suite stubs the native layer entirely.
RSpec.describe "Sandbox live modification & health", :integration do
  let(:image) { default_test_image }

  it "pings and touches a running sandbox" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      ping = sb.ping
      expect(ping).to be_a(Microsandbox::PingResult)
      expect(ping.name).to eq(sb.name)
      expect(ping.latency).to be_a(Float)
      expect(ping.latency).to be >= 0
      expect(ping.latency_ms).to be_within(0.001).of(ping.latency * 1000.0)

      touch = sb.touch
      expect(touch).to be_a(Microsandbox::TouchResult)
      expect(touch.name).to eq(sb.name)
      expect(touch.activity_seq).to be_a(Integer)
      # A second touch advances the activity sequence.
      expect(sb.touch.activity_seq).to be > touch.activity_seq
    end
  end

  it "raises SandboxNotRunningError from a stopped handle's ping/touch" do
    name = unique_sandbox_name
    Microsandbox::Sandbox.create(name, image: image) { |_sb| }
    handle = Microsandbox::Sandbox.get(name)
    expect(handle.stopped?).to be(true)
    expect { handle.ping }.to raise_error(Microsandbox::SandboxNotRunningError)
    expect { handle.touch }.to raise_error(Microsandbox::SandboxNotRunningError)
  ensure
    begin
      Microsandbox::Sandbox.remove(name)
    rescue Microsandbox::Error
      nil
    end
  end

  it "dry-runs a plan, live-resizes resources, and gates restart-required changes" do
    name = unique_sandbox_name
    Microsandbox::Sandbox.create(name, image: image,
      cpus: 1, max_cpus: 2, memory: 512, max_memory: 1024) do |sb|
      # Dry run: classified but not applied.
      plan = sb.modify(cpus: 2, memory: 1024, dry_run: true)
      expect(plan).to be_a(Microsandbox::ModificationPlan)
      expect(plan.applied?).to be(false)
      expect(plan.policy).to eq(:no_restart)
      fields = plan.changes.map { |c| c[:field] }
      expect(fields).to include("cpus", "memory")
      expect(plan.changes).to all(satisfy { |c| c[:disposition].is_a?(String) })

      # Live resize within the boot-time ceilings applies without a restart.
      applied = sb.modify(cpus: 2, memory: 1024)
      expect(applied.applied?).to be(true)
      expect(applied.conflicts).to be_empty

      # env on a RUNNING sandbox requires a restart → the default :no_restart
      # policy refuses the whole apply (this is the documented all-or-nothing
      # contract; nothing is partially applied).
      expect { sb.modify(env: {"TIER" => "prod"}) }.to raise_error(Microsandbox::Error)

      # ...but the same change is accepted for the next start when asked for.
      deferred = sb.modify(env: {"TIER" => "prod"}, policy: :next_start)
      expect(deferred.applied?).to be(true)
      env_change = deferred.changes.find { |c| c[:field] == "env" }
      expect(env_change).not_to be_nil
    end
  end
end
