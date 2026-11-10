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
`secret_violation_action:`, `cmd:`, `detached:`, `idle_timeout`/`max_duration`, and more —
is documented in [surface.md](surface.md) and typed in
[`sig/microsandbox.rbs`](../sig/microsandbox.rbs).

## Network policy

`network:` takes composable profiles (`:public`, `:private`, `:host`, `:none`)
or a custom `Microsandbox::NetworkPolicy` with per-rule CIDR/IP/domain/suffix/
group allow-deny rules, per-direction defaults, DNS and TLS-interception
settings, IPv4/IPv6 pools, connection caps (`max_tcp_connections:` for
proxied TCP connections, `max_udp_connections:` for UDP relay sessions; `0`
means unlimited, omit to keep the runtime default; `max_connections:` is a
deprecated alias of the TCP cap), and `trust_host_cas`.

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  network: Microsandbox::NetworkPolicy.custom(default_egress: :deny,
    rules: [{ action: :allow, direction: :egress, protocol: :tcp, port: 443,
              destination: Microsandbox::Destination.domain("api.example.com") }]))
```

### Strict hostname policy

Strict mode (runtime `v0.6.18`) makes a hostname-rule allow fail closed
unless the runtime can actually see the request authority (plain-HTTP `Host`,
or SNI/`:authority` under TLS interception); a bypassed or non-intercepted
HTTPS flow allowed only by a hostname rule is then denied before the upstream
dial. It is **on by default since 0.18.0** (runtime `v0.7`; it was opt-in
before): pass `strict: false` to opt out. Create-only. Independently of
`strict:`, any policy with domain rules checks plain-HTTP `Host` headers
against it.

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  network: Microsandbox::NetworkPolicy.custom(default_egress: :deny,
    rules: [{ action: :allow, direction: :egress, protocol: :tcp, port: 443,
              destination: Microsandbox::Destination.domain("api.example.com") }]))
# strict hostname enforcement applies by default; `strict: false` opts out.
```

### HTTP deny response

Since 0.18.0 (runtime `v0.7`) a request the network policy denies is answered
instead of reset: a denied plain-HTTP request — or an HTTPS one under TLS
interception — gets `403 Forbidden` with a JSON body such as
`{"code": "network_policy_denied", "domain": "example.com", "message":
"Request blocked by network policy."}`, and a request that a secret policy
blocks gets one too. Other denied traffic is still dropped. This is the
default for every sandbox the runtime starts, including ones created under
0.17.x or earlier: their stored config has no `http` setting, so they pick up
the default on their next start.

Tune it with the create-only `http:` Hash:

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  http: { network_message: "Egress is limited to the build mirror.",
          secret_message: "Secrets only go to api.example.com." })

# a plain-text 403 body instead of JSON (no custom messages in this format)
Microsandbox::Sandbox.create("worker", image: "python", http: { format: :text })

# the 0.17 behaviour: close the connection, no HTTP answer
Microsandbox::Sandbox.create("worker", image: "python", http: { deny_response: false })
```

| Key | Values | Default |
|---|---|---|
| `deny_response:` | `true` / `false` | `true` |
| `format:` | `:json` / `:text` (Symbol or String) | `:json` |
| `network_message:` | String, used as is as the JSON `message` of a network-policy denial | the runtime's message |
| `secret_message:` | String, the JSON `message` of a secret-policy denial | the runtime's message |

The two messages need the JSON format and an enabled response; an unknown key
or a wrong type raises `ArgumentError`. The setting is local-only: a cloud
create accepts the defaults and `deny_response: false`, and raises
`UnsupportedError` for a custom format or message.

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

`secrets:` gives the guest a placeholder and substitutes the real value only in
requests to the hosts you allow. At create time it is an **Array of specs** (one
bare spec Hash also works): `env:` is the variable the guest sees (holding the
placeholder), `value:` is the real secret, and `allow:` — required, non-empty —
lists the hosts that may receive the real value: exact names, `"*.example.com"`
wildcards, or `"*"` for ANY host (upstream's `allow_any_host_dangerous`; use it
only when you mean it).

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  secrets: [{ env: "API_KEY", value: ENV.fetch("HOST_API_KEY"), allow: ["api.example.com"] }])
# inside the guest: $API_KEY is "$MSB_API_KEY"; the proxy swaps in the real
# value for requests to api.example.com only
```

The other per-secret keys:

- `allow_placeholder_for:` — hosts that may receive the **unchanged
  placeholder** without it counting as a violation (e.g. an internal service
  that only forwards it).
- `placeholder:` — the guest-visible stand-in (default `$MSB_<env>`).
- `require_tls_identity:` — substitute only over TLS whose server identity was
  verified (default `true`).
- `substitution:` — where the value may be substituted:
  `{ headers:, header_fields:, query:, body: }`. Defaults: headers on, query
  and body off. `header_fields: [...]` limits header substitution to the named
  headers (it needs headers on). At least one location must stay enabled.
  Basic credentials in an `Authorization` header are substituted whenever
  header substitution applies.
- `violation_action:` — what happens when the placeholder heads for a host not
  in `allow:`/`allow_placeholder_for:`: `:block`, `:block_and_log`, or
  `:block_and_terminate` (kebab-case spellings are accepted too). The
  sandbox-wide default is the create keyword `secret_violation_action:`
  (upstream default `block_and_log`).

### Migrating secrets from 0.17.x

Runtime `v0.7` replaced the secrets vocabulary. The old keys raise
`ArgumentError` naming their replacement instead of being silently dropped:

| 0.17.x | 0.18.0 |
| --- | --- |
| `host:` / `hosts:` / `host_patterns:` | one `allow: [...]` list (wildcards included) |
| `inject_headers:` / `inject_query:` / `inject_body:` | `substitution: { headers:, query:, body: }` |
| `inject_basic_auth:` | removed: Basic credentials are substituted with header substitution |
| `require_tls:` | `require_tls_identity:` |
| `on_violation:` (per secret) | `violation_action:` |
| `on_secret_violation:` (create) | `secret_violation_action:` |
| passthrough violation policy (`passthrough_hosts:` / `"passthrough"`) | per-secret `allow_placeholder_for: [...]` |

`passthrough:` is still accepted on a secret spec as a deprecated alias of
`allow_placeholder_for:` (it warns, and the two lists are merged).

An inline `value:` is part of the sandbox's saved configuration: it is stored
in cleartext in the local catalog under the runtime home (`~/.microsandbox` by
default) until the sandbox is removed, and `SandboxHandle#config` returns it.
Stopping a sandbox does not remove it. Use `ephemeral: true` for short-lived
work, remove sandboxes you no longer need, and do not log `#config`.

Rotating an existing secret on a running sandbox is a live `modify`, which
takes a **different shape** — a Hash keyed by name, where `env:` names a *host*
environment variable to read the new value from. See
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

A relative host path (`volumes: { "/data" => "./data" }`, `image: "./rootfs"`,
a `root_disk:` image, a `Patch.copy_file` source, a `tls:` certificate) is resolved **once, when the sandbox is created**,
against the creating process's working directory, and stored as an absolute
path. Starting the sandbox later from another directory mounts the same host
directory. Resolution does not follow symlinks, and since runtime `v0.7` a bind
path that goes through a symlink (macOS's `/tmp` → `/private/tmp`, say) is
refused unless the mount sets `follow_root_symlinks: true`; pass the resolved
path instead. Sandboxes created by gem
versions before `0.17.1` kept the relative path and resolved it again on every
start ([GHSA-mcw9-9rf6-p4rm](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-mcw9-9rf6-p4rm));
recreate those. On a cloud backend, host paths are sent as written.

Booting from a snapshot is not bound in this build: `Sandbox.create(name,
from_snapshot: ...)` was removed with runtime `v0.7` and raises with directions.
