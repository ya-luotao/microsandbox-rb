# frozen_string_literal: true

# Child process for spec/integration/runtime_bootstrap_spec.rb: one bootstrap
# scenario per process, because the runtime home, MSB_PATH and the SDK path
# slots are all captured once per process.
#
# Usage: ruby -I lib bootstrap_probe.rb '<json config>'
#
#   {"image": "...",              # what every attempt creates from
#    "attempts": [{...}, ...],    # create kwargs, one Sandbox.create each
#    "list_first": true,          # Sandbox.list before the first create
#    "stub_installers": true}     # any installer call aborts the process
#
# Prints one JSON line: each attempt's outcome and the runtime_info at the end.
require "json"
require "microsandbox"

config = JSON.parse(ARGV.fetch(0))

if config["stub_installers"]
  Microsandbox.define_singleton_method(:install) { |**| abort "INSTALLER CALLED: Microsandbox.install" }
  Microsandbox::Native.define_singleton_method(:install_runtime) { |*| abort "INSTALLER CALLED: Native.install_runtime" }
end

def describe_runtime
  info = Microsandbox.runtime_info
  {"origin" => info.origin.to_s, "msb_path" => info.msb_path, "libkrunfw_path" => info.libkrunfw_path,
   "version" => info.version}
rescue Microsandbox::Error => e
  {"error_class" => e.class.name, "message" => e.message}
end

report = {"attempts" => []}
report["listed"] = Microsandbox::Sandbox.list.size if config["list_first"]
config.fetch("attempts").each_with_index do |opts, i|
  name = "bs-#{Process.pid}-#{i}"
  attempt = {}
  begin
    Microsandbox::Sandbox.create(name, image: config.fetch("image"), **opts.transform_keys(&:to_sym)) do |sandbox|
      attempt["echo"] = sandbox.exec("echo", ["ok"]).stdout
    end
    attempt["outcome"] = "created"
  rescue Microsandbox::Error => e
    attempt.merge!("outcome" => "error", "error_class" => e.class.name, "message" => e.message)
  ensure
    begin
      Microsandbox::Sandbox.remove(name)
    rescue Microsandbox::Error
      # never created, or already gone
    end
  end
  report["attempts"] << attempt
end
report["runtime"] = describe_runtime
puts JSON.generate(report)
