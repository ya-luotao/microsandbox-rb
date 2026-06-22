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
    around do |example|
      original = begin
        Microsandbox.runtime_path
      rescue Microsandbox::Error
        nil
      end
      example.run
    ensure
      Microsandbox.runtime_path = original if original
    end

    it "overrides the resolved path (SDK tier)" do
      Microsandbox.runtime_path = "/custom/path/to/msb"
      expect(Microsandbox.runtime_path).to eq("/custom/path/to/msb")
    end
  end

  describe ".libkrunfw_path=" do
    it "is callable and forwards to the native set-once setter" do
      # Process-level + set-once at the core; MSB_LIBKRUNFW_PATH still wins. We
      # only assert the binding is wired (no VM boots in unit tests, so the value
      # is inert here).
      expect(Microsandbox.libkrunfw_path = "/custom/path/to/libkrunfw.dylib").to eq("/custom/path/to/libkrunfw.dylib")
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

    it "is a no-op (no install) when the runtime is already present" do
      allow(Microsandbox).to receive(:installed?).and_return(true)
      allow(Microsandbox).to receive(:install)
      Microsandbox.ensure_runtime!
      expect(Microsandbox).not_to have_received(:install)
    end

    it "auto-installs once when the runtime is missing" do
      allow(Microsandbox).to receive(:installed?).and_return(false)
      allow(Microsandbox).to receive(:install)
      allow(Microsandbox).to receive(:warn)
      Microsandbox.ensure_runtime!
      Microsandbox.ensure_runtime! # second call should be memoized, not re-install
      expect(Microsandbox).to have_received(:install).once
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
  end
end
