# frozen_string_literal: true

# These specs exercise the pure-Ruby option normalization in Microsandbox::Sandbox
# WITHOUT booting a real microVM, by stubbing the native layer. The native
# binding itself is covered by the integration specs.
RSpec.describe Microsandbox::Sandbox do
  let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }

  before do
    allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native)
  end

  describe ".create option mapping" do
    it "normalizes keyword args into a string-keyed options hash" do
      Microsandbox::Sandbox.create(
        "box",
        image: "python", cpus: 2, memory: 1024,
        env: { FOO: 1, "BAR" => :baz }, workdir: "/app",
        labels: { team: "core" }, ports: { "8080" => 80 },
        network: :public_only, entrypoint: %w[/bin/sh -c]
      )

      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "image" => "python",
          "cpus" => 2,
          "memory" => 1024,
          "workdir" => "/app",
          "env" => { "FOO" => "1", "BAR" => "baz" },
          "labels" => { "team" => "core" },
          "ports" => { 8080 => 80 },
          "network" => "public_only",
          "entrypoint" => ["/bin/sh", "-c"]
        )
      )
    end

    it "omits unspecified options" do
      Microsandbox::Sandbox.create("box", image: "alpine")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", { "image" => "alpine" }
      )
    end

    it "maps pull_policy and normalizes secrets into [env, value, host] triples" do
      Microsandbox::Sandbox.create(
        "box", image: "x", pull_policy: "never",
        secrets: [{ env: "OPENAI_API_KEY", value: "sk-123", host: "api.openai.com" }]
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "pull_policy" => "never",
          "secrets" => [["OPENAI_API_KEY", "sk-123", "api.openai.com"]]
        )
      )
    end

    it "raises on a malformed secret spec" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{ env: "X" }])
      end.to raise_error(ArgumentError, /:env, :value, and :host/)
    end

    it "passes the network policy preset string through" do
      Microsandbox::Sandbox.create("box", image: "x", network: :allow_all)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("network" => "allow_all")
      )
    end

    it "normalizes the resource/limit scalar options" do
      Microsandbox::Sandbox.create(
        "box", image: "x", log_level: :debug, quiet_logs: true, security: "restricted",
        oci_upper_size: 2048, max_duration: 600, idle_timeout: 120,
        ports_udp: { "53" => 53 }, rlimits: { nofile: 1024, cpu: [10, 20] }
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "log_level" => "debug", "quiet_logs" => true, "security" => "restricted",
          "oci_upper_size" => 2048, "max_duration" => 600, "idle_timeout" => 120,
          "ports_udp" => { 53 => 53 },
          "rlimits" => [["nofile", 1024, 1024], ["cpu", 10, 20]]
        )
      )
    end

    it "prefers replace_with_timeout over replace" do
      Microsandbox::Sandbox.create("box", image: "x", replace: true, replace_with_timeout: 5)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("replace_with_timeout" => 5.0)
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_excluding("replace")
      )
    end

    it "returns a Sandbox when no block is given" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect(sb).to be_a(Microsandbox::Sandbox)
      expect(sb.name).to eq("box")
    end

    it "yields the sandbox and stops it (block form), returning the block value" do
      result = Microsandbox::Sandbox.create("box", image: "x") do |sb|
        expect(sb).to be_a(Microsandbox::Sandbox)
        :done
      end
      expect(result).to eq(:done)
      expect(native).to have_received(:stop)
    end

    it "stops the sandbox even if the block raises" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x") { raise "boom" }
      end.to raise_error("boom")
      expect(native).to have_received(:stop)
    end
  end

  describe "#exec option mapping" do
    let(:exec_result) do
      { "exit_code" => 0, "success" => true, "stdout" => "".b, "stderr" => "".b }
    end

    before { allow(native).to receive(:exec).and_return(exec_result) }

    it "passes command, args, and a normalized options hash" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      out = sb.exec("ls", ["-l", :foo], cwd: "/tmp", env: { A: 1 }, timeout: 5, tty: true, stdin: "in")

      expect(native).to have_received(:exec).with(
        "ls", ["-l", "foo"],
        hash_including("cwd" => "/tmp", "env" => { "A" => "1" }, "timeout" => 5.0, "tty" => true, "stdin" => "in")
      )
      expect(out).to be_a(Microsandbox::ExecOutput)
    end

    it "defaults args to an empty array" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.exec("whoami")
      expect(native).to have_received(:exec).with("whoami", [], {})
    end

    it "normalizes per-exec rlimits into [resource, soft, hard] triples" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.exec("ls", [], rlimits: { nofile: 256, as: [1000, 2000] })
      expect(native).to have_received(:exec).with(
        "ls", [], hash_including("rlimits" => [["nofile", 256, 256], ["as", 1000, 2000]])
      )
    end
  end

  describe "#shell option mapping" do
    before do
      allow(native).to receive(:shell).and_return(
        { "exit_code" => 0, "success" => true, "stdout" => "".b, "stderr" => "".b }
      )
    end

    it "passes the script and normalized options" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.shell("echo hi", timeout: 2)
      expect(native).to have_received(:shell).with("echo hi", hash_including("timeout" => 2.0))
    end
  end

  describe "#stop / #kill" do
    it "forwards optional float timeouts" do
      allow(native).to receive(:kill)
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.stop(timeout: 3)
      sb.kill
      expect(native).to have_received(:stop).with(3.0)
      expect(native).to have_received(:kill).with(nil)
    end
  end

  describe "async lifecycle controls" do
    subject(:sb) { Microsandbox::Sandbox.create("box", image: "x") }

    it "forwards request_stop/request_kill/request_drain and detach, returning nil" do
      allow(native).to receive(:request_stop)
      allow(native).to receive(:request_kill)
      allow(native).to receive(:request_drain)
      allow(native).to receive(:detach)

      expect(sb.request_stop).to be_nil
      expect(sb.request_kill).to be_nil
      expect(sb.request_drain).to be_nil
      expect(sb.detach).to be_nil

      expect(native).to have_received(:request_stop)
      expect(native).to have_received(:request_kill)
      expect(native).to have_received(:request_drain)
      expect(native).to have_received(:detach)
    end

    it "exposes owns_lifecycle? as a boolean predicate" do
      allow(native).to receive(:owns_lifecycle).and_return(true)
      expect(sb.owns_lifecycle?).to be(true)
    end

    it "wraps wait_until_stopped in a SandboxStopResult" do
      allow(native).to receive(:wait_until_stopped).and_return(
        "name" => "box", "status" => "stopped", "exit_code" => 0,
        "signal" => nil, "observed_at_ms" => 1_700_000_000_000, "source" => "owned process handle"
      )
      result = sb.wait_until_stopped
      expect(result).to be_a(Microsandbox::SandboxStopResult)
      expect(result).to be_stopped
      expect(result.exit_code).to eq(0)
      expect(result.name).to eq("box")
    end
  end

  describe "streaming logs/metrics" do
    subject(:sb) { Microsandbox::Sandbox.create("box", image: "x") }

    it "maps metrics_stream interval and wraps recv in Metrics" do
      native_stream = instance_double(Microsandbox::Native::MetricsStream)
      allow(native).to receive(:metrics_stream).and_return(native_stream)
      allow(native_stream).to receive(:recv).and_return(
        {
          "cpu_percent" => 5.0, "vcpu_time_ns" => 1, "memory_bytes" => 2,
          "memory_available_bytes" => nil, "memory_host_resident_bytes" => nil,
          "memory_limit_bytes" => 4, "disk_read_bytes" => 0, "disk_write_bytes" => 0,
          "net_rx_bytes" => 0, "net_tx_bytes" => 0, "uptime_secs" => 1.0,
          "timestamp_ms" => 1_700_000_000_000
        },
        nil
      )
      stream = sb.metrics_stream(interval: 0.5)
      expect(native).to have_received(:metrics_stream).with(0.5)
      snapshots = stream.to_a
      expect(snapshots.size).to eq(1)
      expect(snapshots.first).to be_a(Microsandbox::Metrics)
      expect(snapshots.first.cpu_percent).to eq(5.0)
    end

    it "normalizes log_stream options and wraps recv in LogEntry" do
      native_stream = instance_double(Microsandbox::Native::LogStream)
      allow(native).to receive(:log_stream).and_return(native_stream)
      allow(native_stream).to receive(:recv).and_return(
        { "timestamp_ms" => 1_700_000_000_000, "source" => "stdout",
          "session_id" => 1, "cursor" => "abc", "data" => "hi".b },
        nil
      )
      stream = sb.log_stream(sources: [:stdout, "stderr"], since_ms: 1000, until_ms: 2000, follow: true)
      expect(native).to have_received(:log_stream).with(
        hash_including("sources" => %w[stdout stderr], "since_ms" => 1000.0,
                       "until_ms" => 2000.0, "follow" => true)
      )
      entries = stream.to_a
      expect(entries.first).to be_a(Microsandbox::LogEntry)
      expect(entries.first.text).to eq("hi")
    end

    it "prefers from_cursor and returns an Enumerator without a block" do
      native_stream = instance_double(Microsandbox::Native::LogStream)
      allow(native).to receive(:log_stream).and_return(native_stream)
      sb.log_stream(from_cursor: "cursor-token")
      expect(native).to have_received(:log_stream).with(
        hash_including("from_cursor" => "cursor-token")
      )
      expect(Microsandbox::LogStream.new(native_stream).each).to be_a(Enumerator)
    end
  end

  describe ".list_with" do
    it "normalizes label filters into a string-keyed labels hash" do
      allow(Microsandbox::Native::Sandbox).to receive(:list_with).and_return(
        [{ "name" => "box", "status" => "running" }]
      )
      infos = Microsandbox::Sandbox.list_with(labels: { team: :core })
      expect(Microsandbox::Native::Sandbox).to have_received(:list_with).with(
        "labels" => { "team" => "core" }
      )
      expect(infos.first).to be_a(Microsandbox::SandboxInfo)
      expect(infos.first.name).to eq("box")
    end
  end
end

RSpec.describe "Microsandbox.all_sandbox_metrics" do
  it "wraps each per-sandbox metrics hash in a Metrics object" do
    allow(Microsandbox::Native).to receive(:all_sandbox_metrics).and_return(
      "box" => {
        "cpu_percent" => 12.5, "vcpu_time_ns" => 1, "memory_bytes" => 2,
        "memory_available_bytes" => nil, "memory_host_resident_bytes" => nil,
        "memory_limit_bytes" => 4, "disk_read_bytes" => 0, "disk_write_bytes" => 0,
        "net_rx_bytes" => 0, "net_tx_bytes" => 0, "uptime_secs" => 1.0,
        "timestamp_ms" => 1_700_000_000_000
      }
    )
    metrics = Microsandbox.all_sandbox_metrics
    expect(metrics.keys).to eq(["box"])
    expect(metrics["box"]).to be_a(Microsandbox::Metrics)
    expect(metrics["box"].cpu_percent).to eq(12.5)
  end
end
