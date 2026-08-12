# frozen_string_literal: true

require "tmpdir"

# The binaries-gem resolver tier + per-tier runtime version check (prototype of
# the two-gem split from upstream #1305). Everything Native-facing is stubbed:
# the real set_runtime_msb_path consumes a process-wide set-once OnceLock that
# cannot be restored (see runtime_spec.rb), and the real resolver would leak
# the dev box's ~/.microsandbox state into the examples. Real-OnceLock
# behavior is covered by the subprocess specs in
# binaries_gem_subprocess_spec.rb.
RSpec.describe "binaries companion gem integration" do
  around do |example|
    reset = lambda do
      %i[@runtime_ready @binaries_gem_claimed @binaries_gem_tier_active
        @msb_slot_owner @firmware_slot_owner @verified_msb_paths].each do |ivar|
        Microsandbox.instance_variable_set(ivar, nil)
      end
    end
    reset.call
    example.run
    reset.call
  end

  # A stand-in for the companion gem's module. A plain double breaks the
  # lockstep check (Double::VERSION raises TypeError), so build a real Module.
  def fake_binaries_module(msb:, firmware:, version: Microsandbox::VERSION)
    mod = Module.new do
      define_singleton_method(:msb_path) { msb }
      define_singleton_method(:libkrunfw_path) { firmware }
    end
    mod.const_set(:VERSION, version) if version
    mod
  end

  describe ".claim_binaries_gem_slots!" do
    before do
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
    end

    it "feeds the vendored msb into the native set-once slot when the gem is present" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
        .with("/gems/b/vendor/bin/msb")
    end

    it "never touches the firmware slot (libkrunfw resolves by adjacency to the vendored msb)" do
      # Claiming msb + libkrunfw through two independent set-once locks can
      # produce a mixed runtime when the user overrode only one of them; the
      # gem therefore claims exactly one slot and relies on the core ladder's
      # `../lib/` adjacency probe for the firmware.
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_libkrunfw_path)
    end

    it "touches no slot when the gem is absent (or is the empty ruby-platform fallback)" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return(nil)
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_libkrunfw_path)
    end

    it "does not claim when a user runtime_path= landed first, and warns nothing" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox).to receive(:warn)
      Microsandbox.runtime_path = "/opt/user/msb"
      Microsandbox.send(:claim_binaries_gem_slots!)
      # The user's call reached the native slot; the gem saw the ownership and
      # never issued a competing set — and the tier reports itself inactive.
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path).once
        .with("/opt/user/msb")
      expect(Microsandbox.send(:binaries_gem_tier_active?)).to be(false)
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "stands down entirely when a user libkrunfw_path= landed first (no mixed runtime)" do
      # The user's firmware override outranks the adjacency probe that would
      # pair the gem's msb with the gem's own firmware — claiming msb anyway
      # would assemble gem-msb + foreign-firmware. All or nothing: the gem
      # claims NEITHER slot.
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      Microsandbox.libkrunfw_path = "/opt/user/libkrunfw.dylib"
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox.send(:binaries_gem_tier_active?)).to be(false)
    end

    it "stands down entirely when MSB_LIBKRUNFW_PATH is set (checked at claim time)" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      stub_const("ENV", ENV.to_h.merge("MSB_LIBKRUNFW_PATH" => "/opt/env/libkrunfw.dylib"))
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox.send(:binaries_gem_tier_active?)).to be(false)
    end

    it "probes the gem once per process (memoized claim)" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      Microsandbox.send(:claim_binaries_gem_slots!)
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path).once
    end

    it "does not let a concurrent caller slip past an in-progress claim (publishes completion last)" do
      # Regression for the racy first version, which published
      # @binaries_gem_claimed = true BEFORE discovery + the native set: a
      # second thread could observe "claimed", skip initialization, and
      # resolve a lower tier while the first thread was still loading the gem.
      started = Queue.new
      release = Queue.new
      allow(Microsandbox).to receive(:binaries_gem_msb_path) do
        started << true
        release.pop
        "/gems/b/vendor/bin/msb"
      end
      first = Thread.new { Microsandbox.send(:claim_binaries_gem_slots!) }
      started.pop # first thread is inside the claim, pre-publication
      second = Thread.new { Microsandbox.send(:claim_binaries_gem_slots!) }
      # The second caller must block on the in-progress claim, not return early.
      expect(second.join(0.2)).to be_nil
      release << true
      first.join
      second.join
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path).once
        .with("/gems/b/vendor/bin/msb")
    end
  end

  describe ".runtime_path=" do
    before do
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
    end

    it "warns (naming the cause) when the binaries gem already claimed the slot" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:claim_binaries_gem_slots!)
      Microsandbox.runtime_path = "/opt/late/msb"
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("runtime_path= ignored").and(including("microsandbox-rb-binaries")))
    end

    it "keeps the documented silent ignore for a second user call" do
      allow(Microsandbox).to receive(:warn)
      Microsandbox.runtime_path = "/opt/first/msb"
      Microsandbox.runtime_path = "/opt/second/msb"
      expect(Microsandbox).not_to have_received(:warn)
    end
  end

  describe ".binaries_gem_msb_path" do
    it "returns nil when the companion gem is not installed" do
      # The unit suite runs under bundler and the companion gem is deliberately
      # not a dependency, so the require genuinely fails here — this exercises
      # the real LoadError branch, not a stub.
      expect(Microsandbox.send(:binaries_gem_msb_path)).to be_nil
    end

    it "returns the vendored msb when the gem ships the complete runtime" do
      allow(Microsandbox).to receive(:require).with("microsandbox_rb_binaries")
      stub_const("MicrosandboxRbBinaries",
        fake_binaries_module(msb: "/gems/b/vendor/bin/msb", firmware: "/gems/b/vendor/lib/libkrunfw.5.dylib"))
      expect(Microsandbox.send(:binaries_gem_msb_path)).to eq("/gems/b/vendor/bin/msb")
    end

    it "returns nil for the ruby-platform fallback build (gem loads, no binaries)" do
      allow(Microsandbox).to receive(:require).with("microsandbox_rb_binaries")
      stub_const("MicrosandboxRbBinaries", fake_binaries_module(msb: nil, firmware: nil))
      expect(Microsandbox.send(:binaries_gem_msb_path)).to be_nil
    end

    it "treats an incomplete vendor tree (msb without firmware) as tier-absent" do
      # msb alone must not suppress auto-provisioning: the runtime it needs to
      # dlopen is missing, so the tier does not exist.
      allow(Microsandbox).to receive(:require).with("microsandbox_rb_binaries")
      stub_const("MicrosandboxRbBinaries", fake_binaries_module(msb: "/gems/b/vendor/bin/msb", firmware: nil))
      expect(Microsandbox.send(:binaries_gem_msb_path)).to be_nil
    end
  end

  describe "lockstep version check" do
    before do
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox).to receive(:require).with("microsandbox_rb_binaries")
      allow(Microsandbox).to receive(:warn)
    end

    it "warns when the two gems' versions drift, naming both" do
      stub_const("MicrosandboxRbBinaries",
        fake_binaries_module(msb: "/g/msb", firmware: "/g/fw", version: "0.11.0"))
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("0.11.0").and(including(Microsandbox::VERSION)))
    end

    it "stays silent when the versions match" do
      stub_const("MicrosandboxRbBinaries",
        fake_binaries_module(msb: "/g/msb", firmware: "/g/fw", version: Microsandbox::VERSION))
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "skips the comparison for a companion build without VERSION" do
      stub_const("MicrosandboxRbBinaries",
        fake_binaries_module(msb: "/g/msb", firmware: "/g/fw", version: nil))
      expect { Microsandbox.send(:claim_binaries_gem_slots!) }.not_to raise_error
      expect(Microsandbox).not_to have_received(:warn)
    end
  end

  describe ".ensure_runtime! with the binaries gem tier" do
    before do
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:verify_runtime_version!)
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
    end

    it "skips auto-provisioning when the gem provides the runtime, but still verifies the version" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:install)
      expect(Microsandbox).to have_received(:verify_runtime_version!)
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
        .with("/gems/b/vendor/bin/msb")
    end

    it "falls through to auto-provisioning when only the fallback build is installed" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return(nil)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:install)
    end

    it "still auto-provisions when the gem is present but its tier stood down (claim outcome, not presence)" do
      # Behavior fork of the stand-down rule: a suppressed tier provides
      # nothing, so it must not suppress provisioning either — otherwise a
      # user firmware override would leave the process with no runtime at all.
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
      Microsandbox.libkrunfw_path = "/opt/user/libkrunfw.dylib"
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:install)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
    end

    it "verifies but does not install when auto-install is disabled and no gem is present" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return(nil)
      stub_const("ENV", ENV.to_h.merge("MICROSANDBOX_NO_AUTO_INSTALL" => "1"))
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:install)
      expect(Microsandbox).to have_received(:verify_runtime_version!)
    end

    it "re-verifies on every call (per-path caching lives inside the check itself)" do
      # Provisioning is decided once, but the winning tier can change between
      # calls (MSB_PATH edited, PATH entry appeared) — so the check must run
      # each time; its own per-path cache keeps that cheap.
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return(nil)
      Microsandbox.ensure_runtime!
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:install).once # provisioning memoized
      expect(Microsandbox).to have_received(:verify_runtime_version!).twice
    end
  end

  describe ".runtime_path" do
    it "claims the binaries gem tier before resolving" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return("/gems/b/vendor/bin/msb")
      expect(Microsandbox.runtime_path).to eq("/gems/b/vendor/bin/msb")
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
        .with("/gems/b/vendor/bin/msb")
    end
  end

  describe ".verify_runtime_version!" do
    let(:expected) { Microsandbox::RUNTIME_VERSION.delete_prefix("v") }

    # Real executables the check shells out to, so the exit-status, parse, and
    # compare branches run against genuine subprocesses rather than stubs.
    def fake_msb(prints, exit_code: 0, sleep_first: nil, name: "msb")
      path = File.join(@tmp, name)
      body = +"#!/bin/sh\n"
      body << "sleep #{sleep_first}\n" if sleep_first
      body << "echo '#{prints}'\nexit #{exit_code}\n"
      File.write(path, body)
      File.chmod(0o755, path)
      path
    end

    around do |example|
      Dir.mktmpdir do |dir|
        @tmp = dir
        example.run
      end
    end

    it "stays silent when the resolved msb matches the embedded runtime version" do
      path = fake_msb("msb #{expected}")
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(path)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "warns (but does not raise) on a version mismatch, naming both versions" do
      path = fake_msb("msb 0.0.1")
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(path)
      allow(Microsandbox).to receive(:warn)
      expect { Microsandbox.send(:verify_runtime_version!) }.not_to raise_error
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("0.0.1").and(including(expected)))
    end

    it "warns when the binary prints unrecognized version output" do
      path = fake_msb("totally not a version line")
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(path)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("could not verify"))
    end

    it "rejects valid-looking output from a binary that exits nonzero" do
      # Exit status is part of the contract: `msb 0.6.8` on stdout followed by
      # exit 1 is a broken binary, not a verified one.
      path = fake_msb("msb #{expected}", exit_code: 1)
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(path)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("could not verify"))
    end

    it "kills and reports a hung binary instead of blocking first use" do
      path = fake_msb("msb #{expected}", sleep_first: 5)
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(path)
      allow(Microsandbox).to receive(:verify_version_timeout).and_return(0.2)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("did not finish"))
    end

    it "warns when the resolved path cannot be executed" do
      allow(Microsandbox::Native).to receive(:resolved_msb_path)
        .and_return(File.join(@tmp, "does-not-exist"))
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("could not verify"))
    end

    it "warns once (and returns) when nothing resolves at all, without re-warning per call" do
      allow(Microsandbox::Native).to receive(:resolved_msb_path)
        .and_raise(StandardError, "no msb anywhere")
      allow(Microsandbox).to receive(:warn)
      expect { Microsandbox.send(:verify_runtime_version!) }.not_to raise_error
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("could not resolve")).once
    end

    it "checks each resolved path once, and re-checks when the winning tier changes" do
      good = fake_msb("msb #{expected}", name: "msb-good")
      stale = fake_msb("msb 0.0.1", name: "msb-stale")
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(good, good, stale)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!) # good: verified, silent
      Microsandbox.send(:verify_runtime_version!) # good again: cached
      Microsandbox.send(:verify_runtime_version!) # tier changed → re-verify → warn
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("0.0.1")).once
    end

    it "re-verifies through ensure_runtime! when the winner changes between two calls" do
      # End-to-end guard for the @runtime_ready restructure: the second
      # ensure_runtime! must not return before validating the NEW winner.
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return(nil)
      good = fake_msb("msb #{expected}", name: "msb-good")
      stale = fake_msb("msb 0.0.1", name: "msb-stale")
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(good, stale)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.ensure_runtime!
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:install).once
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("0.0.1")).once
    end
  end
end
