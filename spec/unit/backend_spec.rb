# frozen_string_literal: true

# Backend routing surface (v0.5.8 / upstream PR #754). These exercise the
# pure-config selection API; no microVM is booted. Tests avoid leaving a
# non-local backend installed process-wide: only validation errors (which raise
# before installing), the read-only kind query, and `with_backend(:local)`
# (which restores) touch real state.
RSpec.describe "Microsandbox backend routing" do
  describe ".default_backend_kind" do
    it "returns :local or :cloud" do
      expect(%i[local cloud]).to include(Microsandbox.default_backend_kind)
    end

    it "is :local by default (no backend configured)" do
      expect(Microsandbox.default_backend_kind).to eq(:local)
    end
  end

  describe ".default_backend_info" do
    # v0.6.9: a secret-safe description of the resolved default backend. In the
    # unit environment nothing selects a backend, so the final local fallback
    # applies — and the API key is never part of the shape.
    it "describes the default-local fallback without exposing credentials" do
      info = Microsandbox.default_backend_info
      expect(info).to be_a(Microsandbox::BackendInfo)
      expect(info.kind).to eq(:local)
      expect(info).to be_local
      expect(info).not_to be_cloud
      expect(info.api_url).to be_nil
      expect(%i[default programmatic]).to include(info.source)
      expect(info).not_to respond_to(:api_key)
    end
  end

  describe Microsandbox::BackendInfo do
    it "wraps the native hash and symbolizes kind/source" do
      info = described_class.new(
        "kind" => "cloud", "api_url" => "https://api.example.com",
        "source" => "MSB_BACKEND", "profile" => nil
      )
      expect(info.kind).to eq(:cloud)
      expect(info).to be_cloud
      expect(info.source).to eq(:MSB_BACKEND)
      expect(info.api_url).to eq("https://api.example.com")
      expect(info.profile).to be_nil
      expect(info.inspect).not_to include("api_key")
    end
  end

  describe ".set_default_backend" do
    it "rejects an unknown kind with InvalidConfigError" do
      expect { Microsandbox.set_default_backend(:bogus) }
        .to raise_error(Microsandbox::InvalidConfigError, /local.*cloud|cloud.*local/)
    end

    it "rejects cloud without url/api_key/profile with InvalidConfigError" do
      expect { Microsandbox.set_default_backend(:cloud) }
        .to raise_error(Microsandbox::InvalidConfigError, /url.*api_key|profile/)
    end

    it "accepts :local (a no-op-equivalent reinstall of the default)" do
      expect { Microsandbox.set_default_backend(:local) }.not_to raise_error
      expect(Microsandbox.default_backend_kind).to eq(:local)
    end
  end

  describe ".with_backend" do
    it "yields and returns the block's value, restoring the previous backend" do
      result = Microsandbox.with_backend(:local) { :inside }
      expect(result).to eq(:inside)
      expect(Microsandbox.default_backend_kind).to eq(:local)
    end

    it "restores the previous backend even when the block raises" do
      expect {
        Microsandbox.with_backend(:local) { raise "boom" }
      }.to raise_error("boom")
      expect(Microsandbox.default_backend_kind).to eq(:local)
    end

    it "rejects an invalid backend before yielding (nothing to restore)" do
      expect { Microsandbox.with_backend(:cloud) { :never } }
        .to raise_error(Microsandbox::InvalidConfigError)
    end
  end
end
