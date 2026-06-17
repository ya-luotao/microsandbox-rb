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

  describe "Native module" do
    it "exposes the expected module functions" do
      %i[version install installed? set_runtime_msb_path resolved_msb_path].each do |m|
        expect(Microsandbox::Native).to respond_to(m)
      end
    end
  end
end
