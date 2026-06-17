# frozen_string_literal: true

require "bundler/gem_tasks"
require "rb_sys/extensiontask"

GEMSPEC = Gem::Specification.load("microsandbox-rb.gemspec")

RbSys::ExtensionTask.new("microsandbox_rb", GEMSPEC) do |ext|
  ext.lib_dir = "lib/microsandbox"
end

begin
  require "rspec/core/rake_task"
  RSpec::Core::RakeTask.new(:spec) do |t|
    # Unit specs by default; integration specs require a real runtime and are
    # opt-in via MICROSANDBOX_INTEGRATION=1 (see spec/spec_helper.rb).
    t.pattern = "spec/unit/**/*_spec.rb"
  end

  RSpec::Core::RakeTask.new("spec:all") do |t|
    t.pattern = "spec/**/*_spec.rb"
  end
rescue LoadError
  # rspec not installed (e.g. production install); skip test tasks.
end

task spec: :compile
task default: %i[compile spec]
