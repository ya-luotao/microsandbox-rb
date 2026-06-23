# frozen_string_literal: true

module Microsandbox
  # Gem version. Versioned independently of the upstream microsandbox runtime it
  # embeds: the gem follows its own semver (while 0.x, breaking changes bump the
  # minor and fixes bump the patch), so the number does NOT track the upstream tag
  # one-to-one. Consult {RUNTIME_VERSION} for the wrapped runtime, and the
  # Versioning section of the README for the full gem-to-runtime map. Must equal
  # the native ext's Cargo crate version (`Native.version`), enforced by
  # spec/unit/version_spec.rb.
  VERSION = "0.6.0"

  # The upstream microsandbox runtime release this gem build embeds — the `tag`
  # pinned on the `microsandbox`/`microsandbox-network` git deps in
  # ext/microsandbox/Cargo.toml. Exposed at runtime as
  # {Microsandbox.runtime_version}. spec/unit/version_spec.rb asserts it stays in
  # sync with the Cargo tag so it can't silently drift out of date.
  RUNTIME_VERSION = "v0.5.8"
end
