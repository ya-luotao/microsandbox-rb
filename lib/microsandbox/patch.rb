# frozen_string_literal: true

module Microsandbox
  # Factory for **rootfs patches** — modifications applied to a sandbox's root
  # filesystem *before* the microVM boots. Pass them to {Sandbox.create} via the
  # `patches:` keyword:
  #
  # @example
  #   Microsandbox::Sandbox.create("box", image: "alpine",
  #     patches: [
  #       Microsandbox::Patch.text("/etc/app.conf", "key = value\n", mode: 0o644),
  #       Microsandbox::Patch.mkdir("/opt/app"),
  #       Microsandbox::Patch.copy_file("./cert.pem", "/etc/ssl/app.pem"),
  #       Microsandbox::Patch.symlink("/etc/app.conf", "/etc/app.link"),
  #       Microsandbox::Patch.remove("/etc/motd"),
  #     ]) do |sb|
  #     # ...
  #   end
  #
  # Patches apply to OverlayFS (OCI) and bind rootfs; they are **not** compatible
  # with disk-image roots. Each factory returns a plain Hash, so a patch list is
  # just an Array of Hashes — you may also build them by hand. Mirrors the
  # `Patch` factory in the official Python/Node/Go SDKs.
  module Patch
    module_function

    # Write UTF-8 text to a file, creating it (or replacing it when +replace+).
    # @param path [String] absolute guest path
    # @param content [String] text to write
    # @param mode [Integer, nil] file mode (e.g. 0o644)
    # @param replace [Boolean] allow shadowing a path already in the rootfs
    # @return [Hash]
    def text(path, content, mode: nil, replace: false)
      h = {"kind" => "text", "path" => path.to_s, "content" => content.to_s, "replace" => replace ? true : false}
      h["mode"] = Integer(mode) unless mode.nil?
      h
    end

    # Write raw bytes to a file (binary-safe; content may contain NUL).
    # @param path [String] absolute guest path
    # @param content [String] raw bytes to write
    # @param mode [Integer, nil] file mode
    # @param replace [Boolean]
    # @return [Hash]
    def file(path, content, mode: nil, replace: false)
      h = {"kind" => "file", "path" => path.to_s, "content" => content.to_s, "replace" => replace ? true : false}
      h["mode"] = Integer(mode) unless mode.nil?
      h
    end

    # Append text to an existing file. For OCI roots, a file living only in a
    # lower image layer is copied up first, then appended.
    # @return [Hash]
    def append(path, content)
      {"kind" => "append", "path" => path.to_s, "content" => content.to_s}
    end

    # Copy a host file into the rootfs.
    # @param src [String] host path
    # @param dst [String] absolute guest destination
    # @param mode [Integer, nil] file mode (preserves source mode when nil)
    # @param replace [Boolean]
    # @return [Hash]
    def copy_file(src, dst, mode: nil, replace: false)
      h = {"kind" => "copy_file", "src" => src.to_s, "dst" => dst.to_s, "replace" => replace ? true : false}
      h["mode"] = Integer(mode) unless mode.nil?
      h
    end

    # Copy a host directory (recursively) into the rootfs.
    # @return [Hash]
    def copy_dir(src, dst, replace: false)
      {"kind" => "copy_dir", "src" => src.to_s, "dst" => dst.to_s, "replace" => replace ? true : false}
    end

    # Create a symlink at +link+ pointing to +target+.
    # @return [Hash]
    def symlink(target, link, replace: false)
      {"kind" => "symlink", "target" => target.to_s, "link" => link.to_s, "replace" => replace ? true : false}
    end

    # Create a directory (idempotent — no error if it already exists).
    # @param path [String] absolute guest path
    # @param mode [Integer, nil] directory mode (e.g. 0o755)
    # @return [Hash]
    def mkdir(path, mode: nil)
      h = {"kind" => "mkdir", "path" => path.to_s}
      h["mode"] = Integer(mode) unless mode.nil?
      h
    end

    # Remove a file or directory (idempotent — no error if absent).
    # @return [Hash]
    def remove(path)
      {"kind" => "remove", "path" => path.to_s}
    end
  end
end
