# Sandbox configuration

All create-time options are keyword arguments to `Sandbox.create`,
`Sandbox.connect_or_create`, and `Sandbox.create_with_progress`.

## Resources, environment, ports, network

```ruby
Microsandbox::Sandbox.create(
  "configured",
  image:    "public.ecr.aws/docker/library/python:3-slim",
  cpus:     2,
  memory:   1024,                      # MiB
  env:      { "API_BASE" => "https://example.com" },
  workdir:  "/app",
  labels:   { "team" => "research" },
  ports:    { 8080 => 80 },            # host => guest (TCP)
  network:  [:public],                 # composable profiles; :none for airgapped
  replace:  true                       # replace an existing sandbox of the same name
) do |sb|
  # ...
end
```

To leave headroom for a live CPU/memory resize later, reserve a ceiling with
`max_cpus:`/`max_memory:` (see [observability.md](observability.md#live-modification-and-health)).

The full option list — `init`/`ephemeral`, disk-image `fstype`, `log_level`,
`security`, `rlimits`, `pull_policy`, `secrets`, `patches`
(`Microsandbox::Patch`), the structured `root_disk:` (`Microsandbox::RootDisk`),
`from_snapshot:`, `cmd:`, `detached:`, `idle_timeout`/`max_duration`, and more —
is documented in [surface.md](surface.md) and typed in
[`sig/microsandbox.rbs`](../sig/microsandbox.rbs).

## Network policy

`network:` takes composable profiles (`:public`, `:private`, `:host`, `:none`)
or a custom `Microsandbox::NetworkPolicy` with per-rule CIDR/IP/domain/suffix/
group allow-deny rules, per-direction defaults, DNS and TLS-interception
settings, IPv4/IPv6 pools, `max_connections`, and `trust_host_cas`.

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  network: Microsandbox::NetworkPolicy.custom(default_egress: :deny,
    rules: [{ action: :allow, direction: :egress, protocol: :tcp, port: 443,
              destination: Microsandbox::Destination.domain("api.example.com") }]))
```

### Strict hostname policy

`strict: true` (runtime `v0.6.18`) makes a hostname-rule allow fail closed
unless the runtime can actually see the request authority (plain-HTTP `Host`,
or SNI/`:authority` under TLS interception); a bypassed or non-intercepted
HTTPS flow allowed only by a hostname rule is then denied before the upstream
dial. Default `false`; create-only. Independently of `strict:`, any policy with
domain rules checks plain-HTTP `Host` headers against it.

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  network: Microsandbox::NetworkPolicy.custom(default_egress: :deny,
    rules: [{ action: :allow, direction: :egress, protocol: :tcp, port: 443,
              destination: Microsandbox::Destination.domain("api.example.com") }]),
  strict: true)
```

## Outbound proxy

Route the sandbox's egress through a SOCKS4 (TCP) or SOCKS5 (TCP + non-DNS UDP)
proxy with `proxy:` (runtime `v0.6.17`). The proxy is dialed by the runtime's
host-side network stack, so its address is resolved from the host (`127.0.0.1`
is the host's loopback), and the egress policy (`network:`) still governs which
destinations may be reached. A SOCKS5 password comes from a host environment
variable via `SecretSource.env` — only the variable's *name* is handed to the
runtime. Local backend only.

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  proxy: Microsandbox::OutboundProxy.socks5("127.0.0.1:1080"))

Microsandbox::Sandbox.create("worker", image: "python",
  proxy: Microsandbox::OutboundProxy.socks5("10.0.0.5:1080")
    .credentials("sandbox", Microsandbox::SecretSource.env("PROXY_PASSWORD")))

Microsandbox::Sandbox.create("worker", image: "python",
  proxy: Microsandbox::OutboundProxy.socks4("127.0.0.1:1080", user_id: "ci"))

# The equivalent plain Hash works too:
Microsandbox::Sandbox.create("worker", image: "python",
  proxy: { protocol: :socks5, address: "10.0.0.5:1080",
           credentials: { username: "sandbox", password: { env: "PROXY_PASSWORD" } } })
```

## Secrets

`secrets:` injects host-side secrets into the guest with multi-host / wildcard
allow-lists, injection toggles, and a per-secret or sandbox-level violation
policy. Specs are keyed by name; `env:`/`store:`/`value:` sources are mutually
exclusive:

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  secrets: { "API_KEY" => { env: "HOST_API_KEY", allowed_hosts: ["api.example.com"] } })
```

Rotating an existing secret on a running sandbox is a live `modify` — see
[observability.md](observability.md#live-modification-and-health).

## Volumes and mounts

Persistent storage that outlives individual sandboxes:

```ruby
Microsandbox::Volume.create("cache", kind: "disk", size_mib: 512)
Microsandbox::Volume.list           # => [Microsandbox::VolumeInfo, ...]

Microsandbox::Sandbox.create("with-vol", image: "public.ecr.aws/docker/library/alpine:latest",
                             volumes: { "/data" => { named: "cache" } }) do |sb|
  sb.fs.write("/data/state.txt", "persisted")
end

Microsandbox::Volume.remove("cache")
```

`volumes:` accepts a host path String (bind mount) or `{ bind: "/host" }` /
`{ named: "volume-name" }` per guest path (tmpfs and disk mounts, mount
policies, and a per-bind-mount `quota_mib:` are supported too). A bind or
named mount may pin the fallback guest owner for host files with `uid:`/`gid:`
(both required together, runtime `v0.6.15`). Named volumes can also be read and
written from the host without booting a sandbox via `Volume.fs` /
`VolumeInfo#fs`.

Boot from a snapshot with `Sandbox.create(name, from_snapshot: "snap-name-or-path")`.
