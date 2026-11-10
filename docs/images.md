# Images, registries, and snapshots

## The local image cache

Images are pulled automatically on `create` (governed by `pull_policy:`). The
cache itself is managed through `Microsandbox::Image`:

```ruby
Microsandbox::Image.list           # => [Microsandbox::ImageInfo, ...]
Microsandbox::Image.get("public.ecr.aws/docker/library/alpine:latest")  # => Microsandbox::ImageInfo
Microsandbox::Image.inspect("public.ecr.aws/docker/library/alpine:latest").layers  # => [{...}, ...]
Microsandbox::Image.remove("public.ecr.aws/docker/library/alpine:latest", force: true)
report = Microsandbox::Image.prune
report.bytes_reclaimed
```

`Image.save`/`Image.load` move images through OCI archives, and
`Sandbox.create_with_progress` returns a `PullSession` that streams pull
progress before yielding the booted sandbox.

## Why the examples use `public.ecr.aws/docker/library/...`

Anonymous **Docker Hub** pulls are rate-limited and often fail with
`registry error: Not authorized`. The examples pull from AWS's public mirror of
the Docker Library instead. Plain short names like `image: "python"` work too if
you aren't rate-limited; for authenticated Docker Hub, pass `registry_auth:`.

## Private & authenticated registries

For a private registry — or to lift Docker Hub's anonymous rate limit — pass
`registry_auth:` with a username and a password or token:

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

## Snapshots

`Microsandbox::Snapshot` covers create / open / get / list / list_dir / reindex /
remove / verify / save / load. `Snapshot.create` captures the disk by default;
`full: true` (it replaced `resumable:` in 0.18.0) captures a resumable
checkpoint. Booting a sandbox from a snapshot is not bound yet in this build:
`Sandbox.create(from_snapshot:)` was removed with runtime `v0.7` and raises
with directions. Snapshot failures raise the typed `Snapshot*Error` classes listed in
[errors.md](errors.md). Payload integrity is opt-in (`record_integrity:`), and
`verify` can report `:not_recorded` for snapshots taken without it.

Since 0.18.0 (runtime `v0.7`) snapshots live in **groups**. `Snapshot.create(name,
from_sandbox: src)` publishes the artifact into the group named after `src`, as a
member aliased `name`, and makes it the group head. Selectors for `open` / `get` /
`verify` / `save` / `remove` resolve like this:

| Selector | Selects |
|---|---|
| `"src"` (a bare name) | the group's current head |
| `"src:name"` | that member |
| `info.id` (`snap_…`) or `info.digest` (`sha256:…`) | that snapshot |
| `info.path` (anything containing `/` or starting with `.`) | that artifact directory |

So the `name` given to `create` is not a selector on its own any more: keep the
returned `SnapshotInfo#id`. `Snapshot.load` puts the copy into a fresh generated
group with no head selected, so address it by `id` or `path` too. `create(force:
true)` is rejected (grouped snapshots are immutable). The group surface itself
(choosing a group, moving the head) is not bound yet.

```ruby
info = Microsandbox::Snapshot.create("before-upgrade", from_sandbox: "worker")
Microsandbox::Snapshot.verify(info.id)
Microsandbox::Snapshot.get("worker:before-upgrade").id == info.id  # => true
```
