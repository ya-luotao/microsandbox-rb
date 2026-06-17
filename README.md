# microsandbox-rb

Lightweight microVM sandboxes for Ruby — run AI agents and untrusted code with hardware-level isolation.

The `microsandbox-rb` gem provides native bindings to the [microsandbox](https://github.com/superradcompany/microsandbox) runtime via a Rust extension (magnus). It spins up real microVMs (not containers) in under 100 ms, runs standard OCI (Docker) images, and gives you full control over command execution, the guest filesystem, networking, and metrics — all from an idiomatic, **synchronous** Ruby API. There is no daemon to install and no server to connect to: the runtime is embedded directly in your process.

This is an **unofficial, community-maintained** Ruby implementation — not part of the official SDK family ([Rust](https://github.com/superradcompany/microsandbox/tree/main/sdk), TypeScript, Python, Go) — though it wraps the same core engine.

## Features

- **Hardware isolation** — each sandbox is a real VM with its own Linux kernel
- **Sub-100 ms boot** — no daemon, no server setup, embedded directly in your app
- **OCI image support** — pull and run images from Docker Hub, GHCR, ECR, or any OCI registry
- **Command execution** — run commands or shell scripts and collect output
- **Guest filesystem access** — read, write, list, copy, stat files inside a running sandbox
- **Metrics & logs** — CPU, memory, disk and network I/O; captured stdout/stderr/system logs
- **Idiomatic Ruby** — keyword arguments, block-scoped lifecycle, a typed error hierarchy
- **Thread-friendly** — the GVL is released during sandbox calls, so other Ruby threads keep running

## Requirements

- **Ruby** >= 3.1
- **Linux** with KVM enabled, or **macOS** on Apple Silicon (M-series)
- A **Rust** toolchain (stable >= 1.91) — the gem currently installs as a source
  gem and compiles the native extension on install (precompiled per-platform
  gems are planned; see [Releasing](#releasing))

## Installation

The gem is published as **`microsandbox-rb`**, but you still `require "microsandbox"`
(the `microsandbox` package name was already taken on RubyGems):

```ruby
# Gemfile
gem "microsandbox-rb", require: "microsandbox"
```

```bash
bundle install
# or
gem install microsandbox-rb
```

Installing compiles the Rust extension, so the first install takes a few minutes
and needs a Rust toolchain on `PATH`.

The first build downloads the `msb` runtime and `libkrunfw` firmware into
`~/.microsandbox`. You can (re)provision them explicitly at any time:

```ruby
Microsandbox.install unless Microsandbox.installed?
```

## Quick start

```ruby
require "microsandbox"

Microsandbox::Sandbox.create("hello", image: "python") do |sb|
  output = sb.exec("python", ["-c", "print('Hello, World!')"])
  puts output.stdout      # => "Hello, World!\n"
  puts output.success?    # => true
end
# the sandbox is stopped automatically when the block returns
```

## Usage

### Lifecycle

```ruby
# Block form — recommended; stops the sandbox automatically (even on error)
Microsandbox::Sandbox.create("box", image: "alpine") do |sb|
  # ...
end

# Manual form — you are responsible for stopping it
sb = Microsandbox::Sandbox.create("box", image: "alpine")
begin
  # ...
ensure
  sb.stop          # graceful (sb.stop(timeout: 5) to bound the wait)
  # sb.kill        # force (SIGKILL)
end

# Inspect / manage existing sandboxes
Microsandbox::Sandbox.list            # => [Microsandbox::SandboxInfo, ...]
Microsandbox::Sandbox.get("box")      # => Microsandbox::SandboxInfo
Microsandbox::Sandbox.start("box")    # restart a stopped sandbox
Microsandbox::Sandbox.remove("box")   # remove a stopped sandbox
```

### Configuration

```ruby
Microsandbox::Sandbox.create(
  "configured",
  image:    "python",
  cpus:     2,
  memory:   1024,                      # MiB
  env:      { "API_BASE" => "https://example.com" },
  workdir:  "/app",
  labels:   { "team" => "research" },
  ports:    { 8080 => 80 },            # host => guest (TCP)
  network:  "public_only",             # or "none" for airgapped
  replace:  true                       # replace an existing sandbox of the same name
) do |sb|
  # ...
end
```

### Executing commands

```ruby
Microsandbox::Sandbox.create("exec-demo", image: "alpine") do |sb|
  # Direct command (no shell)
  out = sb.exec("ls", ["-la", "/etc"], cwd: "/", timeout: 30)
  out.exit_code   # => 0
  out.success?    # => true
  out.stdout      # => "..." (UTF-8)
  out.stderr_bytes # => raw ASCII-8BIT bytes

  # Shell script (pipes, redirects, &&)
  sb.shell("cat /etc/os-release | grep VERSION").stdout

  # Environment, stdin, working directory
  sb.exec("cat", [], stdin: "piped data")
  sb.exec("sh", ["-c", "echo $GREETING"], env: { "GREETING" => "hi" })
end
```

A non-zero exit is **not** an error — inspect `exit_code`/`success?`. Spawn-time
failures (e.g. command not found) and timeouts raise typed errors (see below).

### Guest filesystem

```ruby
Microsandbox::Sandbox.create("fs-demo", image: "alpine") do |sb|
  sb.fs.write("/tmp/data.txt", "hello")
  sb.fs.read_text("/tmp/data.txt")     # => "hello"  (UTF-8)
  sb.fs.read("/tmp/data.txt")          # => raw bytes (ASCII-8BIT)
  sb.fs.exists?("/tmp/data.txt")       # => true

  sb.fs.mkdir("/tmp/sub")
  sb.fs.copy("/tmp/data.txt", "/tmp/sub/copy.txt")
  sb.fs.rename("/tmp/sub/copy.txt", "/tmp/sub/renamed.txt")
  sb.fs.list("/tmp/sub")               # => [Microsandbox::FsEntry, ...]
  sb.fs.stat("/tmp/data.txt")          # => Microsandbox::FsMetadata

  # Host <-> guest copies
  sb.fs.copy_from_host("./local.txt", "/tmp/local.txt")
  sb.fs.copy_to_host("/tmp/out.txt", "./out.txt")
end
```

### Metrics & logs

```ruby
Microsandbox::Sandbox.create("obs", image: "alpine") do |sb|
  m = sb.metrics                       # => Microsandbox::Metrics
  m.cpu_percent
  m.memory_bytes
  m.uptime_secs

  sb.logs(tail: 100, sources: ["stdout", "stderr"]).each do |entry|
    puts "[#{entry.source}] #{entry.text}"
  end
end
```

### Streaming output

For long-running commands, stream events as they arrive instead of waiting:

```ruby
Microsandbox::Sandbox.create("stream", image: "python") do |sb|
  handle = sb.exec_stream("python", ["-u", "-c", "import time\nfor i in range(3): print(i); time.sleep(1)"])
  handle.each do |event|       # ExecHandle is Enumerable
    print event.text if event.stdout?
  end
  # or: out = handle.collect  → ExecOutput  (drain to the end)
  # interactive stdin:
  #   sink = handle.stdin; sink.write("data\n"); sink.close
  # control: handle.signal(15), handle.kill, handle.resize(rows, cols)
end
```

### Images

Manage the local OCI image cache (images are pulled automatically on `create`):

```ruby
Microsandbox::Image.list           # => [Microsandbox::ImageInfo, ...]
Microsandbox::Image.get("alpine")  # => Microsandbox::ImageInfo
Microsandbox::Image.inspect("alpine").layers  # => [{...}, ...]
Microsandbox::Image.remove("alpine", force: true)
report = Microsandbox::Image.prune
report.bytes_reclaimed
```

### Named volumes

Persistent storage that outlives individual sandboxes:

```ruby
Microsandbox::Volume.create("cache", kind: "disk", size_mib: 512)
Microsandbox::Volume.list           # => [Microsandbox::VolumeInfo, ...]

Microsandbox::Sandbox.create("with-vol", image: "alpine",
                             volumes: { "/data" => { named: "cache" } }) do |sb|
  sb.fs.write("/data/state.txt", "persisted")
end

Microsandbox::Volume.remove("cache")
```

`volumes:` accepts a host path String (bind mount) or `{ bind: "/host" }` /
`{ named: "volume-name" }` per guest path. Boot from a snapshot with
`Sandbox.create(name, from_snapshot: "snap-name-or-path")`.

### Error handling

All errors descend from `Microsandbox::Error` and carry a stable `#code`:

```ruby
begin
  Microsandbox::Sandbox.create("dup", image: "alpine")
  Microsandbox::Sandbox.create("dup", image: "alpine")  # name clash
rescue Microsandbox::SandboxAlreadyExistsError => e
  warn "#{e.code}: #{e.message}"       # => "sandbox-already-exists: ..."
rescue Microsandbox::Error => e
  warn "microsandbox failed: #{e.message}"
end
```

| Class | `#code` |
|-------|---------|
| `InvalidConfigError` | `invalid-config` |
| `SandboxNotFoundError` | `sandbox-not-found` |
| `SandboxAlreadyExistsError` | `sandbox-already-exists` |
| `SandboxStillRunningError` | `sandbox-still-running` |
| `ExecTimeoutError` | `exec-timeout` |
| `ExecFailedError` | `exec-failed` |
| `FilesystemError` | `filesystem-error` |
| `ImageNotFoundError` | `image-not-found` |
| `MetricsDisabledError` / `MetricsUnavailableError` | `metrics-disabled` / `metrics-unavailable` |
| … | (see `lib/microsandbox/errors.rb`) |

## Runtime configuration

The `msb` runtime path is resolved in this order: the `MSB_PATH` environment
variable → an SDK-set override → the config file → `~/.microsandbox/bin/msb` →
`msb` on `PATH`.

```ruby
Microsandbox.installed?            # => true/false
Microsandbox.install               # download + install the runtime (idempotent)
Microsandbox.runtime_path          # => "/Users/you/.microsandbox/bin/msb"
Microsandbox.runtime_path = "/opt/microsandbox/bin/msb"  # override
```

## Development

```bash
bin/setup            # bundle install
bundle exec rake compile          # build the native extension (debug)
bundle exec rake compile:release  # build optimized
bundle exec rake spec             # run unit specs (no runtime needed)
MICROSANDBOX_INTEGRATION=1 bundle exec rake spec:all   # + real microVM specs
```

Unit specs run without a runtime. Integration specs boot real microVMs and are
opt-in via `MICROSANDBOX_INTEGRATION=1` (override the test image with
`MICROSANDBOX_TEST_IMAGE`).

The native extension depends on the `microsandbox` core crate via a pinned git
tag, so it builds without an adjacent checkout. To develop against a sibling
`microsandbox/` checkout instead (faster, reflects local runtime changes):

```bash
cp .cargo/config.toml.example .cargo/config.toml   # gitignored path override
bundle exec rake compile
```

## Releasing

Releases are automated by `.github/workflows/release.yml` via RubyGems
**Trusted Publishing** (OIDC) — there is no API key to store as a secret.

**One-time setup** (before the first release), create a *pending* trusted
publisher at <https://rubygems.org/profile/oidc/pending_trusted_publishers>:

| Field | Value |
|-------|-------|
| RubyGems gem name | `microsandbox-rb` |
| Repository owner | `ya-luotao` |
| Repository name | `microsandbox-rb` |
| Workflow filename | `release.yml` |
| Environment | *(leave blank)* |

On the first successful push the pending publisher auto-converts to a permanent
one bound to the gem.

**Each release:**

1. Bump `Microsandbox::VERSION` (and the `tag = "vX.Y.Z"` on the core-crate
   dependency in `ext/microsandbox/Cargo.toml`) to match the upstream runtime,
   update `CHANGELOG.md`.
2. Push a `vX.Y.Z` tag. CI builds the **source gem** and pushes it to RubyGems
   via `rubygems/configure-rubygems-credentials` (OIDC, `id-token: write`) — no
   `RUBYGEMS_API_KEY` secret required.

> **Precompiled per-platform gems** are not on the release path yet — this gem
> wraps a heavy core crate whose `build.rs` downloads platform-specific `msb` +
> `libkrunfw` binaries and links `libkrunfw`/keyring, which doesn't
> cross-compile cleanly through the generic `rake-compiler-dock`/osxcross flow.
> The `cross-gems` job is gated to manual `workflow_dispatch` so you can iterate
> on it (`gh workflow run release.yml`) without failing tag releases. Once it
> produces working gems on all platforms, re-add it to `publish.needs` and drop
> the `workflow_dispatch` gate. Until then, users install the source gem (which
> compiles via `rb_sys`).

See [DESIGN.md](DESIGN.md) for the architecture and the implemented-surface
section for what's covered today vs. on the roadmap. Covered: full sandbox
lifecycle (including the async `request_stop`/`request_kill`/`request_drain`/
`wait_until_stopped`/`detach`/`owns_lifecycle?` controls and label-filtered
`list_with`), `exec`/`shell` (collected and streaming), the full guest
filesystem, metrics (per-sandbox, `Microsandbox.all_sandbox_metrics`, and
streaming `metrics_stream`/`log_stream`), logs, OCI image-cache management,
named volumes, and snapshots (create/list/verify/export/import +
boot-from-snapshot). Create options span resources, network policy presets,
`log_level`/`security`/`rlimits`/`pull_policy`/`secrets` and more; `exec`/`shell`
take per-call `rlimits`. Still on the roadmap: custom per-rule network policies,
file patches, registry auth, interactive `attach`, SSH, and the raw agent client.

## License

Apache-2.0. See [LICENSE](LICENSE).
