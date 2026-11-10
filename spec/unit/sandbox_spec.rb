# frozen_string_literal: true

require "timeout"

# These specs exercise the pure-Ruby option normalization in Microsandbox::Sandbox
# WITHOUT booting a real microVM, by stubbing the native layer. The native
# binding itself is covered by the integration specs.
RSpec.describe Microsandbox::Sandbox do
  let(:native) {
    instance_double(Microsandbox::Native::Sandbox, name: "box", stop: nil, stop_with_timeout: nil, kill: nil,
      kill_with_timeout: nil)
  }

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
        network: :public, entrypoint: %w[/bin/sh -c]
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
          "network_profiles" => ["public"],
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

    it "passes through max_cpus / max_memory resource ceilings (v0.6.6)" do
      Microsandbox::Sandbox.create("box", image: "alpine", cpus: 1, max_cpus: 4,
        memory: 512, max_memory: 2048)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("cpus" => 1, "max_cpus" => 4, "memory" => 512, "max_memory" => 2048)
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

    it "maps pull_policy and normalizes a simple secret (a bare allow: host becomes a list)" do
      Microsandbox::Sandbox.create(
        "box", image: "x", pull_policy: "never",
        secrets: [{env: "OPENAI_API_KEY", value: "sk-123", allow: "api.openai.com"}]
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "pull_policy" => "never",
          "secrets" => [{"env" => "OPENAI_API_KEY", "value" => "sk-123",
                         "allow" => ["api.openai.com"]}]
        )
      )
    end

    it "normalizes the full secret surface (allow, placeholder hosts, TLS identity, violation, substitution)" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        secrets: [{
          env: "STRIPE_KEY", value: "sk_live", allow: ["api.stripe.com", "*.stripe.com"],
          allow_placeholder_for: ["10.0.0.1"], placeholder: "$STRIPE", require_tls_identity: true,
          violation_action: :block_and_terminate,
          substitution: {headers: true, header_fields: ["Authorization"], query: false, body: true}
        }],
        secret_violation_action: :block
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "secrets" => [{
            "env" => "STRIPE_KEY", "value" => "sk_live", "allow" => ["api.stripe.com", "*.stripe.com"],
            "allow_placeholder_for" => ["10.0.0.1"], "placeholder" => "$STRIPE",
            "require_tls_identity" => true, "violation_action" => "block_and_terminate",
            "substitution" => {"headers" => true, "header_fields" => ["Authorization"],
                               "query" => false, "body" => true}
          }],
          "secret_violation_action" => "block"
        )
      )
    end

    it "passes allow: [\"*\"] through (the native layer maps it to upstream's allow_any_host_dangerous)" do
      Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "K", value: "v", allow: ["*"]}])
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("secrets" => [{"env" => "K", "value" => "v", "allow" => ["*"]}])
      )
    end

    it "accepts the deprecated passthrough: alias with a warning, merged into allow_placeholder_for:" do
      expect do
        Microsandbox::Sandbox.create(
          "box", image: "x",
          secrets: [{env: "K", value: "v", allow: ["api.example.com"],
                     allow_placeholder_for: ["a.internal"], passthrough: ["b.internal", "a.internal"]}]
        )
      end.to output(/passthrough: is deprecated; use allow_placeholder_for:/).to_stderr
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("secrets" => [hash_including("allow_placeholder_for" => ["a.internal", "b.internal"])])
      )
    end

    {
      host: /:host was removed in 0\.18\.0.*use allow:/,
      hosts: /:hosts was removed.*use allow:/,
      host_patterns: /:host_patterns was removed.*use allow:/,
      inject_headers: /:inject_headers was removed.*substitution: \{ headers:/,
      inject_query: /:inject_query was removed.*substitution: \{ query:/,
      inject_body: /:inject_body was removed.*substitution: \{ body:/,
      inject_basic_auth: /:inject_basic_auth was removed.*header_fields: \["Authorization"\], query: false, body: false \}.*any scheme.*bare headers: true/,
      require_tls: /:require_tls was removed.*require_tls_identity:/,
      on_violation: /:on_violation was removed.*violation_action:.*allow_placeholder_for:/
    }.each do |key, message|
      it "rejects the removed secret key :#{key} with its replacement" do
        expect do
          Microsandbox::Sandbox.create("box", image: "x",
            secrets: [{env: "K", value: "sk_live_LEAK", allow: ["a.example"]}.merge(key => true)])
        end.to raise_error(ArgumentError, message) { |e| expect(e.message).not_to include("sk_live_LEAK") }
        expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
      end
    end

    it "rejects an unknown secret key and a key given as both Symbol and String" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "K", value: "v", allow: ["a"], hots: ["a"]}])
      end.to raise_error(ArgumentError, /unknown secret key\(s\) :hots/)
      both = {env: "K", value: "v", allow: ["a"]}.merge("env" => "K")
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [both])
      end.to raise_error(ArgumentError, /both a Symbol and a String/)
    end

    it "validates substitution: (unknown keys, header_fields without headers, nothing enabled)" do
      base = {env: "K", value: "v", allow: ["a.example"]}
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [base.merge(substitution: {cookies: true})])
      end.to raise_error(ArgumentError, /unknown substitution key\(s\) :cookies/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x",
          secrets: [base.merge(substitution: {headers: false, header_fields: ["X-Key"], body: true})])
      end.to raise_error(ArgumentError, /header_fields: requires headers substitution/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [base.merge(substitution: {headers: false})])
      end.to raise_error(ArgumentError, /at least one of headers, query, or body/)
    end

    it "raises on a secret spec missing env/value" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "X"}])
      end.to raise_error(ArgumentError, /:env and :value/)
    end

    it "never embeds the cleartext secret value in the env/value error" do
      # env missing but value present: the :env-and-:value guard fires while a
      # value is in hand — the message must report keys only, not the secret.
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{value: "sk_live_LEAK"}])
      end.to raise_error(ArgumentError) { |e|
        expect(e.message).to match(/:env and :value/)
        expect(e.message).not_to include("sk_live_LEAK")
      }
    end

    it "raises on a secret spec with no allowed host (an empty allow: too)" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "X", value: "y"}])
      end.to raise_error(ArgumentError, /needs a non-empty allow:/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "X", value: "y", allow: []}])
      end.to raise_error(ArgumentError, /needs a non-empty allow:/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "X", value: "y", allow: [""]}])
      end.to raise_error(ArgumentError, /entries must be non-empty host names/)
    end

    it "never embeds the cleartext secret value in the host error" do
      # The host guard runs only after :value is confirmed present, so a naive
      # spec.inspect would always leak the live credential into the message.
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secrets: [{env: "X", value: "sk_live_LEAK"}])
      end.to raise_error(ArgumentError) { |e|
        expect(e.message).to match(/needs a non-empty allow:/)
        expect(e.message).not_to include("sk_live_LEAK")
      }
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
        secrets: [{env: "K", value: "v", allow: ["api.example.com"],
                   violation_action: "block-and-terminate"}],
        secret_violation_action: "block-and-log"
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "secrets" => [hash_including("violation_action" => "block_and_terminate")],
          "secret_violation_action" => "block_and_log"
        )
      )
    end

    it "rejects the passthrough violation action, pointing at allow_placeholder_for: (runtime v0.7)" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secret_violation_action: "passthrough")
      end.to raise_error(ArgumentError, /:passthrough was removed in 0\.18\.0.*allow_placeholder_for:/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x",
          secrets: [{env: "K", value: "v", allow: ["a"], violation_action: :passthrough}])
      end.to raise_error(ArgumentError, /:passthrough was removed/)
    end

    it "raises on an unknown violation action string, and on a non-String/Symbol one" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secret_violation_action: "nope")
      end.to raise_error(ArgumentError, /unknown secret_violation_action "nope"/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", secret_violation_action: {passthrough_hosts: ["a"]})
      end.to raise_error(ArgumentError, /secret_violation_action: must be a String or Symbol/)
    end

    it "rejects the removed on_secret_violation: keyword with directions" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", on_secret_violation: "block")
      end.to raise_error(ArgumentError, /on_secret_violation: was removed in 0\.18\.0.*secret_violation_action:/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
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

    it "normalizes dns/tls/pools/connection caps/trust_host_cas" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        dns: {nameservers: ["1.1.1.1"], rebind_protection: true, query_timeout_ms: 2000},
        tls: {bypass: ["pinned.example.com"], verify_upstream: false,
              intercepted_ports: [443, 8443], block_quic: true, intercept_ca_cert: "/ca.pem"},
        ipv4_pool: "10.0.0.0/24", ipv6_pool: "fd00::/64",
        max_tcp_connections: 128, max_udp_connections: 64, trust_host_cas: true
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
          "max_tcp_connections" => 128, "max_udp_connections" => 64, "trust_host_cas" => true
        )
      )
    end

    describe "http: deny response (runtime v0.7)" do
      def native_http
        opts = nil
        expect(Microsandbox::Native::Sandbox).to have_received(:create).with("box", satisfy { |o| opts = o })
        opts["http"]
      end

      it "normalizes every key (String format, case-insensitive)" do
        Microsandbox::Sandbox.create("box", image: "x",
          http: {deny_response: true, format: "JSON", network_message: "no", secret_message: ""})
        expect(native_http).to eq("deny_response" => true, "format" => "json",
          "network_message" => "no", "secret_message" => "")
      end

      it "accepts String keys" do
        Microsandbox::Sandbox.create("box", image: "x", http: {"format" => :json, "network_message" => "no"})
        expect(native_http).to eq("format" => "json", "network_message" => "no")
      end

      it "accepts format: :text and deny_response: false on their own" do
        Microsandbox::Sandbox.create("box", image: "x", http: {format: :text})
        expect(native_http).to eq("format" => "text")
      end

      it "leaves nil keys out" do
        Microsandbox::Sandbox.create("box", image: "x", http: {deny_response: false, format: nil})
        expect(native_http).to eq("deny_response" => false)
      end

      {
        "a non-Hash" => [:json, /http: must be a Hash/],
        "an unknown key (no aliases)" => [{deny_response_format: :json}, /unknown http: key\(s\) deny_response_format/],
        "a non-boolean deny_response" => [{deny_response: "yes"}, /deny_response: must be true or false/],
        "an unknown format" => [{format: :xml}, /format: must be :json or :text/],
        "a non-String message" => [{network_message: :blocked}, /network_message: must be a String/],
        "a message with the text format" => [{format: :text, network_message: "x"}, /network_message: needs the JSON format/],
        "a message with deny_response: false" => [{deny_response: false, secret_message: "x"}, /secret_message: has no effect/]
      }.each do |label, (value, message)|
        it "rejects #{label} before any native call" do
          expect { Microsandbox::Sandbox.create("box", image: "x", http: value) }.to raise_error(ArgumentError, message)
          expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
        end
      end
    end

    describe "connection caps (runtime v0.7)" do
      it "maps the deprecated max_connections: onto the TCP cap, with a warning" do
        allow(Microsandbox::Sandbox).to receive(:warn)
        Microsandbox::Sandbox.create("box", image: "x", max_connections: 7)
        expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
          "box", satisfy { |opts| opts["max_tcp_connections"] == 7 && !opts.key?("max_connections") }
        )
        expect(Microsandbox::Sandbox).to have_received(:warn)
          .with(/max_connections: is deprecated; use max_tcp_connections:/, uplevel: 3)
      end

      it "refuses max_connections: together with max_tcp_connections:" do
        expect {
          Microsandbox::Sandbox.create("box", image: "x", max_connections: 7, max_tcp_connections: 8)
        }.to raise_error(ArgumentError, /mutually exclusive/)
        expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
      end

      it "passes 0 (unlimited) through and leaves nil unset" do
        Microsandbox::Sandbox.create("box", image: "x", max_tcp_connections: 0)
        expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
          "box", satisfy { |opts| opts["max_tcp_connections"] == 0 && !opts.key?("max_udp_connections") }
        )
      end

      it "rejects a negative or non-integer cap before any native call" do
        expect { Microsandbox::Sandbox.create("box", image: "x", max_udp_connections: -1) }
          .to raise_error(ArgumentError, /max_udp_connections: must be >= 0/)
        expect { Microsandbox::Sandbox.create("box", image: "x", max_tcp_connections: "many") }
          .to raise_error(ArgumentError)
        expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
      end
    end

    it "normalizes the resource/limit scalar options" do
      Microsandbox::Sandbox.create(
        "box", image: "x", log_level: :debug, quiet_logs: true, security: "restricted",
        root_disk: 2048, max_duration: 600, idle_timeout: 120,
        ports_udp: {"53" => 53}, rlimits: {nofile: 1024, cpu: [10, 20]}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including(
          "log_level" => "debug", "quiet_logs" => true, "security" => "restricted",
          "root_disk" => 2048, "max_duration" => 600, "idle_timeout" => 120,
          "ports_udp" => {53 => 53},
          "rlimits" => [["nofile", 1024, 1024], ["cpu", 10, 20]]
        )
      )
    end

    it "maps the deprecated oci_upper_size: alias to a managed root_disk (with a warning)" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", oci_upper_size: 4096)
      end.to output(/oci_upper_size: is deprecated/).to_stderr
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("root_disk" => 4096)
      )
    end

    it "rejects passing both root_disk: and oci_upper_size:" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", root_disk: 1024, oci_upper_size: 2048)
      end.to raise_error(ArgumentError, /either root_disk: or oci_upper_size:/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "normalizes RootDisk factory hashes and validates kind/field combinations" do
      Microsandbox::Sandbox.create("box", image: "x", root_disk: Microsandbox::RootDisk.tmpfs(512))
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("root_disk" => {"kind" => "tmpfs", "size_mib" => 512})
      )

      Microsandbox::Sandbox.create(
        "box2", image: "x",
        root_disk: Microsandbox::RootDisk.disk("./scratch.img", format: :raw, fstype: "ext4")
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box2",
        hash_including("root_disk" => {
          "kind" => "disk", "path" => "./scratch.img", "format" => "raw", "fstype" => "ext4"
        })
      )

      expect do
        Microsandbox::Sandbox.create("box3", image: "x", root_disk: {kind: :tmpfs, path: "/x"})
      end.to raise_error(ArgumentError, /only valid for the disk kind/)
      expect do
        Microsandbox::Sandbox.create("box4", image: "x", root_disk: {kind: :disk})
      end.to raise_error(ArgumentError, /requires path:/)
      expect do
        Microsandbox::Sandbox.create("box5", image: "x", root_disk: {kind: :disk, path: "/i.img", size_mib: 8})
      end.to raise_error(ArgumentError, /image file determines the size/)
      expect do
        Microsandbox::Sandbox.create("box6", image: "x", root_disk: {kind: :floppy})
      end.to raise_error(ArgumentError, /unknown root_disk kind/)
    end

    it "normalizes a flat root disk with clone strategy (v0.6.9)" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        root_disk: Microsandbox::RootDisk.flat(8192, fstype: "ext4", clone: :reflink)
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("root_disk" => {
          "kind" => "flat", "size_mib" => 8192, "fstype" => "ext4", "clone" => "reflink"
        })
      )

      expect do
        Microsandbox::Sandbox.create("box2", image: "x", root_disk: {kind: :flat, path: "/x"})
      end.to raise_error(ArgumentError, /only valid for the disk kind/)
      expect do
        Microsandbox::Sandbox.create("box3", image: "x", root_disk: {kind: :flat, clone: :cow})
      end.to raise_error(ArgumentError, /unknown root_disk clone strategy/)
    end

    it "forwards cmd:, distinguishing an explicit empty array from absence (v0.6.9)" do
      Microsandbox::Sandbox.create("box", image: "x", cmd: ["worker.py", :"--once"])
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("cmd" => ["worker.py", "--once"])
      )

      Microsandbox::Sandbox.create("box2", image: "x", cmd: [])
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box2", hash_including("cmd" => [])
      )

      Microsandbox::Sandbox.create("box3", image: "x")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box3", hash_excluding("cmd")
      )
    end

    it "forwards entrypoint: [] (clears the image ENTRYPOINT) distinctly from absence" do
      Microsandbox::Sandbox.create("box", image: "x", entrypoint: [])
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("entrypoint" => [])
      )

      Microsandbox::Sandbox.create("box2", image: "x")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box2", hash_excluding("entrypoint")
      )
    end

    it "normalizes vsock routes from both accepted shapes (v0.6.9)" do
      Microsandbox::Sandbox.create("box", image: "x", vsock: {"/host/api.sock" => 5000})
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("vsock" => [{"host_socket" => "/host/api.sock", "port" => 5000}])
      )

      Microsandbox::Sandbox.create(
        "box2", image: "x",
        vsock: [{host_socket: "/h/log.sock", port: 6000, socket_type: :dgram}]
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box2",
        hash_including("vsock" => [
          {"host_socket" => "/h/log.sock", "port" => 6000, "socket_type" => "dgram"}
        ])
      )

      expect do
        Microsandbox::Sandbox.create("box3", image: "x", vsock: [{port: 1}])
      end.to raise_error(ArgumentError, /requires host_socket: and port:/)
      expect do
        Microsandbox::Sandbox.create("box4", image: "x", vsock: "nope")
      end.to raise_error(ArgumentError, /vsock: must be a Hash/)
    end

    it "normalizes rate_limiter token buckets (v0.6.9)" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        rate_limiter: {
          egress: {
            bandwidth: {size: 1_048_576, refill_time_ms: 1000, one_time_burst: 2048},
            ops: {size: 1000, refill_time_ms: 1000}
          },
          ingress: {bandwidth: {size: 524_288, refill_time_ms: 500}}
        }
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("rate_limiter" => {
          "egress" => {
            "bandwidth" => {"size" => 1_048_576, "refill_time_ms" => 1000, "one_time_burst" => 2048},
            "ops" => {"size" => 1000, "refill_time_ms" => 1000}
          },
          "ingress" => {"bandwidth" => {"size" => 524_288, "refill_time_ms" => 500}}
        })
      )

      expect do
        Microsandbox::Sandbox.create("box2", image: "x", rate_limiter: {egress: {bandwidth: {size: 1}}})
      end.to raise_error(ArgumentError, /requires size: and refill_time_ms:/)
      expect do
        Microsandbox::Sandbox.create("box3", image: "x", rate_limiter: "fast")
      end.to raise_error(ArgumentError, /rate_limiter: must be a Hash/)
    end

    it "sends strict: true and an explicit strict: false, and omits it when nil (v0.6.18)" do
      Microsandbox::Sandbox.create("box", image: "x", strict: true)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box", hash_including("strict" => true)
      )

      # An explicit false must still travel (set_bool probes presence, not
      # truthiness) so a caller can pin the default off against a config overlay.
      Microsandbox::Sandbox.create("box2", image: "x", strict: false)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box2", hash_including("strict" => false)
      )

      Microsandbox::Sandbox.create("box3", image: "x")
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box3", hash_not_including("strict")
      )
    end

    # strict: is applied inside the ext's advanced-network block, which is only
    # entered when at least one of its options is set. Pin the case where strict
    # is the ONLY such option so a guard that forgot `strict.is_some()` would at
    # least be visible at the normalization layer: no sibling network key rides
    # along to open that block.
    it "sends strict: on its own, with no other advanced network option" do
      Microsandbox::Sandbox.create("box", image: "x", strict: true)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        satisfy { |opts|
          opts["strict"] == true &&
            (opts.keys & %w[dns tls ipv4_pool ipv6_pool max_tcp_connections max_udp_connections trust_host_cas]).empty?
        }
      )
    end

    it "normalizes proxy: (v0.6.17) from a value object or a Hash, and omits it when nil" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        proxy: Microsandbox::OutboundProxy.socks5("127.0.0.1:1080")
          .credentials("sandbox", Microsandbox::SecretSource.env("PROXY_PASSWORD"))
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("proxy" => {
          "protocol" => "socks5", "address" => "127.0.0.1:1080",
          "credentials" => {
            "username" => "sandbox",
            "password" => {"kind" => "env", "var" => "PROXY_PASSWORD"}
          }
        })
      )

      Microsandbox::Sandbox.create(
        "box2", image: "x", proxy: {protocol: :socks4, address: "127.0.0.1:1080", user_id: "ci"}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box2",
        hash_including("proxy" => {"protocol" => "socks4", "address" => "127.0.0.1:1080", "user_id" => "ci"})
      )

      Microsandbox::Sandbox.create("box3", image: "x", proxy: nil)
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box3", hash_not_including("proxy")
      )

      expect do
        Microsandbox::Sandbox.create("box4", image: "x", proxy: "socks5://127.0.0.1:1080")
      end.to raise_error(ArgumentError, /proxy: expects a Microsandbox::OutboundProxy/)
    end

    it "passes proxy: through connect_or_create (same kwargs path as create)" do
      allow(Microsandbox::Native::Sandbox).to receive(:connect_or_create).and_return(native)
      Microsandbox::Sandbox.connect_or_create(
        "box", image: "x", proxy: Microsandbox::OutboundProxy.socks4("127.0.0.1:1080")
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:connect_or_create).with(
        "box", hash_including("proxy" => {"protocol" => "socks4", "address" => "127.0.0.1:1080"})
      )
    end

    it "rejects out-of-u32-range root_disk sizes with a clear error" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", root_disk: -1)
      end.to raise_error(ArgumentError, /positive size in MiB.*got -1/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", root_disk: 2**40)
      end.to raise_error(ArgumentError, /fits in 32 bits/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", root_disk: {kind: :tmpfs, size_mib: -5})
      end.to raise_error(ArgumentError, /root_disk size_mib:.*got -5/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "rejects follow_root_symlinks: on tmpfs/disk mounts (no host root to protect)" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        volumes: {"/data" => {bind: "/host", follow_root_symlinks: true}}
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("volumes" => [hash_including("follow_root_symlinks" => true)])
      )

      expect do
        Microsandbox::Sandbox.create(
          "box2", image: "x",
          volumes: {"/scratch" => {tmpfs: true, follow_root_symlinks: true}}
        )
      end.to raise_error(ArgumentError, /follow_root_symlinks: only applies to bind\/named/)
    end

    it "forwards a bind/named mount owner as override_uid/override_gid (runtime v0.6.15)" do
      Microsandbox::Sandbox.create(
        "box", image: "x",
        volumes: {
          "/data" => {bind: "/host", uid: 1000, gid: 1000},
          "/vol" => {named: "shared", uid: 0, gid: 0, stat_virtualization: :relaxed}
        }
      )
      expect(Microsandbox::Native::Sandbox).to have_received(:create).with(
        "box",
        hash_including("volumes" => [
          {"guest" => "/data", "kind" => "bind", "source" => "/host",
           "override_uid" => 1000, "override_gid" => 1000},
          {"guest" => "/vol", "kind" => "named", "source" => "shared",
           "stat_virtualization" => "relaxed", "override_uid" => 0, "override_gid" => 0}
        ])
      )
    end

    it "requires uid: and gid: to be set together" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x", volumes: {"/data" => {bind: "/host", uid: 1000}})
      end.to raise_error(ArgumentError, /uid: and gid: must be set together/)
      expect do
        Microsandbox::Sandbox.create("box", image: "x", volumes: {"/data" => {bind: "/host", gid: 1000}})
      end.to raise_error(ArgumentError, /uid: and gid: must be set together/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "rejects non-Integer and out-of-u32-range mount owner IDs" do
      [["1000", 1000], [1000.0, 1000], [true, false], [-1, 0], [0, 2**32]].each do |uid, gid|
        expect do
          Microsandbox::Sandbox.create(
            "box", image: "x", volumes: {"/data" => {bind: "/host", uid: uid, gid: gid}}
          )
        end.to raise_error(ArgumentError, /must be an Integer between 0 and 4294967295/)
      end
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "rejects a mount owner combined with stat_virtualization: :off" do
      expect do
        Microsandbox::Sandbox.create(
          "box", image: "x",
          volumes: {"/data" => {bind: "/host", uid: 1000, gid: 1000, stat_virtualization: :off}}
        )
      end.to raise_error(ArgumentError, /cannot be combined with stat_virtualization: :off/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "rejects a mount owner on tmpfs/disk mounts" do
      expect do
        Microsandbox::Sandbox.create(
          "box", image: "x", volumes: {"/scratch" => {tmpfs: true, uid: 1000, gid: 1000}}
        )
      end.to raise_error(ArgumentError, %r{uid:/gid: \(mount owner\) only applies to bind/named})
      expect do
        Microsandbox::Sandbox.create(
          "box", image: "x", volumes: {"/disk" => {disk: "/img.raw", uid: 1000, gid: 1000}}
        )
      end.to raise_error(ArgumentError, %r{uid:/gid: \(mount owner\) only applies to bind/named})
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "rejects the removed from_snapshot: keyword with directions (alone or with image:)" do
      [{from_snapshot: "snap"}, {image: "x", from_snapshot: "snap"}].each do |kwargs|
        expect do
          Microsandbox::Sandbox.create("box", **kwargs)
        end.to raise_error(ArgumentError, /from_snapshot: was removed in 0\.18\.0.*Sandbox\.restore/)
      end
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
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
      expect(native).to have_received(:stop_with_timeout).with(10.0)
      expect(native).not_to have_received(:kill)
      expect(native).not_to have_received(:kill_with_timeout)
    end

    it "stops the sandbox even if the block raises" do
      expect do
        Microsandbox::Sandbox.create("box", image: "x") { raise "boom" }
      end.to raise_error("boom")
      expect(native).to have_received(:stop_with_timeout).with(10.0)
    end

    # Runtime v0.7: a graceful stop never escalates, so the block form bounds
    # it and kills on expiry rather than hanging on the way out. The kill has
    # its own end-to-end budget: a plain #kill waits for the transition lock
    # without a deadline.
    it "kills the sandbox with a bounded kill when the bounded stop times out on block exit" do
      allow(native).to receive(:stop_with_timeout).and_raise(Microsandbox::StopTimeoutError, "timed out")
      expect { expect(Microsandbox::Sandbox.create("box", image: "x") { :done }).to eq(:done) }
        .not_to output.to_stderr
      expect(native).to have_received(:kill_with_timeout).with(15.0)
      expect(native).not_to have_received(:kill)
    end

    it "uses BLOCK_STOP_TIMEOUT as the block-form budget" do
      stub_const("Microsandbox::Sandbox::BLOCK_STOP_TIMEOUT", 3)
      Microsandbox::Sandbox.create("box", image: "x") { :done }
      expect(native).to have_received(:stop_with_timeout).with(3.0)
    end

    it "warns about a failing kill after a timed-out stop and keeps the block's exception" do
      allow(native).to receive(:stop_with_timeout).and_raise(Microsandbox::StopTimeoutError, "timed out")
      allow(native).to receive(:kill_with_timeout).and_raise(Microsandbox::Error, "kill timed out")
      expect do
        expect { Microsandbox::Sandbox.create("box", image: "x") { raise IOError, "boom" } }
          .to raise_error(IOError, "boom")
      end.to output(/cleanup gave up on sandbox "box", which may still be running.*kill timed out/).to_stderr
    end

    it "still warns when the sandbox's name cannot be read" do
      allow(native).to receive(:stop_with_timeout).and_raise(Microsandbox::StopTimeoutError, "timed out")
      allow(native).to receive(:kill_with_timeout).and_raise(Microsandbox::Error, "kill timed out")
      allow(native).to receive(:name).and_raise(Microsandbox::ForkedHandleError, "forked")
      expect do
        expect { Microsandbox::Sandbox.create("box", image: "x") { raise IOError, "boom" } }
          .to raise_error(IOError, "boom")
      end.to output(/cleanup gave up on sandbox "<unknown: Microsandbox::ForkedHandleError>"/).to_stderr
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

    # Runtime v0.7: the live sandbox's bounded variants (the plain #stop waits
    # forever and never escalates).
    it "forwards #stop_with_timeout / #kill_with_timeout as seconds, rejecting bad budgets" do
      allow(native).to receive(:kill_with_timeout)
      expect(sb.stop_with_timeout(2)).to be_nil
      expect(sb.kill_with_timeout(0.5)).to be_nil
      expect(native).to have_received(:stop_with_timeout).with(2.0)
      expect(native).to have_received(:kill_with_timeout).with(0.5)
      [-1, Float::NAN, Float::INFINITY].each do |bad|
        expect { sb.stop_with_timeout(bad) }.to raise_error(ArgumentError, /timeout must be a finite, non-negative/)
        expect { sb.kill_with_timeout(bad) }.to raise_error(ArgumentError, /timeout must be a finite, non-negative/)
      end
    end

    it "lets StopTimeoutError from #stop_with_timeout surface (nothing is killed)" do
      allow(native).to receive(:stop_with_timeout).and_raise(Microsandbox::StopTimeoutError, "timed out")
      expect { sb.stop_with_timeout(1) }.to raise_error(Microsandbox::StopTimeoutError)
      expect(native).not_to have_received(:kill)
    end

    # The binding routes the live #stop through the sandbox object itself (not a
    # by-name handle refetch), so the core scopes it to this sandbox's identity
    # and refuses a same-name replacement. The Ruby layer must let that surface,
    # not swallow or rewrap it.
    it "propagates SandboxReplacedError from a stop aimed at a replaced name" do
      allow(native).to receive(:stop).and_raise(Microsandbox::SandboxReplacedError, "replaced")
      expect { sb.stop }.to raise_error(Microsandbox::SandboxReplacedError)
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

  # Sandbox.restore (runtime v0.7): stub-level; the real restores run in
  # spec/integration/snapshot_spec.rb.
  describe ".restore" do
    before { allow(Microsandbox::Native::Sandbox).to receive(:restore).and_return(native) }

    def restored_with
      captured = nil
      expect(Microsandbox::Native::Sandbox).to have_received(:restore) { |ref, opts| captured = [ref, opts] }
      captured
    end

    it "maps the destination options and reads a String selector as auto" do
      sb = Microsandbox::Sandbox.restore("snap_123", name: :child, cpus: 2, memory: 768, user: "app",
        log_level: :debug, max_duration: 60, idle_timeout: 30, volumes: {"/data" => "/host/data"},
        ports: {"8080" => "80"}, disable_network: true, cow_memory: true, disk_only: true,
        snapshot_base: "base", allow_missing_resources: true, external_mount_policy: :relaxed)
      expect(sb).to be_a(Microsandbox::Sandbox)
      ref, opts = restored_with
      expect(ref).to eq("snap_123")
      expect(opts).to eq(
        "snapshot_kind" => "auto", "name" => "child", "cpus" => 2, "memory" => 768, "user" => "app",
        "log_level" => "debug", "max_duration" => 60, "idle_timeout" => 30,
        "volumes" => [{"guest" => "/data", "kind" => "bind", "source" => "/host/data"}],
        "ports" => {8080 => 80}, "disable_network" => true, "cow_memory" => true, "disk_only" => true,
        "snapshot_base" => "base", "allow_missing_resources" => true, "external_mount_policy" => "relaxed"
      )
      expect(Microsandbox).to have_received(:ensure_runtime!)
    end

    it "sends only name: and the kind when nothing else is given" do
      Microsandbox::Sandbox.restore("src:snap", name: "child")
      expect(restored_with).to eq(["src:snap", {"name" => "child", "snapshot_kind" => "auto"}])
    end

    it "restores a SnapshotInfo by its reference and kind, falling back to path, id, then digest" do
      {
        {"reference" => "/snaps/a", "reference_kind" => "path", "path" => "/snaps/a", "id" => "snap_1"} => ["/snaps/a", "path"],
        {"path" => "/snaps/b", "id" => "snap_2", "digest" => "sha256:b"} => ["/snaps/b", "path"],
        {"id" => "snap_3", "digest" => "sha256:c"} => ["snap_3", "id"],
        {"digest" => "sha256:d"} => ["sha256:d", "auto"]
      }.each do |data, (ref, kind)|
        RSpec::Mocks.space.proxy_for(Microsandbox::Native::Sandbox).reset
        allow(Microsandbox::Native::Sandbox).to receive(:restore).and_return(native)
        Microsandbox::Sandbox.restore(Microsandbox::SnapshotInfo.new(data), name: "child")
        got_ref, opts = restored_with
        expect([got_ref, opts["snapshot_kind"]]).to eq([ref, kind])
      end
    end

    it "reads a Pathname as a path" do
      Microsandbox::Sandbox.restore(Pathname("snaps/x"), name: "child")
      expect(restored_with.last).to include("snapshot_kind" => "path")
      expect(restored_with.first).to eq("snaps/x")
    end

    it "warns on the deprecated forked: and maps it to cow_memory" do
      expect { Microsandbox::Sandbox.restore("s", name: "child", forked: true) }
        .to output(/restore\(forked:\) is deprecated; use cow_memory:/).to_stderr
      expect(restored_with.last).to include("cow_memory" => true)
    end

    it "rejects what restore cannot change, before provisioning the runtime" do
      [
        [{network: :none}, /unknown keyword: :network/],
        [{security: :restricted}, /unknown keyword: :security/],
        [{vsock: {"/s" => 1}}, /unknown keyword: :vsock/],
        [{max_tcp_connections: 1}, /unknown keyword: :max_tcp_connections/],
        [{image: "alpine"}, /unknown keyword: :image/],
        [{external_mount_policy: :loose}, /external_mount_policy: must be :strict or :relaxed/]
      ].each do |kwargs, message|
        expect { Microsandbox::Sandbox.restore("s", name: "child", **kwargs) }.to raise_error(ArgumentError, message)
      end
      expect { Microsandbox::Sandbox.restore("s") }.to raise_error(ArgumentError, /missing keyword: :name/)
      expect { Microsandbox::Sandbox.restore(42, name: "child") }.to raise_error(ArgumentError, /snapshot must be/)
      expect(Microsandbox).not_to have_received(:ensure_runtime!)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:restore)
    end

    it "stops the restored sandbox after the block, though upstream starts it detached" do
      allow(native).to receive(:owns_lifecycle).and_return(false)
      expect(Microsandbox::Sandbox.restore("s", name: "child") { |sb| sb.name }).to eq("box")
      expect(native).to have_received(:stop_with_timeout).with(10.0)
    end

    it "stops the unowned restored sandbox when the caller never gets it" do
      allow(native).to receive(:owns_lifecycle).and_return(false)
      allow(Microsandbox::Sandbox).to receive(:new).and_raise(IOError, "lost")
      expect { Microsandbox::Sandbox.restore("s", name: "child") }.to raise_error(IOError, "lost")
      expect(native).to have_received(:stop_with_timeout).with(10.0)
    end
  end

  # The acquisition entry points mask interrupts around the native call (so an
  # interrupted call's sandbox can be stopped), and a mask makes whatever runs
  # under it uninterruptible. It must therefore cover the native call only:
  # converting the caller's arguments is the caller's code and has to stay
  # interruptible. A name whose #to_s blocks stands in for that code.
  describe "interruptibility before the native call" do
    let(:slow_name) do
      Class.new(String) do
        def to_s
          sleep 0.4
          super
        end
      end.new("box")
    end

    {create: {image: "python"}, connect_or_create: {image: "python"}, start: {}, restore: {name: "r"}}.each do |entry, kwargs|
      it ".#{entry} can be timed out while its arguments are prepared, before any native call" do
        allow(Microsandbox::Native::Sandbox).to receive(entry).and_return(native)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect {
          Timeout.timeout(0.05) { Microsandbox::Sandbox.public_send(entry, slow_name, **kwargs) }
        }.to raise_error(Timeout::Error)
        # Well short of the 0.4s the conversion takes when it cannot be interrupted.
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 0.3
        expect(Microsandbox::Native::Sandbox).not_to have_received(entry)
      end
    end
  end

  # Convergent lifecycle APIs (runtime v0.6.16, upstream #1462). Stub-level:
  # the real convergence behaviour is covered by spec/integration.
  describe "convergent lifecycle (.connect_or_create / #id / #wait_for_status / #restart / #destroy)" do
    before { allow(Microsandbox::Native::Sandbox).to receive(:connect_or_create).and_return(native) }

    it "routes .connect_or_create through the shared create option builder" do
      sb = Microsandbox::Sandbox.connect_or_create(
        "box", image: "python", cpus: 2, volumes: {"/data" => "/host/data"}
      )
      expect(sb).to be_a(Microsandbox::Sandbox)
      expect(Microsandbox::Native::Sandbox).to have_received(:connect_or_create).with(
        "box",
        hash_including(
          "image" => "python", "cpus" => 2,
          "volumes" => [{"guest" => "/data", "kind" => "bind", "source" => "/host/data"}]
        )
      )
      expect(Microsandbox::Native::Sandbox).not_to have_received(:create)
    end

    it "validates .connect_or_create kwargs exactly like .create" do
      expect do
        Microsandbox::Sandbox.connect_or_create("box", image: "x", from_snapshot: "snap")
      end.to raise_error(ArgumentError, /from_snapshot: was removed in 0\.18\.0/)
      expect(Microsandbox::Native::Sandbox).not_to have_received(:connect_or_create)
    end

    # The block form stops only what this call owns. `owns_lifecycle` is the
    # core's "we hold the child process handle" predicate: true for an attached
    # create, false both for a sandbox that was already running (connected to)
    # and for one started detached.
    it "stops the sandbox after the .connect_or_create block form when it owns the lifecycle" do
      allow(native).to receive(:owns_lifecycle).and_return(true)
      yielded = nil
      Microsandbox::Sandbox.connect_or_create("box", image: "x") { |sb| yielded = sb }
      expect(yielded).to be_a(Microsandbox::Sandbox)
      expect(native).to have_received(:stop_with_timeout).with(10.0)
    end

    it "leaves a merely-connected sandbox running after the .connect_or_create block form" do
      allow(native).to receive(:owns_lifecycle).and_return(false)
      Microsandbox::Sandbox.connect_or_create("box", image: "x") { |sb| sb.name }
      expect(native).not_to have_received(:stop_with_timeout)
      expect(native).not_to have_received(:kill)
      expect(native).not_to have_received(:kill_with_timeout)
    end

    it "leaves a detached sandbox running after the .connect_or_create block form" do
      allow(native).to receive(:owns_lifecycle).and_return(false)
      Microsandbox::Sandbox.connect_or_create("box", image: "x", detached: true) { |sb| sb.name }
      expect(Microsandbox::Native::Sandbox).to have_received(:connect_or_create).with(
        "box", hash_including("detached" => true)
      )
      expect(native).not_to have_received(:stop_with_timeout)
    end

    it "still returns the block's value and swallows a teardown stop failure" do
      allow(native).to receive(:owns_lifecycle).and_return(true)
      allow(native).to receive(:stop_with_timeout).and_raise(Microsandbox::SandboxNotRunningError, "gone")
      result = Microsandbox::Sandbox.connect_or_create("box", image: "x") { :block_value }
      expect(result).to eq(:block_value)
    end

    # The live #stop is identity-scoped in the core (v0.6.16), so a name that was
    # removed and recreated while the block ran makes the teardown raise instead
    # of stopping the replacement. The ensure must swallow that like any other
    # best-effort teardown failure — the block's value still comes back.
    it "swallows SandboxReplacedError from the block-form teardown" do
      allow(native).to receive(:owns_lifecycle).and_return(true)
      allow(native).to receive(:stop_with_timeout).and_raise(Microsandbox::SandboxReplacedError, "replaced")
      result = Microsandbox::Sandbox.connect_or_create("box", image: "x") { :block_value }
      expect(result).to eq(:block_value)
      expect(native).to have_received(:stop_with_timeout)
      expect(native).not_to have_received(:kill)
      expect(native).not_to have_received(:kill_with_timeout)
    end

    it "exposes the sandbox identity as #id" do
      allow(native).to receive(:id).and_return("local:42")
      expect(Microsandbox::Sandbox.create("box", image: "x").id).to eq("local:42")
    end

    it "wraps #wait_for_status in a SandboxHandle and lowers the status name" do
      native_handle = instance_double(Microsandbox::Native::SandboxHandle)
      allow(native).to receive(:wait_for_status).and_return(native_handle)
      sb = Microsandbox::Sandbox.create("box", image: "x")

      expect(sb.wait_for_status(:running)).to be_a(Microsandbox::SandboxHandle)
      expect(sb.wait_for_status("stopped")).to be_a(Microsandbox::SandboxHandle)
      expect(native).to have_received(:wait_for_status).with("running")
      expect(native).to have_received(:wait_for_status).with("stopped")
    end

    it "rejects an unknown #wait_for_status target without a native call" do
      allow(native).to receive(:wait_for_status)
      sb = Microsandbox::Sandbox.create("box", image: "x")
      expect { sb.wait_for_status(:runnning) }
        .to raise_error(ArgumentError, /unknown sandbox status :runnning.*created, starting, running/m)
      expect { sb.wait_for_status(nil) }.to raise_error(ArgumentError, /unknown sandbox status/)
      expect(native).not_to have_received(:wait_for_status)
    end

    it "ensures the runtime is provisioned before #restart boots a VM again" do
      allow(native).to receive(:restart).and_return(
        instance_double(Microsandbox::Native::Sandbox, name: "box")
      )
      # Wrap the native double directly rather than going through .create, whose
      # own ensure_runtime! call would satisfy the expectation for us.
      Microsandbox::Sandbox.new(native).restart
      expect(Microsandbox).to have_received(:ensure_runtime!)
    end

    it "maps #restart options and returns a new live Sandbox" do
      restarted = instance_double(Microsandbox::Native::Sandbox, name: "box")
      allow(native).to receive(:restart).and_return(restarted)
      sb = Microsandbox::Sandbox.create("box", image: "x")

      expect(sb.restart).to be_a(Microsandbox::Sandbox)
      sb.restart(force: true, timeout: 3, detached: true)
      expect(native).to have_received(:restart).with({})
      expect(native).to have_received(:restart).with(
        {"force" => true, "detached" => true, "timeout" => 3.0}
      )
    end

    it "maps #destroy options and returns nil" do
      allow(native).to receive(:destroy)
      sb = Microsandbox::Sandbox.create("box", image: "x")

      expect(sb.destroy).to be_nil
      sb.destroy(force: true, timeout: 1.5)
      expect(native).to have_received(:destroy).with({})
      expect(native).to have_received(:destroy).with({"force" => true, "timeout" => 1.5})
    end

    it "rejects a non-finite restart/destroy timeout before the native call" do
      allow(native).to receive(:restart)
      allow(native).to receive(:destroy)
      sb = Microsandbox::Sandbox.create("box", image: "x")

      expect { sb.restart(timeout: -1) }
        .to raise_error(ArgumentError, /timeout must be a finite, non-negative/)
      expect { sb.destroy(timeout: Float::NAN) }
        .to raise_error(ArgumentError, /timeout must be a finite, non-negative/)
      expect(native).not_to have_received(:restart)
      expect(native).not_to have_received(:destroy)
    end
  end

  describe "SandboxHandle convergent lifecycle (runtime v0.6.16)" do
    let(:native_handle) { instance_double(Microsandbox::Native::SandboxHandle) }
    subject(:handle) { Microsandbox::SandboxHandle.new(native_handle) }

    it "exposes the bound sandbox identity as #id" do
      allow(native_handle).to receive(:id).and_return("local:7")
      expect(handle.id).to eq("local:7")
    end

    # Both of these can boot a microVM, so they must provision the runtime the
    # way Sandbox.create/.start do — otherwise a machine with no runtime fails
    # in the native layer instead of fetching one. (#destroy/#stop/#wait_* boot
    # nothing and deliberately skip the check.)
    it "ensures the runtime is provisioned before #connect_or_start" do
      allow(native_handle).to receive(:connect_or_start).and_return(native)
      handle.connect_or_start
      expect(Microsandbox).to have_received(:ensure_runtime!)
    end

    it "ensures the runtime is provisioned before #restart" do
      allow(native_handle).to receive(:restart).and_return(native)
      handle.restart
      expect(Microsandbox).to have_received(:ensure_runtime!)
    end

    it "does not provision the runtime for #destroy (it boots nothing)" do
      allow(native_handle).to receive(:destroy)
      handle.destroy
      expect(Microsandbox).not_to have_received(:ensure_runtime!)
    end

    it "maps #connect_or_start's detached flag and returns a live Sandbox" do
      allow(native_handle).to receive(:connect_or_start).and_return(native)
      expect(handle.connect_or_start).to be_a(Microsandbox::Sandbox)
      handle.connect_or_start(detached: true)
      expect(native_handle).to have_received(:connect_or_start).with({})
      expect(native_handle).to have_received(:connect_or_start).with({"detached" => true})
    end

    it "wraps #wait_for_status in a fresh SandboxHandle and validates the target" do
      allow(native_handle).to receive(:wait_for_status).and_return(native_handle)
      expect(handle.wait_for_status("paused")).to be_a(Microsandbox::SandboxHandle)
      expect(native_handle).to have_received(:wait_for_status).with("paused")

      expect { handle.wait_for_status(:gone) }
        .to raise_error(ArgumentError, /unknown sandbox status :gone/)
    end

    it "maps #restart / #destroy options the same way the live Sandbox does" do
      allow(native_handle).to receive(:restart).and_return(native)
      allow(native_handle).to receive(:destroy)

      expect(handle.restart(force: true, timeout: 2)).to be_a(Microsandbox::Sandbox)
      expect(handle.destroy(timeout: 0)).to be_nil
      expect(native_handle).to have_received(:restart).with({"force" => true, "timeout" => 2.0})
      expect(native_handle).to have_received(:destroy).with({"timeout" => 0.0})
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

  describe ".list / .list_with (paginated as of runtime v0.6.8)" do
    let(:native_handle) do
      instance_double(Microsandbox::Native::SandboxHandle, name: "box", status: "running")
    end
    let(:native_page) { {"sandboxes" => [native_handle], "next_cursor" => "tok"} }

    it "wraps the native page hash in an Enumerable SandboxPage" do
      allow(Microsandbox::Native::Sandbox).to receive(:list).and_return(native_page)
      page = Microsandbox::Sandbox.list
      expect(page).to be_a(Microsandbox::SandboxPage)
      expect(page.size).to eq(1)
      expect(page).not_to be_empty
      expect(page).not_to be_last_page
      expect(page.next_cursor).to eq("tok")
      expect(page.map(&:name)).to eq(["box"])
      expect(page.first).to be_a(Microsandbox::SandboxHandle)
    end

    it "reports the final page via last_page? when next_cursor is nil" do
      allow(Microsandbox::Native::Sandbox).to receive(:list).and_return(
        "sandboxes" => [], "next_cursor" => nil
      )
      page = Microsandbox::Sandbox.list
      expect(page).to be_empty
      expect(page).to be_last_page
      expect(page.next_cursor).to be_nil
    end

    it "normalizes label filters into a string-keyed labels hash" do
      allow(Microsandbox::Native::Sandbox).to receive(:list_with).and_return(native_page)
      page = Microsandbox::Sandbox.list_with(labels: {team: :core})
      expect(Microsandbox::Native::Sandbox).to have_received(:list_with).with(
        "labels" => {"team" => "core"}
      )
      expect(page.first).to be_a(Microsandbox::SandboxHandle)
      expect(page.first.name).to eq("box")
    end

    it "forwards limit and cursor, coercing types" do
      allow(Microsandbox::Native::Sandbox).to receive(:list_with).and_return(native_page)
      Microsandbox::Sandbox.list_with(limit: "50", cursor: :tok)
      expect(Microsandbox::Native::Sandbox).to have_received(:list_with).with(
        "labels" => {}, "limit" => 50, "cursor" => "tok"
      )
    end

    it "omits limit and cursor when not given" do
      allow(Microsandbox::Native::Sandbox).to receive(:list_with).and_return(native_page)
      Microsandbox::Sandbox.list_with(labels: {a: 1})
      expect(Microsandbox::Native::Sandbox).to have_received(:list_with).with(
        "labels" => {"a" => "1"}
      )
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

# The native binding parses durations with try_from_secs_f64, so a bad value is
# rejected as a clean Microsandbox::Error *before* any microVM boot — never a
# Rust panic across the FFI boundary. This exercises the REAL native layer (no
# stub): build_builder validates replace_with_timeout while constructing the
# builder, so it raises without ever calling .create(). Mirrors the agent
# client's timeout-validation specs. (The other native duration sites — exec
# timeout, stop/kill_with_timeout, metrics_stream interval — reach the same
# secs_to_duration helper but only via a live Sandbox/SandboxHandle instance,
# which the unit suite can't construct without a microVM, so they are covered by
# the integration suite; the Ruby coerce_duration guard for them is unit-tested
# above with the native layer stubbed. Note metrics_stream keeps a `<= 0.0`
# branch that defaults 0/negative to 1s, so only NaN/out-of-range reach
# secs_to_duration there — that NaN-specific branch is integration-only.)
RSpec.describe "native duration validation (panic-free)" do
  [Float::MAX, Float::INFINITY, -Float::INFINITY, Float::NAN].each do |bad|
    it "rejects #{bad.inspect} replace_with_timeout as a clean error, never a panic" do
      expect do
        Microsandbox::Native::Sandbox.create(
          "duration-probe", {"image" => "x", "replace_with_timeout" => bad}
        )
      end.to raise_error(Microsandbox::Error, /duration must be a non-negative, finite number/)
    end
  end
end
