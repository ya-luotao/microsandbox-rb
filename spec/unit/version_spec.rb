# frozen_string_literal: true

RSpec.describe Microsandbox do
  describe "VERSION" do
    it "is a semantic version string" do
      expect(Microsandbox::VERSION).to match(/\A\d+\.\d+\.\d+/)
    end
  end

  describe ".version" do
    it "returns the gem version" do
      expect(Microsandbox.version).to eq(Microsandbox::VERSION)
    end

    it "agrees with the native extension version" do
      expect(Microsandbox::Native.version).to eq(Microsandbox::VERSION)
    end
  end
end
