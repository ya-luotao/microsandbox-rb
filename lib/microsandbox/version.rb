# frozen_string_literal: true

module Microsandbox
  # Gem version. Tracks the upstream microsandbox runtime (currently `v0.5.7`,
  # the pinned core-crate tag); the patch segment advances for gem-only revisions
  # that add bindings atop the same core. Must equal the native ext's Cargo crate
  # version (`Native.version`), enforced by spec/unit/version_spec.rb.
  VERSION = "0.5.8"
end
