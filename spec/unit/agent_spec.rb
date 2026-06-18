# frozen_string_literal: true

# Unit coverage for the raw agent client's pure-Ruby layer (frame parsing,
# stream iteration, client wrapper). The native transport is stubbed; the real
# socket round-trip is exercised by the integration specs.
RSpec.describe "raw agent client" do
  describe Microsandbox::AgentFrame do
    it "exposes id/flags/body and decodes the flag bits" do
      f = described_class.new("id" => 7, "flags" => 0b0000_0011, "body" => "xx".b)
      expect(f.id).to eq(7)
      expect(f.flags).to eq(3)
      expect(f.body).to eq("xx")
      expect(f).to be_terminal
      expect(f).to be_session_start
      expect(f).not_to be_shutdown
    end
  end

  describe Microsandbox::AgentStream do
    let(:native) { instance_double(Microsandbox::Native::AgentClient) }
    subject(:stream) { described_class.new(native, 42, 1) }

    it "exposes the correlation id" do
      expect(stream.id).to eq(42)
    end

    it "is Enumerable and yields frames until recv returns nil" do
      allow(native).to receive(:stream_next).and_return(
        {"id" => 1, "flags" => 0, "body" => "a".b},
        {"id" => 1, "flags" => 1, "body" => "b".b},
        nil
      )
      bodies = stream.map(&:body)
      expect(bodies).to eq(["a", "b"])
    end

    it "returns an Enumerator without a block" do
      expect(stream.each).to be_a(Enumerator)
    end

    it "closes by handle" do
      allow(native).to receive(:stream_close)
      stream.close
      expect(native).to have_received(:stream_close).with(1)
    end
  end

  describe Microsandbox::AgentClient do
    let(:native) { instance_double(Microsandbox::Native::AgentClient) }

    describe ".connect_sandbox" do
      it "forwards name and timeout and wraps the native client" do
        allow(Microsandbox::Native::AgentClient).to receive(:connect_sandbox).and_return(native)
        client = described_class.connect_sandbox("box", timeout: 2.5)
        expect(client).to be_a(described_class)
        expect(Microsandbox::Native::AgentClient).to have_received(:connect_sandbox).with("box", 2.5)
      end

      it "passes nil timeout through" do
        allow(Microsandbox::Native::AgentClient).to receive(:connect_sandbox).and_return(native)
        described_class.connect_sandbox("box")
        expect(Microsandbox::Native::AgentClient).to have_received(:connect_sandbox).with("box", nil)
      end

      it "yields and auto-closes in block form" do
        allow(Microsandbox::Native::AgentClient).to receive(:connect_sandbox).and_return(native)
        allow(native).to receive(:close)
        yielded = nil
        described_class.connect_sandbox("box") { |c| yielded = c }
        expect(yielded).to be_a(described_class)
        expect(native).to have_received(:close)
      end
    end

    it "delegates socket_path to the native layer" do
      allow(Microsandbox::Native::AgentClient).to receive(:socket_path).and_return("/run/box.sock")
      expect(described_class.socket_path("box")).to eq("/run/box.sock")
      expect(Microsandbox::Native::AgentClient).to have_received(:socket_path).with("box")
    end

    describe "instance methods" do
      subject(:client) { described_class.new(native) }

      it "wraps request into an AgentFrame" do
        allow(native).to receive(:request).and_return("id" => 1, "flags" => 0, "body" => "out".b)
        frame = client.request(0, "in")
        expect(frame).to be_a(Microsandbox::AgentFrame)
        expect(frame.body).to eq("out")
        expect(native).to have_received(:request).with(0, "in")
      end

      it "wraps stream_open into an AgentStream" do
        allow(native).to receive(:stream_open).and_return("id" => 9, "handle" => 3)
        stream = client.stream(2, "body")
        expect(stream).to be_a(Microsandbox::AgentStream)
        expect(stream.id).to eq(9)
        expect(native).to have_received(:stream_open).with(2, "body")
      end

      it "maps send_frame to the native send (without shadowing Object#send)" do
        allow(native).to receive(:send)
        expect(client.send_frame(9, 1, "data")).to be_nil
        expect(native).to have_received(:send).with(9, 1, "data")
        # Object#send reflection is intact (not shadowed by a protocol method).
        expect(client.send(:class)).to eq(described_class)
      end

      it "returns ready_bytes and forwards close" do
        allow(native).to receive(:ready_bytes).and_return("rdy".b)
        allow(native).to receive(:close)
        expect(client.ready_bytes).to eq("rdy")
        expect(client.close).to be_nil
        expect(native).to have_received(:close)
      end
    end
  end
end
