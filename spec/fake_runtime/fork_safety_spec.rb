# frozen_string_literal: true

require_relative "fake_runtime_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# A live Sandbox handle across a fork, against the real native extension and
# the fake `msb`: the forked child is refused the inherited handle, can open
# its own by name, and leaving the child (which frees the inherited native
# Sandbox) does not tear the parent's sandbox down. spec/unit/fork_safety_spec.rb
# covers the backend half without any runtime; spec/integration has the same
# scenario against a real microVM.
RSpec.describe "a sandbox handle across fork", :fake_runtime do
  it "is refused in the child, which opens its own; the parent's sandbox is untouched" do
    Dir.mktmpdir("msb-rb-", "/tmp") do |home|
      name = unique_sandbox_name("fr-fork")
      script = File.expand_path("../support/fake_runtime/fork_sandbox.rb", __dir__)
      env = {"MSB_HOME" => home, "MSB_PATH" => nil, "MSB_LIBKRUNFW_PATH" => nil, "FAKE_RELAY_LOG" => nil}
      out, err, status = Open3.popen3(env, RbConfig.ruby, "-I", File.expand_path("../../lib", __dir__), script, home, name) do |stdin, stdout, stderr, waiter|
        stdin.close
        unless waiter.join(60)
          Process.kill("KILL", waiter.pid)
          waiter.join
          raise "fork probe did not finish within 60s (killed): #{stderr.read}"
        end
        [stdout.read, stderr.read, waiter.value]
      end
      expect(status).to be_success, "probe failed: #{err}\n#{out}"
      report = JSON.parse(out.lines.last)
      child = report.fetch("child")
      expect(child).not_to be_nil, "the forked child died before reporting\n#{out}\n#{err}"

      # Plain data stays readable; anything that acts on the sandbox is refused.
      expect(child["name"]).to eq(name)
      %w[exec stop].each do |call|
        expect(child[call]).to include("error" => "Microsandbox::ForkedHandleError"), out
        expect(child[call]["message"]).to include("Microsandbox::Sandbox")
          .and include("created in process #{report["parent_pid"]}")
          .and include("forked process #{child["pid"]}")
      end

      # The child's own view of the same sandbox works, at once.
      expect(child["listed"]).to include(name)
      expect(child["list_seconds"]).to be < 2.0
      expect(child["own_exec"]).to eq("from the child\n")

      # The child left through a normal exit, freeing the inherited handle,
      # and the parent's sandbox neither noticed nor stopped.
      expect(report).to include("child_exit" => 0, "child_signal" => nil), "#{out}\n#{err}"
      expect(report["untouched_after_child"]).to be(true), out
      expect(report["parent_exec_after"]).to eq("after\n")
      expect(report).to include("parent_stop" => "stopped", "relay_gone_after_stop" => true, "shutdown_seen" => true)
    end
  end
end
