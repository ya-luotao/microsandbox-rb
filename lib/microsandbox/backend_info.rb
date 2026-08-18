# frozen_string_literal: true

module Microsandbox
  # Secret-safe description of the active default backend, from
  # {Microsandbox.default_backend_info} (runtime v0.6.9). Describes what
  # selected the backend and where it points — never its credential: the API
  # key is deliberately absent.
  class BackendInfo
    # @return [String, nil] effective cloud API endpoint (nil for local)
    attr_reader :api_url
    # @return [String, nil] the selected profile name, when a profile chose
    #   the backend
    attr_reader :profile

    def initialize(data)
      @kind = data["kind"]
      @api_url = data["api_url"]
      @source = data["source"]
      @profile = data["profile"]
    end

    # @return [Symbol] :local or :cloud
    def kind
      @kind.to_sym
    end

    # What selected this backend: `:programmatic` (an SDK setter),
    # `:MSB_BACKEND` / `:MSB_API_KEY` / `:MSB_PROFILE` (environment),
    # `:profile` (an explicit SDK profile constructor), `:active_profile`
    # (the SDK config file), or `:default` (the final local fallback).
    # @return [Symbol]
    def source
      @source.to_sym
    end

    def local? = kind == :local

    def cloud? = kind == :cloud

    def inspect
      "#<Microsandbox::BackendInfo kind=#{@kind} source=#{@source.inspect}" \
        "#{" api_url=#{@api_url.inspect}" if @api_url}" \
        "#{" profile=#{@profile.inspect}" if @profile}>"
    end
  end
end
