# frozen_string_literal: true

require "tmpdir"

# The binaries-gem resolver tier + per-tier runtime version check (prototype of
# the two-gem split from upstream #1305). Everything Native-facing is stubbed:
# the real set_runtime_msb_path consumes a process-wide set-once OnceLock that
# cannot be restored (see runtime_spec.rb), and the real resolver would leak
# the dev box's ~/.microsandbox state into the examples.
RSpec.describe "binaries companion gem integration" do
  around do |example|
    Microsandbox.instance_variable_set(:@runtime_ready, nil)
    Microsandbox.instance_variable_set(:@binaries_gem_claimed, nil)
    example.run
    Microsandbox.instance_variable_set(:@runtime_ready, nil)
    Microsandbox.instance_variable_set(:@binaries_gem_claimed, nil)
  end

  describe ".claim_binaries_gem_slots!" do
    before do
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
    end

    it "feeds both vendored paths into the native set-once slots when the gem is present" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox).to receive(:binaries_gem_libkrunfw_path)
        .and_return("/gems/b/vendor/lib/libkrunfw.5.dylib")
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
        .with("/gems/b/vendor/bin/msb")
      expect(Microsandbox::Native).to have_received(:set_runtime_libkrunfw_path)
        .with("/gems/b/vendor/lib/libkrunfw.5.dylib")
    end

    it "touches neither slot when the gem is absent (or is the empty ruby-platform fallback)" do
      # Absent gem and fallback build are the same signal: msb_path is nil. The
      # slots must stay unclaimed so a later user runtime_path= still lands.
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return(nil)
      allow(Microsandbox).to receive(:binaries_gem_libkrunfw_path).and_return(nil)
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_msb_path)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_libkrunfw_path)
    end

    it "claims the msb slot even when the gem ships no libkrunfw" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox).to receive(:binaries_gem_libkrunfw_path).and_return(nil)
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
      expect(Microsandbox::Native).not_to have_received(:set_runtime_libkrunfw_path)
    end

    it "probes the gem once per process (memoized claim)" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox).to receive(:binaries_gem_libkrunfw_path).and_return(nil)
      Microsandbox.send(:claim_binaries_gem_slots!)
      Microsandbox.send(:claim_binaries_gem_slots!)
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path).once
    end
  end

  describe ".binaries_gem_msb_path" do
    it "returns nil when the companion gem is not installed" do
      # The unit suite runs under bundler and the companion gem is deliberately
      # not a dependency, so the require genuinely fails here — this exercises
      # the real LoadError branch, not a stub.
      expect(Microsandbox.send(:binaries_gem_msb_path)).to be_nil
    end

    it "returns the gem's vendored path when the companion gem loads" do
      allow(Microsandbox).to receive(:require).with("microsandbox_rb_binaries")
      stub_const("MicrosandboxRbBinaries", double(msb_path: "/gems/b/vendor/bin/msb"))
      expect(Microsandbox.send(:binaries_gem_msb_path)).to eq("/gems/b/vendor/bin/msb")
    end

    it "returns nil for the ruby-platform fallback build (gem loads, no binaries)" do
      allow(Microsandbox).to receive(:require).with("microsandbox_rb_binaries")
      stub_const("MicrosandboxRbBinaries", double(msb_path: nil))
      expect(Microsandbox.send(:binaries_gem_msb_path)).to be_nil
    end
  end

  describe ".ensure_runtime! with the binaries gem tier" do
    before do
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:verify_runtime_version!)
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
    end

    it "skips auto-provisioning when the gem provides the runtime, but still verifies the version" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox).to receive(:binaries_gem_libkrunfw_path).and_return(nil)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:install)
      expect(Microsandbox).to have_received(:verify_runtime_version!)
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
        .with("/gems/b/vendor/bin/msb")
    end

    it "falls through to auto-provisioning when only the fallback build is installed" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return(nil)
      allow(Microsandbox).to receive(:binaries_gem_libkrunfw_path).and_return(nil)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:install)
    end

    it "verifies but does not install when auto-install is disabled and no gem is present" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return(nil)
      allow(Microsandbox).to receive(:binaries_gem_libkrunfw_path).and_return(nil)
      stub_const("ENV", ENV.to_h.merge("MICROSANDBOX_NO_AUTO_INSTALL" => "1"))
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:install)
      expect(Microsandbox).to have_received(:verify_runtime_version!)
    end
  end

  describe ".runtime_path" do
    it "claims the binaries gem tier before resolving" do
      allow(Microsandbox).to receive(:binaries_gem_msb_path).and_return("/gems/b/vendor/bin/msb")
      allow(Microsandbox).to receive(:binaries_gem_libkrunfw_path).and_return(nil)
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return("/gems/b/vendor/bin/msb")
      expect(Microsandbox.runtime_path).to eq("/gems/b/vendor/bin/msb")
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
        .with("/gems/b/vendor/bin/msb")
    end
  end

  describe ".verify_runtime_version!" do
    let(:expected) { Microsandbox::RUNTIME_VERSION.delete_prefix("v") }

    # A real executable the check can shell out to, so the parse/compare
    # branches run against genuine `IO.popen` output rather than stubs.
    def fake_msb(dir, prints)
      path = File.join(dir, "msb")
      File.write(path, "#!/bin/sh\necho '#{prints}'\n")
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
      path = fake_msb(@tmp, "msb #{expected}")
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(path)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "warns (but does not raise) on a version mismatch, naming both versions" do
      path = fake_msb(@tmp, "msb 0.0.1")
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(path)
      allow(Microsandbox).to receive(:warn)
      expect { Microsandbox.send(:verify_runtime_version!) }.not_to raise_error
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("0.0.1").and(including(expected)))
    end

    it "warns when the binary prints unrecognized version output" do
      path = fake_msb(@tmp, "totally not a version line")
      allow(Microsandbox::Native).to receive(:resolved_msb_path).and_return(path)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("could not verify"))
    end

    it "warns when the resolved path cannot be executed" do
      allow(Microsandbox::Native).to receive(:resolved_msb_path)
        .and_return(File.join(@tmp, "does-not-exist"))
      allow(Microsandbox).to receive(:warn)
      Microsandbox.send(:verify_runtime_version!)
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("could not verify"))
    end

    it "warns (and returns) when nothing resolves at all" do
      allow(Microsandbox::Native).to receive(:resolved_msb_path)
        .and_raise(StandardError, "no msb anywhere")
      allow(Microsandbox).to receive(:warn)
      expect { Microsandbox.send(:verify_runtime_version!) }.not_to raise_error
      expect(Microsandbox).to have_received(:warn)
        .with(a_string_including("could not resolve"))
    end
  end
end
