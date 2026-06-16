# microsandbox (Ruby)

Lightweight microVM sandboxes for Ruby — run AI agents and untrusted code with hardware-level isolation.

The `microsandbox` gem provides native bindings to the [microsandbox](https://github.com/superradcompany/microsandbox) runtime via a Rust extension (magnus). It spins up real microVMs (not containers) in under 100 ms, runs standard OCI (Docker) images, and gives you full control over command execution, the guest filesystem, networking, and metrics — all from an idiomatic, **synchronous** Ruby API. There is no daemon to install and no server to connect to: the runtime is embedded directly in your process.

This is the Ruby member of the official SDK family ([Rust](https://github.com/superradcompany/microsandbox/tree/main/sdk), TypeScript, Python, Go), wrapping the same core engine.

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
- Building from source additionally needs a **Rust** toolchain (stable >= 1.91)

## Installation

```ruby
# Gemfile
gem "microsandbox"
```

```bash
bundle install
# or
gem install microsandbox
```

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

Releases are automated by `.github/workflows/release.yml`:

1. Bump `Microsandbox::VERSION` (and the `tag = "vX.Y.Z"` on the core-crate
   dependency in `ext/microsandbox/Cargo.toml`) to match the upstream runtime,
   update `CHANGELOG.md`.
2. Push a `vX.Y.Z` tag. CI builds precompiled, multi-ABI platform gems
   (`x86_64-linux`, `aarch64-linux`, `arm64-darwin`) with
   `rake-compiler-dock`, plus the source gem, and publishes them to RubyGems via
   Trusted Publishing (OIDC — configure the trusted publisher in the RubyGems UI
   first). Use the workflow's manual `dry_run` dispatch to build artifacts without
   publishing.

See [DESIGN.md](DESIGN.md) for the architecture and [the implemented-surface
section](DESIGN.md#implemented-surface-v1-vs-roadmap) for what's covered today
vs. on the roadmap (streaming exec/logs, volumes, images, snapshots, SSH, the
raw agent client, and fine-grained networking).

## License

Apache-2.0. See [LICENSE](LICENSE).
