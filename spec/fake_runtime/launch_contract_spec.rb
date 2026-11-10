# frozen_string_literal: true

require "open3"
require "tmpdir"
require_relative "fake_runtime_helper"

# The v0.7 launch contract, observed end to end through the real native
# extension: the core reads the runtime version from the msb executable, probes
# `msb __launch-protocol` for capabilities, refuses runtimes that lack one the
# sandbox needs, and launches `msb machine`. Each capability set runs in its own
# child process (launch_probe.rb), because the local backend captures the msb
# path once per process.
RSpec.describe "fake runtime: v0.7 launch contract", :fake_runtime do
  let(:probe_script) { File.expand_path("../support/fake_runtime/launch_probe.rb", __dir__) }
  let(:lib_dir) { File.expand_path("../../lib", __dir__) }

  def probe(variant, opts = {})
    Dir.mktmpdir("msb-rb-", File.realpath("/tmp")) do |home|
      name = unique_sandbox_name("fr-lc")
      env = {"MSB_HOME" => home, "MSB_PATH" => nil, "MSB_LIBKRUNFW_PATH" => nil, "FAKE_RELAY_LOG" => nil}
      out, err, status = Open3.capture3(env, RbConfig.ruby, "-I", lib_dir, probe_script, home, variant.to_s, name, JSON.generate(opts))
      expect(status).to be_success, "launch probe failed: #{err}\n#{out}"
      JSON.parse(out.lines.last).merge("name" => name)
    end
  end

  it "launches a runtime advertising the full contract as `msb machine`" do
    report = probe(:default)
    expect(report["outcome"]).to eq("created"), report.inspect
    expect(report["echo"]).to eq("ok\n")
    args = report.fetch("relay_args")
    expect(args.first).to eq("machine")
    expect(args.each_cons(2).to_a).to include(["--name", report["name"]])
    expect(args.each_cons(2).to_a).to include(["--config-fd", "96"])
    expect(args.each_cons(2).to_a).to include(["--lifecycle-lock-fd", "99"])
    expect(report["lifecycle_lock_fd"]).to eq("open"), "the runtime did not inherit its lifecycle lock"
  end

  it "refuses a runtime that does not advertise protected sandbox state (base Error)" do
    report = probe(:no_protected)
    expect(report["outcome"]).to eq("error"), report.inspect
    expect(report["error_class"]).to eq("Microsandbox::Error")
    expect(report["message"]).to include("does not advertise protected sandbox state")
    expect(report["relay_args"]).to be_nil, "the runtime was launched anyway: #{report.inspect}"
  end

  it "refuses the default (networked, JSON deny response) sandbox on a runtime without http_deny_json" do
    report = probe(:no_http_json)
    expect(report["outcome"]).to eq("error"), report.inspect
    expect(report["error_class"]).to eq("Microsandbox::UnsupportedError")
    expect(report["message"]).to include("network.http.deny_response")
    expect(report["relay_args"]).to be_nil
  end

  it "launches a networked sandbox on that runtime once http: {deny_response: false} opts out" do
    report = probe(:no_http_json, http: {deny_response: false})
    expect(report["outcome"]).to eq("created"), report.inspect
    expect(report["relay_args"].first).to eq("machine")
  end

  it "refuses http: {format: :text} on a runtime without http_deny_message (UnsupportedError)" do
    report = probe(:no_http_text, http: {format: "text"})
    expect(report["outcome"]).to eq("error"), report.inspect
    expect(report["error_class"]).to eq("Microsandbox::UnsupportedError")
    expect(report["message"]).to include("network.http.deny_response")
    expect(report["relay_args"]).to be_nil
  end

  it "still launches a network-disabled sandbox on that runtime (the capability is only needed with a network)" do
    report = probe(:no_http_json, network: "none")
    expect(report["outcome"]).to eq("created"), report.inspect
    expect(report["relay_args"].first).to eq("machine")
  end
end
