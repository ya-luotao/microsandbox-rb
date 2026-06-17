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
- **Rootfs patches** — inject files, dirs, and symlinks into the image before boot (`Microsandbox::Patch`)
- **Fine-grained networking** — policy presets *and* custom CIDR/domain/group allow-deny rules (`Microsandbox::NetworkPolicy`)
- **SSH & SFTP** — native in-process SSH client/server and file transfer (`Sandbox#ssh`)
- **Raw agent client** — byte-level access to the guest `agentd` protocol (`Microsandbox::AgentClient`)
- **Idiomatic Ruby** — keyword arguments, block-scoped lifecycle, a typed error hierarchy
- **Thread-friendly** — the GVL is released during sandbox calls, so other Ruby threads keep running

## Requirements

- **Ruby** >= 3.1
- **Linux** with KVM enabled, or **macOS** on Apple Silicon (M-series)
- A **Rust** toolchain (stable >= 1.91) — needed only when installing the source
  gem (it compiles the native extension on install). Precompiled per-platform
  gems, where available, require no Rust toolchain; see [Releasing](#releasing)

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

Installing the **source gem** compiles the Rust extension, so the first install
takes a few minutes and needs a Rust toolchain (`rustc >= 1.91`) on `PATH`. When
a **precompiled platform gem** is available for your OS/architecture, RubyGems
picks it automatically and no Rust toolchain is required.

Either way the `msb` runtime and `libkrunfw` firmware are provisioned into
`~/.microsandbox` automatically on first use (the first `Sandbox.create`/`start`
downloads them if missing). To provision ahead of time — e.g. while baking a
container image, or to avoid the first-call latency — call `install` explicitly:

```ruby
Microsandbox.install unless Microsandbox.installed?
```

Set `MICROSANDBOX_NO_AUTO_INSTALL` to disable the automatic first-use download
(e.g. on air-gapped hosts that provision the runtime out of band).

## Quick start

```ruby
require "microsandbox"

Microsandbox::Sandbox.create("hello", image: "public.ecr.aws/docker/library/python:3-slim") do |sb|
  output = sb.exec("python", ["-c", "print('Hello, World!')"])
  puts output.stdout      # => "Hello, World!\n"
  puts output.success?    # => true
end
# the sandbox is stopped automatically when the block returns
```

> **Why `public.ecr.aws/docker/library/...`?** The examples pull from AWS's
> public mirror of the Docker Library because anonymous **Docker Hub** pulls are
> rate-limited and often fail with `registry error: Not authorized`. Plain short
> names like `image: "python"` work too if you aren't rate-limited. For private
> or authenticated registries (including authenticated Docker Hub), pass
> `registry_auth:` — see [Private & authenticated registries](#private--authenticated-registries).

## Usage

### Lifecycle

```ruby
# Block form — recommended; stops the sandbox automatically (even on error)
Microsandbox::Sandbox.create("box", image: "public.ecr.aws/docker/library/alpine:latest") do |sb|
  # ...
end

# Manual form — you are responsible for stopping it
sb = Microsandbox::Sandbox.create("box", image: "public.ecr.aws/docker/library/alpine:latest")
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
  image:    "public.ecr.aws/docker/library/python:3-slim",
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
Microsandbox::Sandbox.create("exec-demo", image: "public.ecr.aws/docker/library/alpine:latest") do |sb|
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
Microsandbox::Sandbox.create("fs-demo", image: "public.ecr.aws/docker/library/alpine:latest") do |sb|
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
Microsandbox::Sandbox.create("obs", image: "public.ecr.aws/docker/library/alpine:latest") do |sb|
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
Microsandbox::Sandbox.create("stream", image: "public.ecr.aws/docker/library/python:3-slim") do |sb|
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
Microsandbox::Image.get("public.ecr.aws/docker/library/alpine:latest")  # => Microsandbox::ImageInfo
Microsandbox::Image.inspect("public.ecr.aws/docker/library/alpine:latest").layers  # => [{...}, ...]
Microsandbox::Image.remove("public.ecr.aws/docker/library/alpine:latest", force: true)
report = Microsandbox::Image.prune
report.bytes_reclaimed
```

### Private & authenticated registries

Images are pulled automatically on `create`. For a private registry — or to lift
Docker Hub's anonymous rate limit — pass `registry_auth:` with a username and a
password or token:

```ruby
Microsandbox::Sandbox.create(
  "private",
  image: "registry.example.com/team/app:latest",
  registry_auth: { username: "ci-bot", password: ENV.fetch("REGISTRY_TOKEN") }
) do |sb|
  # ...
end
```

For self-hosted registries you can also reach the registry over plain HTTP and
trust a private CA:

```ruby
Microsandbox::Sandbox.create(
  "internal",
  image: "registry.internal:5000/app:latest",
  registry_insecure: true,                                  # plain HTTP instead of HTTPS
  registry_ca_certs: File.read("/etc/pki/internal-ca.pem")  # String or Array of PEMs
)
```

Without `registry_auth:`, the core's default credential resolution still applies
(OS keyring, global config, and `~/.docker/config.json`), so an existing
`docker login` is honored automatically.

### Named volumes

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
`{ named: "volume-name" }` per guest path. Boot from a snapshot with
`Sandbox.create(name, from_snapshot: "snap-name-or-path")`.

### Error handling

All errors descend from `Microsandbox::Error` and carry a stable `#code`:

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

> **Precompiled per-platform gems** are built best-effort by the `cross-gems`
> job, gated to manual `workflow_dispatch` so you can iterate
> (`gh workflow run release.yml`) without failing tag releases. They are not
> auto-published on tags yet: a gem that *compiles but can't boot a microVM*
> would be served to users ahead of the source gem, and CI can't boot a VM to
> prove otherwise — so promotion is manual after validating the artifact on each
> platform. A precompiled gem ships the compiled extension (with the guest
> `agentd` baked in by *target* arch); the host-side `msb` + `libkrunfw` runtime
> is fetched into `~/.microsandbox` on first use by `Microsandbox.ensure_runtime!`
> (libkrunfw is `dlopen`'d by `msb` at runtime, never linked into the gem). The
> real cross-compile work is linking the *target* native libraries — `libcap-ng`
> on Linux (handled via Debian multiarch in the workflow) and the Hypervisor +
> Security frameworks on macOS (via osxcross; the one platform left to confirm).
> Until promoted, users install the source gem (which compiles via `rb_sys`).

See [DESIGN.md](DESIGN.md) for the architecture and the implemented-surface
section. The binding now covers the full official-SDK surface: sandbox
lifecycle (including the async `request_stop`/`request_kill`/`request_drain`/
`wait_until_stopped`/`detach`/`owns_lifecycle?` controls and label-filtered
`list_with`), `exec`/`shell` (collected and streaming), interactive `attach`/
`attach_shell`, the full guest filesystem, metrics (per-sandbox,
`Microsandbox.all_sandbox_metrics`, and streaming `metrics_stream`/`log_stream`),
logs, OCI image-cache management, named volumes, snapshots (create/list/verify/
export/import + boot-from-snapshot), **rootfs patches** (`Microsandbox::Patch`),
**custom per-rule network policies** (`Microsandbox::NetworkPolicy`/`Rule`/
`Destination`, alongside the presets), **SSH** (`Sandbox#ssh` →
`SshClient`/`SftpClient`/`SshServer`), and the **raw agent client**
(`Microsandbox::AgentClient`). Create options span resources, network policy,
`log_level`/`security`/`rlimits`/`pull_policy`/`secrets`/`patches` and more;
`exec`/`shell` take per-call `rlimits`, and `create` accepts
`registry_auth`/`registry_insecure`/`registry_ca_certs` for private and
authenticated registries.

## License

Apache-2.0. See [LICENSE](LICENSE).
