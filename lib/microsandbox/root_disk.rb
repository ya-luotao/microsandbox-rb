# frozen_string_literal: true

module Microsandbox
  # Factory for an OCI sandbox's writable **root disk** spec (runtime v0.6.7),
  # passed to {Sandbox.create} via `root_disk:`. Three kinds:
  #
  # - {managed} — the default: a sparse ext4 upper file created and resized by
  #   the runtime (4 GiB cap when no size is given). A bare Integer passed to
  #   `root_disk:` means the same thing.
  # - {tmpfs} — RAM-backed upper, so the rootfs is pristine on every boot.
  #   Default size is half the sandbox memory; the size must not exceed sandbox
  #   memory (no swap in the guest). Cannot be snapshotted or patched.
  # - {disk} — a user-supplied disk image attached writable as the upper. The
  #   file determines its own size; the runtime never creates, resizes, or
  #   deletes it. Cannot be snapshotted or patched.
  #
  # @example
  #   Sandbox.create("worker", image: "python", root_disk: 8192)
  #   Sandbox.create("ci", image: "python", root_disk: Microsandbox::RootDisk.tmpfs(2048))
  #   Sandbox.create("warm", image: "python",
  #     root_disk: Microsandbox::RootDisk.disk("./scratch.img", fstype: "ext4"))
  #
  # Mirrors the `RootDisk` factory in the official Python/Node/Go SDKs.
  module RootDisk
    module_function

    # The managed sparse-ext4 upper (the default kind).
    # @param size_mib [Integer, nil] size cap in MiB (default 4096)
    # @return [Hash]
    def managed(size_mib = nil)
      h = {"kind" => "managed"}
      h["size_mib"] = Integer(size_mib) if size_mib
      h
    end

    # A RAM-backed tmpfs upper — pristine rootfs on every boot.
    # @param size_mib [Integer, nil] size in MiB (default: half sandbox memory)
    # @return [Hash]
    def tmpfs(size_mib = nil)
      h = {"kind" => "tmpfs"}
      h["size_mib"] = Integer(size_mib) if size_mib
      h
    end

    # A user-supplied disk image attached writable as the upper.
    # @param path [String] path to the image file
    # @param format ["raw", "qcow2", nil] image format (inferred from the
    #   .img/.raw/.qcow2 extension when omitted)
    # @param fstype [String, nil] filesystem type inside the image, e.g. "ext4"
    # @return [Hash]
    def disk(path, format: nil, fstype: nil)
      h = {"kind" => "disk", "path" => path.to_s}
      h["format"] = format.to_s if format
      h["fstype"] = fstype.to_s if fstype
      h
    end
  end
end
