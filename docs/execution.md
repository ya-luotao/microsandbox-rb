# Executing commands

## `exec` and `shell`

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
failures (e.g. command not found) and timeouts raise typed errors
([errors.md](errors.md)). `exec`/`shell` also take per-call `rlimits`.

## Default workload

`create` is strictly boot-only (runtime `v0.6.9`): it never runs the image's
`ENTRYPOINT`/`CMD`. Execute the image's own command explicitly:

```ruby
Microsandbox::Sandbox.create("worker", image: "example/worker:latest",
  cmd: ["worker.py", "--once"]) do |sb|   # cmd: overrides the durable image CMD
  out = sb.exec_default(timeout: 300)     # buffered; exec-style options
  handle = sb.exec_default_stream         # or streaming (returns an ExecHandle)
  sb.attach_default                       # or interactive (host TTY)
end
```

An image whose entrypoint and CMD resolve to no executable command raises
`Microsandbox::NoDefaultCommandError`.

## Streaming output

For long-running commands, stream events as they arrive instead of waiting:

```ruby
Microsandbox::Sandbox.create("stream", image: "public.ecr.aws/docker/library/python:3-slim") do |sb|
  handle = sb.exec_stream("python", ["-u", "-c", "import time\nfor i in range(3): print(i); time.sleep(1)"])
  handle.each do |event|       # ExecHandle is Enumerable
    print event.text if event.stdout?
  end
  # or: out = handle.collect  → ExecOutput  (drain to the end)
  # interactive stdin — create the stream with stdin: :pipe to get a writable sink:
  #   h = sb.exec_stream("cat", [], stdin: :pipe)
  #   sink = h.stdin; sink.write("data\n"); sink.close  # close sends EOF
  # control: handle.signal(15), handle.kill, handle.resize(rows, cols)
end
```

`shell_stream` is the shell-script counterpart. For a host-TTY-coupled
interactive session (raw mode + SIGWINCH), use `attach`/`attach_shell`.

### Streams are single-pass

`ExecHandle`, `LogStream`, `MetricsStream`, `FsReadStream`, `PullSession`, and
`AgentStream` are `Enumerable`, but `each` drains a one-shot native channel —
they are forward-only, not rewindable, and meant for a single consumer. Iterate
(or `collect`/`read`) exactly once: a second `each`, or a combinator after a
partial drain (`count` then `each`, `to_a` twice), silently yields nothing.
Don't share one handle across threads.

## Threads, the GVL, and timeouts

The GVL is released during sandbox calls, so *other* Ruby threads keep
running. The *calling* thread blocks uninterruptibly until the call returns:
`Timeout::timeout`, `Thread#kill`, and Ctrl-C cannot interrupt a blocked native
call. Bound long-running work with a real deadline where one exists:

- `exec(timeout:)` / `shell(timeout:)` kill the guest command after N seconds.
- `AgentClient.connect_sandbox` / `connect_path` take a `timeout:` that bounds
  only the connect handshake.
- The streaming paths and `AgentClient#request`/`#stream` have no timeout knob
  and can block indefinitely if the guest wedges.

See [DESIGN.md](../DESIGN.md#sync-not-async) for the sync-over-async bridge
behind this.

## SSH and SFTP

`Sandbox#ssh` opens an in-process SSH client to the guest (`SshClient`, with an
`SftpClient` for file transfer) or prepares an `SshServer`. `open_client` /
`prepare_server` accept `inactivity_timeout:` in seconds (`0` disables, `nil`
inherits the 600s global default).

## Raw agent client

`Microsandbox::AgentClient` gives byte-level access to the guest `agentd`
protocol (`AgentStream`/`AgentFrame`) for protocol-level work the higher-level
API doesn't cover.
