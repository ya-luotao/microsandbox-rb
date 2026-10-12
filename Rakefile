# frozen_string_literal: true

require "bundler/gem_tasks"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("microsandbox-rb.gemspec")

RbSys::ExtensionTask.new("microsandbox_rb", GEMSPEC) do |ext|
  ext.lib_dir = "lib/microsandbox"
end

begin
  require "rspec/core/rake_task"
  # Unit specs; integration specs require a real runtime and are opt-in via
  # MICROSANDBOX_INTEGRATION=1 (see spec/spec_helper.rb).
  RSpec::Core::RakeTask.new("spec:unit") do |t|
    t.pattern = "spec/unit/**/*_spec.rb"
  end

  # The fake-runtime specs drive the real native extension against a fake `msb`
  # (spec/support/fake_runtime). They point MSB_PATH at that fake for the whole
  # process, which would break the unit specs that assert what happens when no
  # runtime can be found — so they get an rspec process of their own.
  RSpec::Core::RakeTask.new("spec:fake_runtime") do |t|
    t.pattern = "spec/fake_runtime/**/*_spec.rb"
  end

  # The default: both of the above, as two processes.
  desc "Run the unit specs, then the fake-runtime specs (separate processes)"
  task spec: %w[spec:unit spec:fake_runtime]

  # Everything in one process. The fake-runtime specs skip themselves here
  # (see spec/fake_runtime/fake_runtime_helper.rb); run `rake spec` for them.
  RSpec::Core::RakeTask.new("spec:all") do |t|
    t.pattern = "spec/**/*_spec.rb"
  end
rescue LoadError
  # rspec not installed (e.g. production install); skip test tasks.
end

begin
  require "standard/rake"
  # Adds `rake standard` (lint) and `rake standard:fix` (autocorrect) for the
  # Ruby layer (lib/, spec/). Rust formatting/linting stays with cargo fmt/clippy.
rescue LoadError
  # standard not installed (e.g. production install); skip lint task.
end

task "spec:unit" => :compile
task "spec:fake_runtime" => :compile
task default: %i[compile spec]
