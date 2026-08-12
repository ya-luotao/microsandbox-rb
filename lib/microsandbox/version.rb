# frozen_string_literal: true

module Microsandbox
  # Gem version. Versioned independently of the upstream microsandbox runtime it
  # embeds: the gem follows its own semver (while 0.x, breaking changes bump the
  # minor and fixes bump the patch), so the number does NOT track the upstream tag
  # one-to-one. Consult {RUNTIME_VERSION} for the wrapped runtime, and the
  # Versioning section of the README for the full gem-to-runtime map. Must equal
  # the native ext's Cargo crate version (`Native.version`), enforced by
  # spec/unit/version_spec.rb.
  VERSION = "0.12.0"

  # The upstream microsandbox runtime release this gem build embeds — the base
  # of the `microsandbox`/`microsandbox-network` git deps pinned in
  # ext/microsandbox/Cargo.toml. Exposed at runtime as
  # {Microsandbox.runtime_version}. TEMPORARY: the deps are currently NOT
  # tag-pinned — they are rev-pinned to the ya-luotao/microsandbox fork's
  # `v0.6.8-digest-backport` branch (this base tag plus digest verification for
  # the runtime bundle and agentd downloads, backported from upstream #1300)
  # until equivalent verification ships in an upstream release tag.
  # spec/unit/version_spec.rb enforces the pin: either both deps carry an
  # official tag equal to this constant, or both carry the approved backport
  # rev recorded there.
  RUNTIME_VERSION = "v0.6.8"
end
