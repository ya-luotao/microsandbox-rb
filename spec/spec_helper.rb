# frozen_string_literal: true

require "microsandbox"
require "rspec/retry"

# Matches ONLY the transient "timed out waiting for agent relay" boot failure so
# rspec-retry can be scoped to it (see the :integration around hook below).
#
# The relay timeout surfaces as a *base* Microsandbox::Error — upstream's
# `MicrosandboxError::Runtime` variant has no typed subclass, so
# ext/microsandbox/src/error.rs maps it to the base class — and every typed
# runtime error (image-pull, cleanup, SSH, FS, …) also inherits from that base.
# Retrying on the class alone would therefore also swallow those intermittent
# failures and mask real regressions, so we match on the message instead.
#
# A Module (not a lambda or plain object) is required: rspec-retry checks
# `exception.is_a?(klass) || klass === exception` (rspec/retry.rb), and `is_a?`
# raises TypeError unless its argument is a Module. is_a? against a Module the
# exception doesn't mix in just returns false, then our `===` does the message
# check.
module RelayTimeoutRetry
  MESSAGE = "timed out waiting for agent relay"

  def self.===(exception)
    exception.is_a?(Microsandbox::Error) && exception.message.to_s.include?(MESSAGE)
  end
end

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Integration specs boot real microVMs. On GitHub-hosted nested KVM the boot
  # latency has a long tail: a microVM occasionally exceeds the upstream 180s
  # agent-relay deadline and the example fails with a transient relay timeout.
  # The failing example is random run-to-run — the signature of environment
  # flakiness, not a spec bug — so retry just that one failure (RelayTimeoutRetry
  # above; scoped to the message so other intermittent runtime errors are NOT
  # swallowed). Unit specs get no retry (no around hook below → rspec-retry's
  # single-try default), and assertion failures still fail on the first try.
  config.verbose_retry = true
  config.display_try_failure_messages = true
  config.exceptions_to_retry = [RelayTimeoutRetry]
  config.around(:each, :integration) do |example|
    example.run_with_retry retry: 3
  end

  # Integration specs require a real microsandbox runtime and the ability to
  # boot a microVM (Linux + KVM, or macOS Apple Silicon). They are opt-in:
  # run with MICROSANDBOX_INTEGRATION=1. Mirrors the Python SDK's conftest skip.
  config.before(:each, :integration) do
    unless ENV["MICROSANDBOX_INTEGRATION"]
      skip "set MICROSANDBOX_INTEGRATION=1 to run integration specs (boots real microVMs)"
    end
    unless Microsandbox.installed?
      skip "microsandbox runtime not installed (run Microsandbox.install)"
    end
  end
end

# A unique sandbox name per example, so parallel/interrupted runs don't collide.
def unique_sandbox_name(prefix = "rb-spec")
  "#{prefix}-#{Process.pid}-#{rand(1_000_000)}"
end

# Default OCI image for integration specs. Defaults to AWS's public ECR mirror
# of the Docker library: anonymous docker.io pulls are rate-limited (and fail
# with "Not authorized" in CI / unauthenticated environments), while the ECR
# mirror needs no auth and isn't throttled. Override with MICROSANDBOX_TEST_IMAGE.
def default_test_image
  ENV.fetch("MICROSANDBOX_TEST_IMAGE", "public.ecr.aws/docker/library/alpine:latest")
end

# Block until a freshly-created sandbox's metrics slot is live, returning the
# first successful Metrics snapshot. The per-sandbox metrics slot goes live a
# beat AFTER Sandbox.create returns on the v0.6.1 runtime — the spawn handshake
# (upstream #1036) no longer blocks create until the first sample is written, so
# `metrics`/`metrics_stream` briefly raise "sandbox N has no live metrics slot"
# right after boot. Poll past that startup window so streaming assertions don't
# race it; this mirrors how a real caller must treat the window (see the metrics
# docs). Only the transient slot error is retried — any other error propagates.
def wait_for_metrics_slot(sandbox, attempts: 50, delay: 0.1)
  attempts.times do
    return sandbox.metrics
  rescue Microsandbox::Error => e
    raise unless e.message.include?("no live metrics slot")
    sleep delay
  end
  raise "metrics slot never went live after #{attempts} attempts"
end
