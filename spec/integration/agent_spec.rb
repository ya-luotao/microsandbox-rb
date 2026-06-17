# frozen_string_literal: true

# Real-microVM integration coverage for the raw agent client. Opt-in via
# MICROSANDBOX_INTEGRATION=1. Exercises socket resolution, the connection
# handshake, and the cached ready frame without hand-rolling CBOR request bodies.
RSpec.describe Microsandbox::AgentClient, :integration do
  let(:image) { default_test_image }

  it "resolves a sandbox's relay socket path without connecting" do
    path = described_class.socket_path("any-name")
    expect(path).to be_a(String)
    expect(path).not_to be_empty
  end

  it "connects to a running sandbox, reads the handshake, and closes" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      described_class.connect_sandbox(sb.name, timeout: 10) do |client|
        ready = client.ready_bytes
        expect(ready).to be_a(String)
        expect(ready.encoding).to eq(Encoding::ASCII_8BIT)
      end
    end
  end
end
