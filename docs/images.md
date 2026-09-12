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
remove / verify / save / load, and `Sandbox.create(name, from_snapshot: ...)` boots
from one. Snapshot failures raise the typed `Snapshot*Error` classes listed in
[errors.md](errors.md). Payload integrity is opt-in (`record_integrity:`), and
`verify` can report `:not_recorded` for snapshots taken without it.
