# frozen_string_literal: true

require "tmpdir"
require_relative "../support/wire_capture"

# Wire-level option mapping: Ruby kwargs → normalized Hash → ext → core builder
# → serialized create request, observed offline through a fake cloud API. The
# stubbed-native specs prove the Ruby half only; these prove both halves, so a
# key the ext stops reading (or a flag the Ruby layer stops emitting) fails here.
RSpec.describe "create options on the wire (native-serialized)" do
  include WireCapture

  def mount(spec)
    Dir.mktmpdir do |dir|
      host = File.realpath(dir)
      spec = spec.transform_values { |v| (v == :host) ? host : v }
      return wire_create(volumes: {"/d" => spec}).fetch("mounts").fetch(0)
    end
  end

  describe "mount isolation flags" do
    it "is read-write, exec, suid, dev by default" do
      expect(mount(bind: :host)["options"])
        .to eq("readonly" => false, "noexec" => false, "nosuid" => false, "nodev" => false)
    end

    {
      {ro: true} => "readonly",
      {readonly: true} => "readonly",
      {"ro" => true} => "readonly",
      {"readonly" => true} => "readonly",
      {noexec: true} => "noexec",
      {nosuid: true} => "nosuid",
      {nodev: true} => "nodev",
      {options: %w[ro]} => "readonly",
      {options: %w[noexec]} => "noexec",
      {options: %w[nosuid]} => "nosuid",
      {options: %w[nodev]} => "nodev"
    }.each do |flag, wire_key|
      it "serializes #{flag.inspect} as options.#{wire_key} == true (and nothing else)" do
        spec = flag.keys.first.is_a?(String) ? {"bind" => :host}.merge(flag) : {bind: :host}.merge(flag)
        options = mount(spec)["options"]
        expect(options[wire_key]).to be(true)
        expect(options.reject { |k, _| k == wire_key }.values).to all(be(false))
      end
    end

    it "carries the flags on tmpfs mounts too" do
      m = wire_create(volumes: {"/t" => {tmpfs: true, size_mib: 64, ro: true, noexec: true, nosuid: true, nodev: true}})
        .fetch("mounts").fetch(0)
      expect(m).to include("type" => "tmpfs", "size_mib" => 64)
      expect(m["options"].values).to all(be(true))
    end

    it "serializes quota_mib / stat_virtualization / host_permissions" do
      m = mount(bind: :host, quota_mib: 16, stat_virtualization: :relaxed, host_permissions: :mirror)
      expect(m).to include("quota_mib" => 16, "stat_virtualization" => "relaxed", "host_permissions" => "mirror")
    end
  end

  describe "network policy defaults and ordering" do
    def policy(network)
      wire_create(network: network).dig("network", "policy")
    end

    def summary(rule)
      [rule["action"], rule["direction"], rule["destination"]]
    end

    it "defaults a rules-only Hash to deny egress / allow ingress (fail-closed)" do
      p = policy(rules: [Microsandbox::Rule.allow(destination: "1.1.1.1", protocol: :tcp, port: "443")])
      expect(p).to include("default_egress" => "deny", "default_ingress" => "allow")
      expect(p["rules"]).to eq([{
        "direction" => "egress", "destination" => {"cidr" => "1.1.1.1/32"},
        "protocols" => ["tcp"], "ports" => [{"start" => 443, "end" => 443}], "action" => "allow"
      }])
    end

    it "treats an empty profile list as deny-egress with no rules" do
      expect(policy(profiles: [])).to eq("default_egress" => "deny", "default_ingress" => "allow", "rules" => [])
    end

    it "honours default_egress:/default_ingress: layered on a profile base" do
      p = policy(profiles: [:public], default_egress: :allow, default_ingress: :deny)
      expect(p).to include("default_egress" => "allow", "default_ingress" => "deny")
    end

    it "orders deny lists, then caller rules, then the profile expansion (first match wins)" do
      p = policy(profiles: [:public], rules: [Microsandbox::Rule.deny_dns],
        deny_domains: ["evil.example"], deny_domain_suffixes: [".ads.example"])
      expect(p["rules"].map { |r| summary(r) }).to eq([
        ["deny", "egress", {"domain" => "evil.example"}],
        ["deny", "egress", {"domain_suffix" => "ads.example"}],
        ["deny", "egress", {"group" => "host"}],
        ["allow", "egress", {"group" => "host"}],
        ["allow", "egress", {"group" => "public"}]
      ])
    end

    it "disables networking entirely for :none" do
      net = wire_create(network: :none).fetch("network")
      expect(net["enabled"]).to be(false)
      expect(net["policy"]).to include("default_egress" => "deny", "default_ingress" => "deny", "rules" => [])
    end

    it "keeps deny lists when layered on the allow_all preset" do
      p = policy(preset: :allow_all, deny_domains: ["x.example"])
      expect(p).to include("default_egress" => "allow")
      expect(p["rules"].map { |r| summary(r) }).to eq([["deny", "egress", {"domain" => "x.example"}]])
    end
  end

  describe "secrets" do
    it "serializes the allow list, placeholder, toggles and violation policy" do
      secrets = wire_create(
        secrets: [
          {env: "API_KEY", value: "s3cr3t", host: "api.example.com"},
          {env: "K2", value: "v2", hosts: ["a.example"], host_patterns: ["*.b.example"], placeholder: "PH",
           require_tls: false, inject_headers: false, inject_query: true, on_violation: "block-and-terminate"}
        ],
        on_secret_violation: {passthrough_hosts: ["p.example"]}
      ).dig("network", "secrets")
      first, second = secrets.fetch("entries")
      expect(first).to include(
        "env_var" => "API_KEY", "placeholder" => "$MSB_API_KEY", "require_tls_identity" => true,
        "allowed_hosts" => [{"type" => "exact", "value" => "api.example.com"}],
        "injection" => {"headers" => true, "basic_auth" => true, "query_params" => false, "body" => false}
      )
      expect(second).to include(
        "placeholder" => "PH", "require_tls_identity" => false,
        "allowed_hosts" => [{"type" => "exact", "value" => "a.example"}, {"type" => "wildcard", "value" => "*.b.example"}],
        "injection" => {"headers" => false, "basic_auth" => true, "query_params" => true, "body" => false},
        "on_violation" => {"type" => "block_and_terminate"}
      )
      expect(secrets["on_violation"]).to eq("type" => "passthrough", "hosts" => [{"type" => "exact", "value" => "p.example"}])
    end
  end

  describe "scalar options" do
    it "serializes resources, runtime, lifecycle, pull policy and security profile" do
      body = wire_create(
        cpus: 2, memory: 1024, root_disk: 2048, env: {"A" => "1"}, workdir: "/w", shell: "/bin/bash",
        user: "app", labels: {team: "x"}, scripts: {hello: "echo hi"}, entrypoint: [], cmd: %w[sleep 1],
        max_duration: 60, idle_timeout: 30, rlimits: {nofile: [10, 20]}, log_level: "debug",
        security: "restricted", ephemeral: true, pull_policy: "never", max_connections: 7,
        registry_auth: {username: "u", password: "p"}
      )
      expect(body["resources"]).to eq("vcpus" => 2, "memory_mib" => 1024, "disk_size_mib" => 2048)
      expect(body["runtime"]).to include("workdir" => "/w", "shell" => "/bin/bash", "user" => "app",
        "scripts" => {"hello" => "echo hi"}, "entrypoint" => [], "cmd" => %w[sleep 1], "log_level" => "debug")
      expect(body["env"]).to eq([{"key" => "A", "value" => "1"}])
      expect(body["labels"]).to eq("team" => "x")
      expect(body["rlimits"]).to eq([{"resource" => "nofile", "soft" => 10, "hard" => 20}])
      expect(body["lifecycle"]).to eq("ephemeral" => true, "max_duration_secs" => 60, "idle_timeout_secs" => 30)
      expect(body).to include("pull_policy" => "never", "security_profile" => "restricted")
      expect(body.dig("network", "max_connections")).to eq(7)
      expect(body["registry"]).to eq("mode" => "inline", "username" => "u", "password" => "p")
    end

    it "inherits the image ENTRYPOINT/CMD when neither is given" do
      expect(wire_create["runtime"]).to include("entrypoint" => nil, "cmd" => nil)
    end
  end

  # The cloud backend refuses these BEFORE sending anything; the refusal names
  # the field, which proves the ext applied the option to the core's builder.
  describe "options the cloud backend rejects (applied-by-the-ext evidence)" do
    {
      {hostname: "h"} => "hostname",
      {cpus: 1, max_cpus: 2} => "max_cpus",
      {memory: 512, max_memory: 1024} => "max_memory",
      {ports: {8080 => 80}} => "network ports",
      {ports_udp: {5353 => 53}} => "network ports",
      {dns: {nameservers: ["1.1.1.1"]}} => "custom DNS",
      {trust_host_cas: true} => "host-CA trust",
      {tls: {bypass: ["*.x"]}} => "network.tls",
      {ipv4_pool: "10.9.0.0/24"} => "network.interface",
      {ipv6_pool: "fd00::/64"} => "network.interface",
      {rate_limiter: {egress: {bandwidth: {size: 1, refill_time_ms: 1}}}} => "network.rate_limiter",
      {proxy: {protocol: :socks5, address: "127.0.0.1:1080"}} => "network.outbound_proxy",
      {vsock: {"/tmp/a.sock" => 5000}} => "vsock",
      {replace: true} => "replace",
      {replace_with_timeout: 3} => "replace",
      {registry_insecure: true} => "insecure",
      {registry_ca_certs: "PEM"} => "ca_certs",
      {root_disk: {kind: :tmpfs, size_mib: 64}} => "non-managed root_disk",
      {root_disk: {kind: :flat, size_mib: 2048}} => "non-managed root_disk"
    }.each do |kwargs, field|
      it "#{kwargs.keys.join("+")}: reaches the core (rejected as #{field.inspect})" do
        expect(wire_rejection(**kwargs).message).to include(field)
      end
    end
  end
end
