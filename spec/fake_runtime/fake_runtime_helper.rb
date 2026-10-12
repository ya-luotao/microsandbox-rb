# frozen_string_literal: true

require "spec_helper"
require_relative "../support/fake_runtime/fake_runtime"

# The fake-runtime specs drive the REAL native extension against a fake `msb`
# (spec/support/fake_runtime). Pointing the process at that fake means setting
# MSB_PATH / MSB_LIBKRUNFW_PATH for everything that runs afterwards, and
# spec/unit has examples that assert what happens when no runtime can be found
# — in random order. So these specs only activate when the rspec process runs
# nothing but spec/fake_runtime (`rake spec:fake_runtime`, which `rake spec`
# runs as a second process). In a mixed run (`rake spec:all`, bare `rspec`) and
# under MICROSANDBOX_INTEGRATION (where spec_helper keeps the real, non-isolated
# home) they skip instead of touching the environment.
module FakeRuntimeSpecs
  DIR = File.expand_path(__dir__) + File::SEPARATOR

  def self.skip_reason
    return "the fake runtime needs the isolated unit home; unset MICROSANDBOX_INTEGRATION" if ENV["MICROSANDBOX_INTEGRATION"]
    foreign = RSpec.configuration.files_to_run.reject { |f| File.expand_path(f).start_with?(DIR) }
    return nil if foreign.empty?
    "fake-runtime specs run in their own process: bundle exec rspec spec/fake_runtime"
  end

  SKIP_REASON = skip_reason
  # spec_helper already pointed MSB_HOME at a short, throwaway /tmp directory.
  FakeRuntime.setup! unless SKIP_REASON
end

RSpec.configure do |config|
  config.before(:each, :fake_runtime) do
    skip FakeRuntimeSpecs::SKIP_REASON if FakeRuntimeSpecs::SKIP_REASON
    # The runtime is the fake one; never let an example provision a real one.
    allow(Microsandbox).to receive(:ensure_runtime!)
  end

  config.after(:each, :fake_runtime) do
    FakeRuntime.kill_relays! unless FakeRuntimeSpecs::SKIP_REASON
  end
end
