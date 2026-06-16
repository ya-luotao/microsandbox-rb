# frozen_string_literal: true

module Microsandbox
  # Metadata for a cached OCI image, from {Image.get} / {Image.list}.
  class ImageInfo
    attr_reader :reference, :size_bytes, :manifest_digest, :architecture, :os, :layer_count

    def initialize(data)
      @reference = data["reference"]
      @size_bytes = data["size_bytes"]
      @manifest_digest = data["manifest_digest"]
      @architecture = data["architecture"]
      @os = data["os"]
      @layer_count = data["layer_count"]
      @created_at_ms = data["created_at_ms"]
      @last_used_at_ms = data["last_used_at_ms"]
    end

    # @return [Time, nil]
    def created_at
      @created_at_ms && Time.at(@created_at_ms / 1000.0)
    end

    # @return [Time, nil]
    def last_used_at
      @last_used_at_ms && Time.at(@last_used_at_ms / 1000.0)
    end

    def inspect
      "#<Microsandbox::ImageInfo reference=#{@reference.inspect} layers=#{@layer_count}>"
    end
  end

  # Full inspection detail for a cached image, from {Image.inspect}.
  class ImageDetail
    # @return [ImageInfo]
    attr_reader :handle
    # @return [Hash, nil] OCI config (digest, env, cmd, entrypoint, working_dir, user, stop_signal)
    attr_reader :config
    # @return [Array<Hash>] layer descriptors
    attr_reader :layers

    def initialize(data)
      @handle = ImageInfo.new(data["handle"])
      @config = data["config"]
      @layers = data["layers"] || []
    end

    def reference = @handle.reference

    def inspect
      "#<Microsandbox::ImageDetail reference=#{@handle.reference.inspect} layers=#{@layers.size}>"
    end
  end

  # The result of {Image.prune}.
  class ImagePruneReport
    attr_reader :image_refs_removed, :manifests_removed, :layers_removed,
                :fsmeta_removed, :vmdk_removed, :bytes_reclaimed

    def initialize(data)
      @image_refs_removed = data["image_refs_removed"]
      @manifests_removed = data["manifests_removed"]
      @layers_removed = data["layers_removed"]
      @fsmeta_removed = data["fsmeta_removed"]
      @vmdk_removed = data["vmdk_removed"]
      @bytes_reclaimed = data["bytes_reclaimed"]
    end
  end

  # Management of the local OCI image cache. Images are pulled automatically by
  # {Sandbox.create}; this namespace lets you inspect and prune the cache.
  class Image
    class << self
      # All cached images.
      # @return [Array<ImageInfo>]
      def list
        Native::Image.list.map { |info| ImageInfo.new(info) }
      end

      # Metadata for one cached image.
      # @return [ImageInfo]
      def get(reference)
        ImageInfo.new(Native::Image.get(reference.to_s))
      end

      # Full inspection detail for a cached image. With no argument this is the
      # normal class `#inspect` (so object display still works).
      # @return [ImageDetail]
      def inspect(reference = nil)
        return super() if reference.nil?

        ImageDetail.new(Native::Image.inspect(reference.to_s))
      end

      # Remove a cached image.
      # @param force [Boolean] remove even if referenced
      # @return [nil]
      def remove(reference, force: false)
        Native::Image.remove(reference.to_s, force)
        nil
      end

      # Garbage-collect unreferenced images, manifests, and layers.
      # @return [ImagePruneReport]
      def prune
        ImagePruneReport.new(Native::Image.prune)
      end
    end
  end
end
