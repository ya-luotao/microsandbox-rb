# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"

# Fork safety against a real microVM (opt-in via MICROSANDBOX_INTEGRATION=1):
# a process that booted a sandbox forks; the child is refused the inherited
# handle, sees the sandbox in the catalog at once, boots and stops a sandbox of
# its own, and exits normally — after which the parent's sandbox still answers.
# The probe runs in a process of its own (spec/support/fork_sandbox_probe.rb).
RSpec.describe "fork safety with a live sandbox", :integration do
  it "refuses the inherited handle in the child and leaves the parent's sandbox running" do
    name = unique_sandbox_name("rb-fork")
    script = File.expand_path("../support/fork_sandbox_probe.rb", __dir__)
    lib = File.expand_path("../../lib", __dir__)
    out, err, status = Open3.popen3(RbConfig.ruby, "-I", lib, script, name, default_test_image) do |stdin, stdout, stderr, waiter|
      stdin.close
      streams = [stdout, stderr].map { |io| Thread.new { io.read } }
      unless waiter.join(600)
        Process.kill("KILL", waiter.pid)
        waiter.join
        raise "fork probe did not finish within 600s (killed): #{streams.last.value}"
      end
      [*streams.map(&:value), waiter.value]
    end
    expect(status).to be_success, "probe failed: #{err}\n#{out}"
    report = JSON.parse(out.lines.last)
    child = report.fetch("child")
    expect(child).not_to be_nil, "the forked child died before reporting\n#{out}\n#{err}"
    expect(report["parent_exec_before"]).to eq("before\n")

    expect(child["name"]).to eq(name)
    expect(child["exec"]).to include("error" => "Microsandbox::ForkedHandleError"), out
    expect(child["exec"]["message"]).to include("created in process #{report["parent_pid"]}")
      .and include("forked process #{child["pid"]}")

    expect(child["listed"]).to include(name)
    expect(child["list_seconds"]).to be < 2.0
    expect(child["own"]).to eq("from the child\n")
    expect(child["own_removed"]).to be(true)

    expect(report).to include("child_exit" => 0, "child_signal" => nil), "#{out}\n#{err}"
    expect(report["parent_exec_after"]).to eq("after\n")
    expect(report["parent_stop"]).to eq("stopped")
  end
end
