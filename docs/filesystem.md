# Guest filesystem

`Sandbox#fs` is a `Microsandbox::FS` bound to the running guest.

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

## Streaming reads and writes

Large files stream instead of buffering: `fs.read_stream(path)` returns a
single-pass `FsReadStream` (see
[execution.md](execution.md#streams-are-single-pass)), and
`fs.write_stream(path)` returns an `FsWriteSink` to write into and close.

## Errors

Guest filesystem failures, including missing paths, raise
`Microsandbox::FilesystemError` (`#code` `filesystem-error`); the message
carries the guest-side detail. See [errors.md](errors.md).

## Host-side volume access

Named volumes can be read and written from the host without a running sandbox
through `Microsandbox::Volume.fs(name)` / `VolumeInfo#fs` (a `VolumeFs`). See
[configuration.md](configuration.md#volumes-and-mounts).
