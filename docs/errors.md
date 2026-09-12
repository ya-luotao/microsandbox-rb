# Error handling

All errors descend from `Microsandbox::Error` (itself a `StandardError`) and
carry a stable, machine-readable `#code`. The native layer raises the matching
subclass for each core error variant; unmapped variants surface as the base
`Error`. The hierarchy is flat, mirroring the Python SDK.

```ruby
begin
  Microsandbox::Sandbox.create("dup", image: "public.ecr.aws/docker/library/alpine:latest")
  Microsandbox::Sandbox.create("dup", image: "public.ecr.aws/docker/library/alpine:latest")  # name clash
rescue Microsandbox::SandboxAlreadyExistsError => e
  warn "#{e.code}: #{e.message}"       # => "sandbox-already-exists: ..."
rescue Microsandbox::Error => e
  warn "microsandbox failed: #{e.message}"
end
```

`Microsandbox::SomeError.code` returns the code for a class without an instance.
Ruby-side keyword validation (a malformed `secrets:` spec, mutually exclusive
options) raises a plain `ArgumentError` before the native layer is reached.

## Classes and codes

| Class | `#code` | Raised when |
|-------|---------|-------------|
| `Error` | `microsandbox-error` | Base class; unmapped core errors |
| `InvalidConfigError` | `invalid-config` | Bad create options, invalid backend/cloud configuration |
| `SandboxNotFoundError` | `sandbox-not-found` | No sandbox with that name |
| `SandboxNotRunningError` | `sandbox-not-running` | Operation needs a running guest (`ping`/`touch`/`exec` on a stopped sandbox) |
| `SandboxAlreadyExistsError` | `sandbox-already-exists` | Name clash on `create` without `replace:` |
| `SandboxStillRunningError` | `sandbox-still-running` | `remove` on a running sandbox |
| `SandboxReplacedError` | `sandbox-replaced` | The identity a handle was bound to no longer owns the name (see [lifecycle.md](lifecycle.md#convergent-lifecycle)) |
| `ExecTimeoutError` | `exec-timeout` | `exec(timeout:)` / `shell(timeout:)` deadline hit |
| `ExecFailedError` | `exec-failed` | Spawn-time failure (e.g. command not found) — a non-zero exit is **not** an error |
| `NoDefaultCommandError` | `no-default-command` | `exec_default` / `attach_default` on an image with no runnable `ENTRYPOINT`+`CMD` |
| `FilesystemError` | `filesystem-error` | Guest filesystem I/O failure |
| `PathNotFoundError` | `path-not-found` | Reserved for parity; the native layer currently reports missing guest paths as `FilesystemError` |
| `VolumeNotFoundError` | `volume-not-found` | No named volume with that name |
| `VolumeAlreadyExistsError` | `volume-already-exists` | `Volume.create` name clash |
| `ImageNotFoundError` | `image-not-found` | Image absent from the cache / registry |
| `ImageInUseError` | `image-in-use` | `Image.remove` on an image a sandbox still references |
| `ImagePullFailedError` | `image-pull-failed` | Reserved for parity; not raised by the current native mapping |
| `SnapshotNotFoundError` | `snapshot-not-found` | No snapshot with that name |
| `SnapshotAlreadyExistsError` | `snapshot-already-exists` | Snapshot name clash |
| `SnapshotSandboxRunningError` | `snapshot-sandbox-running` | Snapshot requested from a running source sandbox |
| `SnapshotImageMissingError` | `snapshot-image-missing` | Restore needs an image that is not cached |
| `SnapshotIntegrityError` | `snapshot-integrity` | Snapshot payload failed verification |
| `SnapshotMigrationError` | `snapshot-migration` | Automatic snapshot-descriptor migration was blocked and needs repair |
| `NetworkPolicyError` | `network-policy-error` | Invalid network policy or `NetworkBuilder` validation failure (an invalid `proxy:` is `InvalidConfigError`) |
| `SecretViolationError` | `secret-violation` | Reserved for parity; not raised by the current native mapping |
| `TlsError` | `tls-error` | Reserved for parity; not raised by the current native mapping |
| `IoError` | `io-error` | Host-side I/O failure |
| `MetricsDisabledError` | `metrics-disabled` | Metrics turned off for this sandbox |
| `MetricsUnavailableError` | `metrics-unavailable` | No live metrics slot yet (transient right after boot) |
| `UnsupportedOperationError` | `unsupported-operation` | The runtime version does not support the operation |
| `CloudHttpError` | `cloud-http` | Cloud backend HTTP failure |
| `UnsupportedError` | `unsupported` | The selected backend does not implement the operation; carries `#operation` (e.g. `"sandbox.kill"`) and `#hint` |

The snapshot classes go beyond the Python SDK (which collapses them into its
base error) and match the Go SDK's per-variant coverage, so callers can rescue
a missing / duplicate / running-source / missing-image / corrupt snapshot
specifically.

The authoritative list is `lib/microsandbox/errors.rb`; the core-variant to
class mapping lives in `ext/microsandbox/src/error.rs`, and every class is
declared in [`sig/microsandbox.rbs`](../sig/microsandbox.rbs). Classes marked
"reserved" exist so callers can rescue them today without a code change once
the native layer maps a core variant to them.

## Secrets are redacted

The native layer redacts secret values from error messages (since `0.8.2`),
and a rejected proxy credential is reported by kind only, never by value.
