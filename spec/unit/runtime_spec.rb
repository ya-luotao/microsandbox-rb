# frozen_string_literal: true

RSpec.describe "Microsandbox runtime helpers" do
  describe ".installed?" do
    it "returns a boolean" do
      expect([true, false]).to include(Microsandbox.installed?)
    end
  end

  describe ".runtime_path" do
    it "returns the resolved msb path as a string" do
      path = Microsandbox.runtime_path
      expect(path).to be_a(String)
      expect(path).not_to be_empty
    end
  end

  describe ".runtime_path=" do
    it "forwards the stringified path to the native set-once setter" do
      # Stub the native setter so we (a) actually verify the binding forwards,
      # and (b) never consume the real process-wide set-once OnceLock — it has no
      # getter and cannot be restored, so writing a fake path here would leak
      # into the rest of the process (e.g. a combined unit+integration run with
      # :random order, where a later real-microVM example would then resolve the
      # bogus msb path and fail with an order-dependent boot error). The previous
      # around-hook "restore" was a silent no-op for exactly that reason.
      # Mirrors the .libkrunfw_path= spec below.
      allow(Microsandbox::Native).to receive(:set_runtime_msb_path)
      Microsandbox.runtime_path = "/custom/path/to/msb"
      expect(Microsandbox::Native).to have_received(:set_runtime_msb_path)
        .with("/custom/path/to/msb")
    end
  end

  describe ".libkrunfw_path=" do
    it "forwards the stringified path to the native set-once setter" do
      # Stub the native setter so we (a) actually verify the binding forwards,
      # and (b) never consume the real process-wide set-once OnceLock — it has no
      # getter and cannot be restored, so touching it would leak into a combined
      # unit+integration run. Asserting the assignment's value would be a Ruby
      # tautology (an assignment evaluates to its RHS regardless of the setter),
      # so assert the forwarded native call instead.
      allow(Microsandbox::Native).to receive(:set_runtime_libkrunfw_path)
      Microsandbox.libkrunfw_path = "/custom/path/to/libkrunfw.dylib"
      expect(Microsandbox::Native).to have_received(:set_runtime_libkrunfw_path)
        .with("/custom/path/to/libkrunfw.dylib")
    end
  end

  describe "Native module" do
    it "exposes the expected module functions" do
      %i[
        version install installed? set_runtime_msb_path set_runtime_libkrunfw_path
        resolved_msb_path set_default_backend push_default_backend pop_default_backend
        default_backend_kind
      ].each do |m|
        expect(Microsandbox::Native).to respond_to(m)
      end
    end
  end

  describe ".ensure_runtime!" do
    # The memoized "ready" flag would leak across examples (and from a real
    # source-built runtime on the dev box), so reset it around each one.
    around do |example|
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
      example.run
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
    end

    it "still runs the version-correcting installer when the runtime is present" do
      # Regression guard for the stale-runtime boot failure (issue #18):
      # `installed?` checks file *presence* only, so a stale msb left by an older
      # gem passes it. `install` is idempotent + version-correcting (cheap
      # `msb --version`, re-downloads only on mismatch), so ensure_runtime! must
      # delegate to it even when present rather than short-circuit. It must NOT
      # warn in this case (nothing is missing).
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.ensure_runtime!
      Microsandbox.ensure_runtime! # second call is memoized, not re-checked
      expect(Microsandbox).to have_received(:install).once
      expect(Microsandbox).not_to have_received(:warn)
    end

    it "auto-installs once (with a notice) when the runtime is missing" do
      allow(Microsandbox).to receive(:installed?).and_return(false)
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.ensure_runtime!
      Microsandbox.ensure_runtime! # second call should be memoized, not re-install
      expect(Microsandbox).to have_received(:install).once
      expect(Microsandbox).to have_received(:warn).once
    end

    it "does not auto-install when MICROSANDBOX_NO_AUTO_INSTALL is set" do
      allow(Microsandbox).to receive(:installed?).and_return(false)
      allow(Microsandbox).to receive(:install)
      stub_const("ENV", ENV.to_h.merge("MICROSANDBOX_NO_AUTO_INSTALL" => "1"))
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:install)
    end

    it "treats MICROSANDBOX_NO_AUTO_INSTALL=0/false as 'not disabled'" do
      allow(Microsandbox).to receive(:installed?).and_return(false)
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:warn)
      stub_const("ENV", ENV.to_h.merge("MICROSANDBOX_NO_AUTO_INSTALL" => "false"))
      Microsandbox.ensure_runtime!
      expect(Microsandbox).to have_received(:install)
    end

    it "skips the local-runtime check entirely under a cloud backend" do
      # A cloud backend has no local msb/libkrunfw to provision, so neither the
      # presence/version check nor a download should run.
      allow(Microsandbox).to receive(:default_backend_kind).and_return(:cloud)
      allow(Microsandbox).to receive(:installed?)
      allow(Microsandbox).to receive(:install)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:installed?)
      expect(Microsandbox).not_to have_received(:install)
    end
  end
end
