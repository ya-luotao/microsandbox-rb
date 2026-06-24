# frozen_string_literal: true

source "https://rubygems.org"

# Declare gem dependencies in microsandbox-rb.gemspec
gemspec

group :development do
  gem "rake", "~> 13.0"
  gem "rake-compiler", "~> 1.2"
  gem "rspec", "~> 3.13"
  # Retries only the :integration examples (see spec/spec_helper.rb) so a microVM
  # that loses the GitHub-hosted nested-KVM boot-latency lottery and trips the
  # upstream 180s agent-relay deadline is re-attempted instead of failing main CI.
  gem "rspec-retry", "~> 0.6"
  gem "standard", "~> 1.0"
end
