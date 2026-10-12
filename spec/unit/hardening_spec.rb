# frozen_string_literal: true

# Regression coverage for the argument guards and cleanup semantics that have
# no natural home in a per-class spec: errors that must name a type instead of
# echoing a value, block forms that must not replace the caller's exception,
# and runtime provisioning that must not run before validation or twice.
RSpec.describe "argument guards and cleanup semantics" do
  let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }

  before do
    allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native)
    allow(Microsandbox).to receive(:ensure_runtime!)
  end

  def create_opts(**kwargs)
    Microsandbox::Sandbox.create("box", **kwargs)
    opts = nil
    expect(Microsandbox::Native::Sandbox).to have_received(:create) { |_name, given| opts = given }
    opts
  end

  describe "create-time validation" do
    it "rejects patches: together with from_snapshot: before anything is created" do
      expect { Microsandbox::Sandbox.create("box", from_snapshot: "snap", patches: [Microsandbox::Patch.mkdir("/d")]) }
        .to raise_error(ArgumentError, /patches: cannot be combined with from_snapshot:/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "still allows from_snapshot: with no patches" do
      expect(create_opts(from_snapshot: "snap", patches: [])).to include("from_snapshot" => "snap")
    end

    it "does not provision the runtime when an option is rejected" do
      expect { Microsandbox::Sandbox.create("box", image: "python", from_snapshot: "snap") }
        .to raise_error(ArgumentError)
      expect { Microsandbox::Sandbox.connect_or_create("box", image: "python", cpus: "many") }
        .to raise_error(ArgumentError)
      expect { Microsandbox::Sandbox.create_with_progress("box", image: "python", fstype: "ext4") }
        .to raise_error(ArgumentError)
      expect(Microsandbox).not_to have_received(:ensure_runtime!)
    end

    it "provisions the runtime once the options are accepted" do
      Microsandbox::Sandbox.create("box", image: "python")
      expect(Microsandbox).to have_received(:ensure_runtime!).once
    end
  end

  describe "secrets: at create time" do
    it "explains the modify-shaped Hash instead of raising TypeError" do
      expect { Microsandbox::Sandbox.create("box", image: "python", secrets: {"API_KEY" => {value: "SYNTHETIC-SECRET", hosts: ["api.example.com"]}}) }
        .to raise_error(ArgumentError) { |e|
          expect(e.message).to match(/takes an Array of Hashes .* at create time/)
          expect(e.message).not_to include("SYNTHETIC")
        }
    end

    it "accepts one bare spec Hash as a list of one" do
      opts = create_opts(image: "python", secrets: {env: "API_KEY", value: "v", host: "api.example.com"})
      expect(opts["secrets"]).to eq([{"env" => "API_KEY", "value" => "v", "hosts" => ["api.example.com"]}])
    end

    it "names the class of a non-Hash spec, never its content" do
      expect { Microsandbox::Sandbox.create("box", image: "python", secrets: ["SYNTHETIC-SECRET"]) }
        .to raise_error(ArgumentError) { |e|
          expect(e.message).to eq("secret spec must be a Hash (got String)")
        }
    end
  end

  describe "errors that must not echo values" do
    it "names the class when env: / labels: / scripts: is not a Hash" do
      %i[env labels scripts].each do |option|
        expect { Microsandbox::Sandbox.create("box", **{:image => "python", option => "TOKEN=SYNTHETIC-SECRET"}) }
          .to raise_error(ArgumentError) { |e|
            expect(e.message).to eq("expected a Hash of names to values (got String)")
          }
      end
    end

    it "still accepts ENV and a list of pairs where a Hash is expected" do
      stub_const("ENV", ENV.to_h.merge("MSB_RB_SPEC_VAR" => "1"))
      expect(create_opts(image: "python", env: [["A", 1], [:B, "2"]])["env"]).to eq("A" => "1", "B" => "2")
      expect(Microsandbox::Sandbox.send(:stringify, ::ENV)).to be_a(Hash)
      expect { Microsandbox::Sandbox.send(:stringify, ["TOKEN=SYNTHETIC-SECRET"]) }
        .to raise_error(ArgumentError, "expected a Hash of names to values (got Array)")
    end

    it "names the class of a malformed patch, never its content" do
      expect { Microsandbox::Sandbox.create("box", image: "python", patches: ["SYNTHETIC-SECRET"]) }
        .to raise_error(ArgumentError) { |e|
          expect(e.message).to eq("patch must be a Hash (use Microsandbox::Patch.*), got String")
        }
    end

    it "treats a single patch Hash as a list of one" do
      opts = create_opts(image: "python", patches: Microsandbox::Patch.mkdir("/d"))
      expect(opts["patches"]).to eq([{"kind" => "mkdir", "path" => "/d"}])
    end

    it "refuses a URL-style proxy address without repeating it" do
      ["socks5://user:SYNTHETIC-SECRET@127.0.0.1:1080", "user:SYNTHETIC-SECRET@127.0.0.1:1080",
        "socks5://127.0.0.1:1080", "127.0.0.1 1080"].each do |address|
        expect { Microsandbox::OutboundProxy.socks5(address) }
          .to raise_error(ArgumentError) { |e|
            expect(e.message).to match(/must be "IP:port" with no scheme, credentials or whitespace/)
            expect(e.message).not_to include("SYNTHETIC")
          }
      end
    end

    it "still accepts IPv4 and bracketed IPv6 proxy addresses" do
      expect(Microsandbox::OutboundProxy.socks5("127.0.0.1:1080").address).to eq("127.0.0.1:1080")
      expect(Microsandbox::OutboundProxy.socks5("[::1]:1080").address).to eq("[::1]:1080")
    end
  end

  describe "Microsandbox.time_from_ms" do
    it "is exact to the millisecond" do
      base = 1_760_000_000_000
      (0...2000).each do |offset|
        ms = base + offset
        time = Microsandbox.time_from_ms(ms)
        expect((time.to_r * 1000).to_i).to eq(ms)
      end
    end

    it "passes nil through and backs the value objects" do
      expect(Microsandbox.time_from_ms(nil)).to be_nil
      entry = Microsandbox::FsEntry.new("path" => "/f", "type" => "file", "size" => 1, "mode" => 0o644, "modified_ms" => 1_760_000_000_001)
      expect(entry.modified.strftime("%L")).to eq("001")
    end
  end

  describe "Microsandbox.close_after (block forms that own a resource)" do
    let(:resource) { double("resource", close: nil) }

    it "returns the block's value and closes" do
      expect(Microsandbox.close_after(resource) { :value }).to eq(:value)
      expect(resource).to have_received(:close).once
    end

    it "keeps the block's exception when the close that follows also fails" do
      allow(resource).to receive(:close).and_raise(Microsandbox::Error, "close failed")
      expect { Microsandbox.close_after(resource) { raise KeyError, "from the block" } }
        .to raise_error(KeyError, "from the block")
      expect(resource).to have_received(:close).once
    end

    it "surfaces a close failure when the block finished" do
      allow(resource).to receive(:close).and_raise(Microsandbox::Error, "flush failed")
      expect { Microsandbox.close_after(resource) { :ok } }.to raise_error(Microsandbox::Error, "flush failed")
    end

    it "surfaces a close failure when the block left with break" do
      allow(resource).to receive(:close).and_raise(Microsandbox::Error, "flush failed")
      leave_early = -> { [1].each { Microsandbox.close_after(resource) { break } } }
      expect(&leave_early).to raise_error(Microsandbox::Error, "flush failed")
    end

    it "is what FS#write_stream uses" do
      sink_native = double("native sink", close: nil)
      allow(sink_native).to receive(:close).and_raise(Microsandbox::Error, "close failed")
      allow(native).to receive(:fs_write_stream).with("/f").and_return(sink_native)
      fs = Microsandbox::FS.new(native)
      expect { fs.write_stream("/f") { raise KeyError, "from the block" } }.to raise_error(KeyError, "from the block")
    end
  end

  describe Microsandbox::PullSession do
    it "re-raises the original failure on a second #sandbox call" do
      session_native = instance_double(Microsandbox::Native::PullSession)
      calls = 0
      allow(session_native).to receive(:result) do
        calls += 1
        raise Microsandbox::ImageNotFoundError, "pull failed" if calls == 1
        raise Microsandbox::Error, "result already taken"
      end
      session = described_class.new(session_native)
      2.times { expect { session.sandbox }.to raise_error(Microsandbox::ImageNotFoundError, "pull failed") }
      expect(calls).to eq(1)
    end
  end

  describe "Microsandbox.ensure_runtime! under concurrency" do
    around do |example|
      bundled = Microsandbox.instance_variable_get(:@bundled_msb_path)
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
      Microsandbox.instance_variable_set(:@bundled_msb_path, nil)
      example.run
    ensure
      Microsandbox.instance_variable_set(:@runtime_ready, nil)
      Microsandbox.instance_variable_set(:@bundled_msb_path, bundled)
    end

    it "runs the installer once when several threads hit a first create together" do
      allow(Microsandbox).to receive(:ensure_runtime!).and_call_original
      allow(Microsandbox).to receive(:installed?).and_return(true)
      installs = 0
      allow(Microsandbox).to receive(:install) do
        installs += 1
        sleep 0.05
      end
      Array.new(4) { Thread.new { Microsandbox.ensure_runtime! } }.each(&:join)
      expect(installs).to eq(1)
    end
  end
end
