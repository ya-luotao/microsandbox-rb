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
entry in some of them is a different gem. This table is the mapping.

| Advisory | Severity | Affected `microsandbox-rb` | Status |
|---|---|---|---|
| [GHSA-mcw9-9rf6-p4rm](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-mcw9-9rf6-p4rm) — relative bind-mount paths re-resolved against the working directory on restart | High | `<= 0.17.0` | Fixed in `0.17.1` (paths are pinned at create time in the binding). Sandboxes created earlier with a relative path keep it: recreate them. |
| [GHSA-cg9x-2vfm-3j58](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-cg9x-2vfm-3j58) — NAT64 addresses can bypass destination-group network policy | High | all versions (runtime `< v0.7.5`) | **Not fixed in this gem yet**; needs the runtime fix. Only exploitable where the host network routes a NAT64 prefix. Mitigate by denying the prefix explicitly (see below) or blocking it at the host. |
| [GHSA-3mpp-52gc-935r](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-3mpp-52gc-935r) — hostname allowlist bypass via mismatched HTTP `Host` / `:authority` | High | `<= 0.16.0` | Runtime fix included from `0.17.0`. If you rely on a hostname allowlist for HTTPS without TLS interception, also pass `strict: true` (off by default in this gem). |
| [GHSA-gj24-29j2-3x78](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-gj24-29j2-3x78) — egress allowlist bypass on malformed HTTP/1 request lines | Medium | `<= 0.12.0` | Runtime fix included from `0.13.0`. |
| [GHSA-4vq3-cjpp-v7fg](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-4vq3-cjpp-v7fg) — guest-controlled symlinks in `msb copy` | High | `<= 0.10.0` (the bundled `msb` CLI) | Runtime fix included from `0.11.0`. |
| [GHSA-m8f5-rh7h-vgg3](https://github.com/superradcompany/microsandbox/security/advisories/GHSA-m8f5-rh7h-vgg3) — secret values in world-readable process arguments | Medium | `<= 0.7.0` | Runtime fix included from `0.8.0`. |

### Mitigating GHSA-cg9x-2vfm-3j58 before the runtime fix

On a host whose network provides NAT64 (typically IPv6-only networks), deny the
well-known prefix explicitly. Rules you pass are evaluated before the rules a
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
expected to be exploitable through this vector. This mitigation follows the
upstream advisory's guidance; it has not been exercised on a NAT64 network.
