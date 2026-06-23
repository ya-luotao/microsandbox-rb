# frozen_string_literal: true

module Microsandbox
  # A directory entry returned by {FS#list}.
  class FsEntry
    # @return [String] absolute guest path
    attr_reader :path
    # @return [Symbol] one of :file, :directory, :symlink, :other
    attr_reader :type
    # @return [Integer] size in bytes
    attr_reader :size
    # @return [Integer] POSIX mode bits
    attr_reader :mode

    def initialize(data)
      @path = data["path"]
      @type = data["type"].to_sym
      @size = data["size"]
      @mode = data["mode"]
      @modified_ms = data["modified_ms"]
    end

    # @return [String] the final path component
    def name
      File.basename(@path)
    end

    # @return [Time, nil] last-modified time, if known
    def modified
      @modified_ms && Time.at(@modified_ms / 1000.0)
    end

    def file? = @type == :file
    def directory? = @type == :directory
    def symlink? = @type == :symlink

    def inspect
      "#<Microsandbox::FsEntry path=#{@path.inspect} type=#{@type} size=#{@size}>"
    end
  end

  # File/directory metadata returned by {FS#stat}.
  class FsMetadata
    # @return [Symbol] one of :file, :directory, :symlink, :other
    attr_reader :type
    # @return [Integer] size in bytes
    attr_reader :size
    # @return [Integer] POSIX mode bits
    attr_reader :mode

    def initialize(data)
      @type = data["type"].to_sym
      @size = data["size"]
      @mode = data["mode"]
      @readonly = data["readonly"]
      @modified_ms = data["modified_ms"]
      @created_ms = data["created_ms"]
    end

    def readonly? = @readonly
    def file? = @type == :file
    def directory? = @type == :directory
    def symlink? = @type == :symlink

    # @return [Time, nil] last-modified time, if known
    def modified
      @modified_ms && Time.at(@modified_ms / 1000.0)
    end

    # @return [Time, nil] creation time, if known
    def created
      @created_ms && Time.at(@created_ms / 1000.0)
    end

    def inspect
      "#<Microsandbox::FsMetadata type=#{@type} size=#{@size} mode=#{format("%o", @mode)}>"
    end
  end

  # Guest filesystem operations for a running sandbox. Obtain via {Sandbox#fs}.
  # All paths are paths *inside* the guest VM.
  class FS
    def initialize(native)
      @native = native
    end

    # Read a file as raw bytes (ASCII-8BIT).
    # @return [String]
    def read(path)
      @native.fs_read(path.to_s)
    end

    # Read a file as a UTF-8 string.
    # @return [String]
    def read_text(path)
      @native.fs_read_text(path.to_s)
    end

    # Write data to a file, creating or truncating it.
    # @param data [String] raw bytes to write (binary-safe; ASCII-8BIT is fine)
    # @raise [TypeError] if +data+ is not a String (rather than silently writing
    #   its +to_s+ form, e.g. the inspect string of a StringIO or "42")
    # @return [nil]
    def write(path, data)
      bytes = Microsandbox.coerce_write_bytes(data)
      @native.fs_write(path.to_s, bytes)
      nil
    end

    # List the entries of a directory.
    # @return [Array<FsEntry>]
    def list(path)
      @native.fs_list(path.to_s).map { |entry| FsEntry.new(entry) }
    end

    # Create a directory (and any missing parents).
    # @return [nil]
    def mkdir(path)
      @native.fs_mkdir(path.to_s)
      nil
    end

    # Remove a single file.
    # @return [nil]
    def remove(path)
      @native.fs_remove(path.to_s)
      nil
    end

    # Remove a directory recursively.
    # @return [nil]
    def remove_dir(path)
      @native.fs_remove_dir(path.to_s)
      nil
    end

    # Copy a file within the guest.
    # @return [nil]
    def copy(src, dst)
      @native.fs_copy(src.to_s, dst.to_s)
      nil
    end

    # Rename/move a file or directory within the guest.
    # @return [nil]
    def rename(src, dst)
      @native.fs_rename(src.to_s, dst.to_s)
      nil
    end

    # @return [Boolean] whether the path exists in the guest
    def exists?(path)
      @native.fs_exists(path.to_s)
    end

    # Stat a path.
    # @return [FsMetadata]
    def stat(path)
      FsMetadata.new(@native.fs_stat(path.to_s))
    end

    # Copy a file from the host into the guest.
    # @return [nil]
    def copy_from_host(host_path, guest_path)
      @native.fs_copy_from_host(host_path.to_s, guest_path.to_s)
      nil
    end

    # Copy a file from the guest to the host.
    # @return [nil]
    def copy_to_host(guest_path, host_path)
      @native.fs_copy_to_host(guest_path.to_s, host_path.to_s)
      nil
    end

    # Open a streaming reader over a guest file — for files too large to read
    # into memory at once (unlike {#read}, which buffers the whole file).
    # @return [FsReadStream] an {Enumerable} of byte chunks (ASCII-8BIT)
    def read_stream(path)
      FsReadStream.new(@native.fs_read_stream(path.to_s))
    end

    # Open a streaming writer to a guest file. With a block, the sink is yielded
    # and closed (flushed) when the block returns.
    # @yieldparam sink [FsWriteSink]
    # @return [FsWriteSink, Object]
    def write_stream(path)
      sink = FsWriteSink.new(@native.fs_write_stream(path.to_s))
      return sink unless block_given?

      begin
        yield sink
      ensure
        sink.close
      end
    end
  end

  # A streaming reader over a guest file, from {FS#read_stream}. Iterate it (it
  # is {Enumerable}) to consume byte chunks (ASCII-8BIT) as they arrive, or call
  # {#read} to drain it into one String.
  class FsReadStream
    include Enumerable

    def initialize(native)
      @native = native
    end

    # Yield each chunk of bytes until the stream ends. Returns an Enumerator when
    # called without a block.
    # @yieldparam chunk [String] raw bytes (ASCII-8BIT)
    # @return [self, Enumerator]
    def each
      return enum_for(:each) unless block_given?

      while (chunk = @native.recv)
        yield chunk
      end
      self
    end

    # Drain the stream into a single byte String.
    # @return [String] raw bytes (ASCII-8BIT)
    def read
      buffer = +"".b
      each { |chunk| buffer << chunk }
      buffer
    end
  end

  # A streaming writer to a guest file, from {FS#write_stream}.
  class FsWriteSink
    def initialize(native)
      @native = native
    end

    # Write a chunk of bytes.
    # @param data [String] raw bytes (binary-safe)
    # @raise [TypeError] if +data+ is not a String
    # @return [self]
    def write(data)
      bytes = Microsandbox.coerce_write_bytes(data)
      @native.write(bytes)
      self
    end

    # Flush and close the sink. Idempotent.
    # @return [nil]
    def close
      @native.close
      nil
    end
  end
end
