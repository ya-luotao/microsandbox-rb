# frozen_string_literal: true

source "https://rubygems.org"

# Declare gem dependencies in microsandbox-rb.gemspec. The glob keeps Bundler's
# path source to the root gemspec: its default (`{,*,*/*}.gemspec`) would also
# evaluate binaries/microsandbox-rb-binaries.gemspec — the companion gem's spec —
# inside every `bundle exec` process, defining Microsandbox::Binaries there
# before the SDK has a chance to (not) find the gem. That gem is built and
# consumed only through its own Rakefile + `gem install`, never via this bundle.
gemspec glob: "{,*}.gemspec"

group :development do
  gem "rake", "~> 13.0"
  gem "rake-compiler", "~> 1.2"
  # Parses sig/microsandbox.rbs for spec/unit/rbs_contract_spec.rb and backs
  # `rbs -I sig validate` in CI. Held on the 3.x line; moving to rbs 4 is a
  # separate change (the Ruby 3.1 floor that forced the pin is gone in 0.18.0).
  gem "rbs", "~> 4.2"
  gem "rspec", "~> 3.13"
  # Retries only the :integration examples (see spec/spec_helper.rb) so a microVM
  # that loses the GitHub-hosted nested-KVM boot-latency lottery and trips the
  # upstream 180s agent-relay deadline is re-attempted instead of failing main CI.
  gem "rspec-retry", "~> 0.6"
  gem "standard", "~> 1.0"
end
