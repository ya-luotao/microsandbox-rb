# frozen_string_literal: true

# These specs exercise the pure-Ruby option normalization in Microsandbox::Sandbox
# WITHOUT booting a real microVM, by stubbing the native layer. The native
# binding itself is covered by the integration specs.
RSpec.describe Microsandbox::Sandbox do
  let(:native) { instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil) }

  before do
    allow(Microsandbox::Native::Sandbox).to receive(:create).and_return(native)
    # Don't let the auto-provision hook touch the filesystem / network in unit
    # tests; runtime provisioning is covered separately in runtime_spec.
    allow(Microsandbox).to receive(:ensure_runtime!)
  end

  describe ".create option mapping" do
    it "normalizes keyword args into a string-keyed options hash" do
      Microsandbox::Sandbox.create(
        "box",
        image: "python", cpus: 2, memory: 1024,
        env: {:FOO => 1, "BAR" => :baz}, workdir: "/app",
        labels: {team: "core"}, ports: {"8080" => 80},
        network: :public_only, entrypoint: %w[/bin/sh -c]
      )

      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "image" => "python",
          "cpus" => 2,
          "memory" => 1024,
          "workdir" => "/app",
          "env" => {"FOO" => "1", "BAR" => "baz"},
          "labels" => {"team" => "core"},
          "ports" => {8080 => 80},
          "network" => "public_only",
          "entrypoint" => ["/bin/sh", "-c"]
        )
      )
    end

    it "omits unspecified options" do
      Microsandbox::Sandbox.create("box", image: "alpine")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", {"image" => "alpine"}
      )
    end

    it "ensures the runtime is provisioned before creating" do
      Microsandbox::Sandbox.create("box", image: "x")
      expect(Microsandbox).to have_received(:ensure_runtime!)
    end

    it "create_with_progress forwards the same options and returns a PullSession" do
      session_native = instance_double(Microsandbox::Native::PullSession)
      allow(Microsandbox::Native::Sandbox).to receive(:create_with_progress)
        .and_return(session_native)
      session = Microsandbox::Sandbox.create_with_progress("box", image: "python", cpus: 2)
      expect(session).to be_a(Microsandbox::PullSession)
      expect(Microsandbox::Native::Sandbox).to have_received(:create_with_progress)
        .with("box", hash_including("image" => "python", "cpus" => 2))
    end

    it "create_with_progress rejects a block (which would silently leak the sandbox)" do
      allow(Microsandbox::Native::Sandbox).to receive(:create_with_progress)
      expect do
        Microsandbox::Sandbox.create_with_progress("box", image: "python") { |sb| sb }
      end.to raise_error(ArgumentError, /takes no block/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create_with_progress)
    end

    it "flattens registry_auth into registry_username/registry_password" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        registry_auth: {username: "alice", password: "s3cr3t"}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("registry_username" => "alice", "registry_password" => "s3cr3t")
      )
    end

    it "accepts string-keyed registry_auth and passes insecure + ca_certs through" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        registry_auth: {"username" => "bob", "password" => "tok"},
        registry_insecure: true,
        registry_ca_certs: "-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----"
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "registry_username" => "bob", "registry_password" => "tok",
          "registry_insecure" => true,
          "registry_ca_certs" => ["-----BEGIN CERTIFICATE-----\nabc\n-----END CERTIFICATE-----"]
        )
      )
    end

    it "wraps a single ca_cert and an array of ca_certs the same way" do
      Microsandbox::Sandbox.create(
        "box", image: "x", registry_ca_certs: %w[pem-a pem-b]
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("registry_ca_certs" => %w[pem-a pem-b])
      )
    end

    it "omits registry keys entirely when no registry options are given" do
      Microsandbox::Sandbox.create("box", image: "x")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_excluding("registry_username", "registry_insecure", "registry_ca_certs")
      )
    end

    it "raises on a half-specified registry_auth (missing password)" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", registry_auth: {username: "alice"})
      end.to raise_error(ArgumentError, /:username and :password/)
    end

    it "maps pull_policy and normalizes a simple secret (host -> hosts)" do
      Microsandbox::Sandbox.create(
        "box", image: "x", pull_policy: "never",
        secrets: [{env: "OPENAI_API_KEY", value: "sk-123", host: "api.openai.com"}]
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "pull_policy" => "never",
          "secrets" => [{"env" => "OPENAI_API_KEY", "value" => "sk-123",
                         "hosts" => ["api.openai.com"]}]
        )
      )
    end

    it "normalizes the full secret surface (patterns, injection, violation)" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        secrets: [{
          env: "STRIPE_KEY", value: "sk_live", hosts: ["api.stripe.com"],
          host_patterns: ["*.stripe.com"], placeholder: "$STRIPE", require_tls: true,
          inject_headers: true, inject_query: false, inject_body: true,
          on_violation: "block_and_terminate"
        }],
        on_secret_violation: {passthrough_hosts: ["10.0.0.1"]}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "secrets" => [{
            "env" => "STRIPE_KEY", "value" => "sk_live", "hosts" => ["api.stripe.com"],
            "host_patterns" => ["*.stripe.com"], "placeholder" => "$STRIPE",
            "require_tls" => true, "inject_headers" => true, "inject_query" => false,
            "inject_body" => true, "on_violation" => "block_and_terminate"
          }],
          "on_secret_violation" => {"passthrough_hosts" => ["10.0.0.1"]}
        )
      )
    end

    it "raises on a secret spec missing env/value" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "X"}])
      end.to raise_error(ArgumentError, /:env and :value/)
    end

    it "raises on a secret spec with no allowed host" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "X", value: "y"}])
      end.to raise_error(ArgumentError, /:host, :hosts, or :host_patterns/)
    end

    it "maps fstype, a String init, and ephemeral" do
      Microsandbox::Sandbox.create(
        "box", image: "/img/alpine.raw", fstype: "ext4",
        init: "/sbin/init", ephemeral: true
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "image" => "/img/alpine.raw", "fstype" => "ext4",
          "init" => {"cmd" => "/sbin/init"}, "ephemeral" => true
        )
      )
    end

    it "rejects fstype: paired with an OCI image reference" do
      expect do
        Microsandbox::Sandbox.create("box", image: "python", fstype: "ext4")
      end.to raise_error(ArgumentError, /fstype: only applies to a disk-image rootfs/)
    end

    # Pins the disk_image_rootfs? heuristic that gates the fstype:-vs-OCI check.
    # It hand-mirrors upstream's looks_like_local_path_text (path prefix) +
    # DiskImageFormat::from_extension (qcow2/raw/vmdk); this guards against drift
    # if a runtime-tag bump changes either set. Expectations are hardcoded here
    # (not derived from the constant) so a wrong constant value is caught.
    describe "disk_image_rootfs? contract" do
      def disk?(image) = Microsandbox::Sandbox.send(:disk_image_rootfs?, image)

      it "accepts a local-path-looking disk image (any recognized extension, any case)" do
        expect(disk?("/img/alpine.raw")).to be(true)
        expect(disk?("./disk.qcow2")).to be(true)
        expect(disk?("../vm.vmdk")).to be(true)
        expect(disk?("/img/alpine.RAW")).to be(true) # extension match is case-insensitive
      end

      it "rejects an OCI ref, a path without a local prefix, and a non-disk extension" do
        expect(disk?("python")).to be(false)           # bare OCI reference
        expect(disk?("alpine.raw")).to be(false)        # no /, ./, ../ prefix
        expect(disk?("/img/rootfs.tar")).to be(false)   # unrecognized extension
        expect(disk?("/img/rootfs")).to be(false)       # no extension
      end
    end

    it "accepts the upstream kebab-case violation spellings" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        secrets: [{env: "K", value: "v", hosts: ["api.example.com"],
                   on_violation: "block-and-terminate"}],
        on_secret_violation: "block-and-log"
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "secrets" => [hash_including("on_violation" => "block_and_terminate")],
          "on_secret_violation" => "block_and_log"
        )
      )
    end

    it "maps the bare \"passthrough\" string to passthrough-all-hosts (SDK parity)" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        secrets: [{env: "K", value: "v", hosts: ["api.example.com"], on_violation: "passthrough"}],
        on_secret_violation: "passthrough"
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "secrets" => [hash_including("on_violation" => {"passthrough_all_hosts" => true})],
          "on_secret_violation" => {"passthrough_all_hosts" => true}
        )
      )
    end

    it "raises on an unknown violation action string" do
      expect do
        Microsandbox::Sandbox.create(
          "box", image: "x", on_secret_violation: "nope"
        )
      end.to raise_error(ArgumentError, /unknown on_violation "nope"/)
    end

    it "rejects an effectively-empty passthrough Hash (a no-op spec)" do
      expect do
        Microsandbox::Sandbox.create(
          "box", image: "x", on_secret_violation: {passthrough_hosts: []}
        )
      end.to raise_error(ArgumentError, /passthrough on_violation needs at least one/)
    end

    it "normalizes a Hash init with args and env" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        init: {cmd: "/lib/systemd/systemd", args: ["--unit=multi-user.target"],
               env: {container: "microsandbox"}}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("init" => {
          "cmd" => "/lib/systemd/systemd",
          "args" => ["--unit=multi-user.target"],
          "env" => {"container" => "microsandbox"}
        })
      )
    end

    it "raises on a Hash init without :cmd" do
      expect { Microsandbox::Sandbox.create("box", image: "x", init: {args: ["a"]}) }
        .to raise_error(ArgumentError, /:cmd/)
    end

    it "passes the network policy preset string through" do
      Microsandbox::Sandbox.create("box", image: "x", network: :allow_all)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("network" => "allow_all")
      )
    end

    it "normalizes dns/tls/pools/max_connections/trust_host_cas" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        dns: {nameservers: ["1.1.1.1"], rebind_protection: true, query_timeout_ms: 2000},
        tls: {bypass: ["pinned.example.com"], verify_upstream: false,
              intercepted_ports: [443, 8443], block_quic: true, intercept_ca_cert: "/ca.pem"},
        ipv4_pool: "10.0.0.0/24", ipv6_pool: "fd00::/64",
        max_connections: 128, trust_host_cas: true
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "dns" => {"nameservers" => ["1.1.1.1"], "rebind_protection" => true,
                    "query_timeout_ms" => 2000},
          "tls" => {"bypass" => ["pinned.example.com"], "verify_upstream" => false,
                    "intercepted_ports" => [443, 8443], "block_quic" => true,
                    "intercept_ca_cert" => "/ca.pem"},
          "ipv4_pool" => "10.0.0.0/24", "ipv6_pool" => "fd00::/64",
          "max_connections" => 128, "trust_host_cas" => true
        )
      )
    end

    it "normalizes the resource/limit scalar options" do
      Microsandbox::Sandbox.create(
        "box", image: "x", log_level: :debug, quiet_logs: true, security: "restricted",
        oci_upper_size: 2048, max_duration: 600, idle_timeout: 120,
        ports_udp: {"53" => 53}, rlimits: {nofile: 1024, cpu: [10, 20]}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "log_level" => "debug", "quiet_logs" => true, "security" => "restricted",
          "oci_upper_size" => 2048, "max_duration" => 600, "idle_timeout" => 120,
          "ports_udp" => {53 => 53},
          "rlimits" => [["nofile", 1024, 1024], ["cpu", 10, 20]]
        )
      )
    end

    it "raises when both image: and from_snapshot: are given" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", from_snapshot: "snap")
      end.to raise_error(ArgumentError, /either image: or from_snapshot:/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "accepts from_snapshot: on its own" do
      Microsandbox::Sandbox.create("box", from_snapshot: "snap")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("from_snapshot" => "snap")
      )
    end

    it "rejects a negative replace_with_timeout before any runtime round-trip" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", replace_with_timeout: -1)
      end.to raise_error(ArgumentError, /replace_with_timeout must be a finite, non-negative/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
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
      {"exit_code" => 0, "success" => true, "stdout" => "".b, "stderr" => "".b}
    end

    before { allow(native).to receive(:exec).and_return(exec_result) }

    it "passes command, args, and a normalized options hash" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      out = sb.exec("ls", ["-l", :foo], cwd: "/tmp", env: {A: 1}, timeout: 5, tty: true, stdin: "in")

      expect(native).to have_received(:exec).with(
        "ls", ["-l", "foo"],
        hash_including("cwd" => "/tmp", "env" => {"A" => "1"}, "timeout" => 5.0, "tty" => true, "stdin" => "in")
      )
      expect(out).to be_a(Microsandbox::ExecOutput)
    end

    it "rejects stdin: :pipe on blocking exec (there is no sink to write to)" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect { sb.exec("cat", stdin: :pipe) }.to raise_error(ArgumentError, /pipe/)
      expect(native).not_to have_received(:exec)
    end

    it "passes a stdin string as bytes, not a pipe" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.exec("cat", stdin: "data")

      expect(native).to have_received(:exec).with(
        "cat", [], hash_including("stdin" => "data")
      )
      expect(native).to have_received(:exec).with(
        "cat", [], hash_excluding("stdin_pipe")
      )
    end

    it "defaults args to an empty array" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.exec("whoami")
      expect(native).to have_received(:exec).with("whoami", [], {})
    end

    it "normalizes per-exec rlimits into [resource, soft, hard] triples" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.exec("ls", [], rlimits: {nofile: 256, as: [1000, 2000]})
      expect(native).to have_received(:exec).with(
        "ls", [], hash_including("rlimits" => [["nofile", 256, 256], ["as", 1000, 2000]])
      )
    end
  end

  describe "#shell option mapping" do
    before do
      allow(native).to receive(:shell).and_return(
        {"exit_code" => 0, "success" => true, "stdout" => "".b, "stderr" => "".b}
      )
    end

    it "passes the script and normalized options" do
      sb = Microsandbox::Sandbox.create("box", image: "x")
      sb.shell("echo hi", timeout: 2)
      expect(native).to have_received(:shell).with("echo hi", hash_including("timeout" => 2.0))
    end
  end

  describe "live lifecycle (#stop / #stop_and_wait / #kill / #drain / #wait / #status)" do
    subject(:sb) { Microsandbox::Sandbox.create("box", image: "x") }

    before do
      allow(native).to receive(:kill)
      allow(native).to receive(:drain)
      allow(native).to receive(:stop_and_wait).and_return("exit_code" => 0, "success" => true)
      allow(native).to receive(:wait).and_return("exit_code" => 137, "success" => false)
      allow(native).to receive(:status).and_return("running")
    end

    it "forwards the high-level lifecycle calls (no timeout args on the live handle)" do
      expect(sb.stop).to be_nil
      expect(sb.kill).to be_nil
      expect(sb.drain).to be_nil
      expect(native).to have_received(:stop).with(no_args)
      expect(native).to have_received(:kill).with(no_args)
      expect(native).to have_received(:drain).with(no_args)
    end

    it "wraps #stop_and_wait and #wait in an ExitStatus" do
      done = sb.stop_and_wait
      expect(done).to be_a(Microsandbox::ExitStatus)
      expect(done).to be_success
      expect(done.exit_code).to eq(0)

      killed = sb.wait
      expect(killed).to be_a(Microsandbox::ExitStatus)
      expect(killed).to be_failure
      expect(killed.exit_code).to eq(137)
    end

    it "exposes the live #status as a Symbol" do
      expect(sb.status).to eq(:running)
    end
  end

  describe "duration validation" do
    subject(:sb) { Microsandbox::Sandbox.create("box", image: "x") }

    before do
      allow(native).to receive(:exec).and_return(
        {"exit_code" => 0, "success" => true, "stdout" => "".b, "stderr" => "".b}
      )
      allow(native).to receive(:kill)
      allow(native).to receive(:metrics_stream)
    end

    # The native layer's Duration::from_secs_f64 panics on these; they must be
    # caught in Ruby as a clean ArgumentError, never reaching the binding.
    [-1, -0.5, Float::INFINITY, -Float::INFINITY, Float::NAN].each do |bad|
      it "rejects #{bad.inspect} as an exec timeout without calling the native layer" do
        expect { sb.exec("sleep", ["1"], timeout: bad) }
          .to raise_error(ArgumentError, /timeout must be a finite, non-negative/)
        expect(native).not_to have_received(:exec)
      end

      it "rejects #{bad.inspect} as a handle stop_with_timeout" do
        handle = Microsandbox::SandboxHandle.new(
          instance_double(Microsandbox::Native::SandboxHandle)
        )
        expect { handle.stop_with_timeout(bad) }
          .to raise_error(ArgumentError, /timeout must be a finite, non-negative/)
      end

      it "rejects #{bad.inspect} as a metrics_stream interval" do
        expect { sb.metrics_stream(interval: bad) }
          .to raise_error(ArgumentError, /interval must be a finite, non-negative/)
        expect(native).not_to have_received(:metrics_stream)
      end
    end

    # Valid durations (including 0 and integers) still flow through unchanged.
    it "accepts 0, integers, and positive floats" do
      sb.exec("true", [], timeout: 0)
      sb.exec("true", [], timeout: 5)
      sb.exec("true", [], timeout: 1.5)
      expect(native).to have_received(:exec).with("true", [], hash_including("timeout" => 0.0))
      expect(native).to have_received(:exec).with("true", [], hash_including("timeout" => 5.0))
      expect(native).to have_received(:exec).with("true", [], hash_including("timeout" => 1.5))
    end

    it "leaves a nil timeout absent (no coercion)" do
      sb.exec("true")
      expect(native).to have_received(:exec).with("true", [], hash_excluding("timeout"))
    end
  end

  describe "live owns_lifecycle? / detach" do
    subject(:sb) { Microsandbox::Sandbox.create("box", image: "x") }

    it "forwards detach, returning nil" do
      allow(native).to receive(:detach)
      expect(sb.detach).to be_nil
      expect(native).to have_received(:detach)
    end

    it "exposes owns_lifecycle? as a boolean predicate" do
      allow(native).to receive(:owns_lifecycle).and_return(true)
      expect(sb.owns_lifecycle?).to be(true)
    end
  end

  describe "SandboxHandle fine-grained lifecycle (from Sandbox.get/list)" do
    let(:native_handle) { instance_double(Microsandbox::Native::SandboxHandle) }
    subject(:handle) { Microsandbox::SandboxHandle.new(native_handle) }

    it "forwards request_stop/request_kill/request_drain, returning nil" do
      allow(native_handle).to receive(:request_stop)
      allow(native_handle).to receive(:request_kill)
      allow(native_handle).to receive(:request_drain)

      expect(handle.request_stop).to be_nil
      expect(handle.request_kill).to be_nil
      expect(handle.request_drain).to be_nil

      expect(native_handle).to have_received(:request_stop)
      expect(native_handle).to have_received(:request_kill)
      expect(native_handle).to have_received(:request_drain)
    end

    it "forwards stop_with_timeout/kill_with_timeout with coerced floats" do
      allow(native_handle).to receive(:stop_with_timeout)
      allow(native_handle).to receive(:kill_with_timeout)
      handle.stop_with_timeout(3)
      handle.kill_with_timeout(1.5)
      expect(native_handle).to have_received(:stop_with_timeout).with(3.0)
      expect(native_handle).to have_received(:kill_with_timeout).with(1.5)
    end

    it "wraps wait_until_stopped in a SandboxStopResult" do
      allow(native_handle).to receive(:wait_until_stopped).and_return(
        "name" => "box", "status" => "stopped", "exit_code" => 0,
        "signal" => nil, "observed_at_ms" => 1_700_000_000_000, "source" => "owned process handle"
      )
      result = handle.wait_until_stopped
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
        {"timestamp_ms" => 1_700_000_000_000, "source" => "stdout",
         "session_id" => 1, "cursor" => "abc", "data" => "hi".b},
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
      native_handle = instance_double(
        Microsandbox::Native::SandboxHandle, name: "box", status: "running"
      )
      allow(Microsandbox::Native::Sandbox).to receive(:list_with).and_return([native_handle])
      handles = Microsandbox::Sandbox.list_with(labels: {team: :core})
      expect(Microsandbox::Native::Sandbox).to have_received(:list_with).with(
        "labels" => {"team" => "core"}
      )
      expect(handles.first).to be_a(Microsandbox::SandboxHandle)
      expect(handles.first.name).to eq("box")
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
