# frozen_string_literal: true

require "microsandbox"

RSpec.configure do |config|
  config.expect_with :rspec do |c|
    c.syntax = :expect
  end
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

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
