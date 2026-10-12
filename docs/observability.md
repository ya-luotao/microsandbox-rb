# Metrics, logs, and live modification

## Metrics & logs

```ruby
Microsandbox::Sandbox.create("obs", image: "public.ecr.aws/docker/library/alpine:latest") do |sb|
  # On v0.6.x runtimes the metrics slot goes live a beat after create returns,
  # so `metrics` can briefly raise "no live metrics slot" right after boot —
  # retry for a few hundred ms rather than treating the first failure as fatal.
  m = sb.metrics                       # => Microsandbox::Metrics
  m.cpu_percent
  m.memory_bytes
  m.uptime_secs

  sb.logs(tail: 100, sources: ["stdout", "stderr"]).each do |entry|
    puts "[#{entry.source}] #{entry.text}"
  end
end
```

Streaming counterparts: `sb.metrics_stream` (`MetricsStream` over `Metrics`)
and `sb.log_stream` (`LogStream` over `LogEntry`) — both single-pass, see
[execution.md](execution.md#streams-are-single-pass).
`Microsandbox.all_sandbox_metrics` reports every running sandbox at once.

`MetricsDisabledError` means metrics are turned off for the sandbox. The
metrics slot goes live a moment *after* `create` returns; a call inside that
window raises the base `Microsandbox::Error` with a message containing
`no live metrics slot` (not `MetricsUnavailableError`, which the pinned runtime
never raises). Retry on that message:

```ruby
metrics = begin
  sb.metrics
rescue Microsandbox::Error => e
  raise unless e.message.include?("no live metrics slot")
  sleep 0.1
  retry
end
```

`sb.log_stream(follow: true)` keeps waiting for new entries and **does not end
when the sandbox stops** — the runtime follows the log file, not the sandbox —
and the wait cannot be interrupted. A thread blocked in it also keeps the
process from exiting normally. Read what exists with `sb.logs` or
`sb.log_stream` (no `follow:`), or follow from a separate process you can kill.

## Live modification and health

Resize, reconfigure, or rotate secrets on a sandbox **without recreating it**,
and probe the guest agent's liveness. To leave headroom for a live CPU/memory
resize, reserve a ceiling at create time with `max_cpus:`/`max_memory:`:

```ruby
Microsandbox::Sandbox.create("live", image: "public.ecr.aws/docker/library/alpine:latest",
  cpus: 1, max_cpus: 4, memory: 512, max_memory: 2048) do |sb|
  # Health check — does NOT refresh the idle timer:
  ping = sb.ping                       # => Microsandbox::PingResult
  ping.latency_ms                      # round-trip latency

  # Explicitly refresh the idle-activity timer (resets any idle_timeout:):
  sb.touch.activity_seq                # => Microsandbox::TouchResult

  # Preview a change without applying it:
  plan = sb.modify(cpus: 2, memory: 1024, dry_run: true)
  plan.applied?                        # => false
  plan.changes                         # => [{ kind: "config", field: "cpus", ... }, ...]

  # Live resize — applies to the running VM under the default :no_restart policy:
  sb.modify(cpus: 2, memory: 1024)

  # Grow the root disk (managed upper or flat, MiB — runtime v0.6.9). Applied
  # while stopped; growth-only:
  sb.modify(root_disk_size: 8192, policy: :next_start)

  # env/labels/workdir changes on a *running* sandbox require a restart, so the
  # default :no_restart policy rejects the whole apply (it raises rather than
  # partially applying). Persist them for the next start — or restart now —
  # by saying so explicitly:
  sb.modify(env: { "TIER" => "prod" }, remove_env: ["DEBUG"],
    labels: { "role" => "worker" }, policy: :next_start)  # or policy: :restart

  # Rotating/removing an *existing* secret (or updating its allowed hosts) is
  # live; *adding* a new secret is restart-required, like env. Specs are keyed
  # by name; env:/store:/value: are mutually exclusive:
  sb.modify(
    secrets: { "API_KEY" => { env: "HOST_API_KEY", allowed_hosts: ["api.example.com"] } },
    remove_secrets: ["OLD_TOKEN"],
  )
end
```

The apply is **all-or-nothing**: under a given `policy:` every planned change
must be applicable, or the whole `modify` raises — nothing is partially
applied. Use `dry_run: true` to inspect each change's `disposition` (`"live"`,
`"next start"`, `"requires restart"`) before committing.

`SandboxHandle` (from `Sandbox.get`/`list`) carries the same `#ping`/`#touch`/
`#modify`; on a stopped sandbox `#ping`/`#touch` raise `SandboxNotRunningError`.
