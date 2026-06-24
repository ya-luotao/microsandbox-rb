# frozen_string_literal: true

require "microsandbox"
require "rspec/retry"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Integration specs boot real microVMs. On GitHub-hosted nested KVM the boot
  # latency has a long tail: a microVM occasionally exceeds the upstream 180s
  # agent-relay deadline and fails with a transient
  # "timed out waiting for agent relay" (a Microsandbox::Error). The failing
  # example is random run-to-run — the signature of environment flakiness, not a
  # spec bug. Retry such examples a few times; unit specs get no retry (no
  # around hook below → rspec-retry's default of a single try). Restricting
  # exceptions_to_retry to Microsandbox::Error means a microVM that loses the
  # boot lottery is re-attempted while assertion failures and real runtime
  # errors still fail on the first try.
  config.verbose_retry = true
  config.display_try_failure_messages = true
  config.exceptions_to_retry = [Microsandbox::Error]
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
