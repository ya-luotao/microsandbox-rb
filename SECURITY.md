# Security Policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue:

- GitHub: <https://github.com/ya-luotao/microsandbox-rb/security/advisories/new>
  ("Report a vulnerability" on the repository's Security tab).

Include the gem version (`Microsandbox::VERSION`), the embedded runtime
(`Microsandbox.runtime_version`), the host OS, and the smallest reproduction you
have. You should get a first reply within a few days.

If the problem is in the microsandbox runtime itself (the `msb` binary, the
guest agent, the network engine) rather than in this Ruby binding, report it
upstream at <https://github.com/superradcompany/microsandbox/security> — and
feel free to tell us too, so the fix can be tracked for this gem.

## Supported versions

Only the latest released version receives fixes. The gem embeds a specific
upstream runtime; the README's Versioning table maps every gem version to its
runtime tag.

## Upstream advisories and this gem

Upstream advisories name the upstream packages (the Rust crate, the CLI, and
the official SDKs). **They do not list `microsandbox-rb`**, so `bundler-audit`
and Dependabot will not flag this gem for them. The `rubygems:microsandbox`
entry in some of them refers to the upstream project's own Ruby gem, not to
`microsandbox-rb`. This table is the mapping.

| Advisory | Severity | Affected `microsandbox-rb` | Status |
|---|---|---|---|
| [GHSA-rh2c-vm8j-5gg6](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-rh2c-vm8j-5gg6) — `Volume.fs` paths that pass through a missing directory escape the volume root | Critical | `0.7.0`–`0.17.0` | Mitigated in `0.17.1`: every `Volume.fs` / `VolumeInfo#fs` method refuses a path with a `..` segment, in both the Ruby and the native layer, which closes the published bypass (`write`, `mkdir`, `copy` and `rename` through a directory that does not exist). **Fully fixed in `0.18.0`**, which embeds runtime `v0.7.14`: upstream rewrote host-side volume access in runtime `v0.7.6`, which also closes the window between checking a path and using it. The upstream advisory lists only `microsandbox <= 0.6.16` with no patched version, but the affected resolver is unchanged in every runtime up to `v0.7.5`, so gem `0.17.0` (runtime `v0.6.18`) is affected too. `Volume.fs` first appeared in `0.7.0`. Tracked for this gem as [GHSA-7hgp-qrrh-xc2m](https://github.com/ya-luotao/microsandbox-rb/security/advisories/GHSA-7hgp-qrrh-xc2m). |
| [GHSA-mcw9-9rf6-p4rm](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-mcw9-9rf6-p4rm) — relative bind-mount paths re-resolved against the working directory on restart | High | `<= 0.17.0` | Fixed in `0.17.1` for sandboxes created through this gem (paths are pinned at create time in the binding). Sandboxes created earlier with a relative path keep it: recreate them. Upstream fixed it in runtime `v0.7.6`, so from `0.18.0` (runtime `v0.7.14`) the `msb` CLI this gem installs pins relative paths too; with `0.17.x` its `msb` is runtime `v0.6.18`, so a sandbox created with `msb` directly is not covered there: use absolute paths. Tracked for this gem as [GHSA-qrhv-m6hf-9cmg](https://github.com/ya-luotao/microsandbox-rb/security/advisories/GHSA-qrhv-m6hf-9cmg). |
| [GHSA-cg9x-2vfm-3j58](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-cg9x-2vfm-3j58) — NAT64 addresses can bypass destination-group network policy | High | `<= 0.17.5` (runtime `< v0.7.5`) | **Fixed in `0.18.0`** (runtime `v0.7.14`; upstream fixed it in `v0.7.5`). Only exploitable where the host network routes a NAT64 prefix. On older gem versions, mitigate by denying the prefix explicitly (see below) or blocking it at the host. |
| [GHSA-cvr8-2329-j4xw](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-cvr8-2329-j4xw) — sandbox catalog database is created world-readable, exposing persisted secret and environment values to other local users | Medium | `<= 0.17.5` | **Fixed in `0.18.0`** (runtime `v0.7.14`; upstream fixed it in `v0.7.12`): the catalog directory and its SQLite files are owner-only, and an existing catalog is tightened when the runtime opens it. The runtime home must now be private to one OS account (see `docs/runtime.md`). Tracked for this gem as [GHSA-pwg7-fm3g-v2xj](https://github.com/ya-luotao/microsandbox-rb/security/advisories/GHSA-pwg7-fm3g-v2xj). |
| [GHSA-3mpp-52gc-935r](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-3mpp-52gc-935r) — hostname allowlist bypass via mismatched HTTP `Host` / `:authority` | High | `<= 0.16.0` | Runtime fix included from `0.17.0`. If you rely on a hostname allowlist for HTTPS without TLS interception, also keep strict mode on: it is the default from `0.18.0`, and `0.17.x` needs `strict: true`. |
| [GHSA-gj24-29j2-3x78](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-gj24-29j2-3x78) — egress allowlist bypass on malformed HTTP/1 request lines | Medium | `<= 0.12.0` | Runtime fix included from `0.13.0`. |
| [GHSA-4vq3-cjpp-v7fg](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-4vq3-cjpp-v7fg) — guest-controlled symlinks in `msb copy` | High | `<= 0.10.0` (the bundled `msb` CLI) | Runtime fix included from `0.11.0`. |
| [GHSA-v693-3rfr-6q3q](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-v693-3rfr-6q3q) — IPv4-mapped IPv6 addresses bypass DNS rebind protection | Critical | `<= 0.9.1` | Runtime fix included from `0.9.2` (runtime `v0.6.3`). Affects network-enabled sandboxes. |
| [GHSA-m8f5-rh7h-vgg3](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-m8f5-rh7h-vgg3) — secret values in world-readable process arguments | Medium | `<= 0.7.0` | Runtime fix included from `0.8.0`. |
| [GHSA-89j4-256r-3pcq](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-89j4-256r-3pcq) — symlink traversal when importing a snapshot archive | High | `0.5.7`–`0.5.9` (`Snapshot.import` and the bundled `msb snapshot import`) | Runtime fix included from `0.5.10` (runtime `v0.5.8`). |

[GHSA-xgg5-hjwq-2gw8](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-xgg5-hjwq-2gw8)
(domain deny rules bypassed by direct-IP TLS) does not affect any release of
this gem: it was fixed in runtime `v0.5.0`, and the first release, `0.5.7`,
embeds runtime `v0.5.7`.

[GHSA-3f94-vm6x-3jv3](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-3f94-vm6x-3jv3)
(cross-sandbox filesystem access via a guest-controlled root-disk journal,
runtime `0.7.8` on Windows) does not affect any release of this gem either:
the gem does not support Windows, no release embedded a runtime between
`v0.6.18` and `v0.7.14`, and runtime `v0.6.18` has no root-disk journal
(`crates/runtime/lib/checkpoint` does not exist there).

### Mitigating GHSA-cg9x-2vfm-3j58 on `0.17.5` and earlier

Upgrade to `0.18.0`. Until you can, on a host whose network provides NAT64
(typically IPv6-only networks), deny the well-known prefix explicitly. Rules you pass are evaluated before the rules a
profile expands to, so this keeps the default public-internet profile and puts
the deny ahead of it:

```ruby
Microsandbox::Sandbox.create("worker", image: "python",
  network: {
    profiles: [:public],
    rules: [Microsandbox::Rule.deny(destination: "64:ff9b::/96")]
  })
```

If your network uses a different NAT64 prefix, deny that one as well, or block
the prefix at the host or network boundary. Hosts without NAT64 routing are not
expected to be exploitable through this vector.

The deny rule is this gem's suggestion, relying on the policy engine matching
rules in order; it has not been exercised on a NAT64 network. The upstream
advisory's own workarounds are to disable sandbox networking for untrusted
workloads (`network: :none`) or to block NAT64 prefixes at the host or network
boundary.
