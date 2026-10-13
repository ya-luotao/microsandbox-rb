# frozen_string_literal: true

require "json"
require "rbconfig"
require "timeout"
require "tmpdir"
require "fileutils"

# Fork safety against the REAL native extension. `fork(2)` copies only the
# calling thread, so a child of a process that used the SDK inherits a tokio
# runtime, a backend and handles whose threads are gone. Before the fix the
# child's first catalog read waited out the 30 s pool timeout on Linux and died
# with SIGTRAP on macOS; merely replacing the inherited backend did the same.
#
# The rspec process itself has used the SDK and must never fork, so every
# example runs spec/support/fork_probe.rb in a process of its own, with a home
# of its own, and reads the JSON lines it prints. Volumes only: catalog reads
# and writes need no `msb`, so nothing is provisioned.
RSpec.describe "fork safety (subprocess)" do
  root = File.expand_path("../..", __dir__)
  probe = File.join(root, "spec", "support", "fork_probe.rb")

  # A catalog call against a fresh pool takes milliseconds. The bug costs 30 s.
  let(:instant) { 2.0 }

  # Run one probe scenario; returns {steps: {name => line}, status:, out:, err:}.
  # The probe (and whatever it forked) is killed after 20 s: on Linux that, not
  # a crash, is what the unfixed extension looks like.
  def run_probe(scenario, root:, probe:, deadline: 20)
    home = Dir.mktmpdir("msb-fork-", File.directory?("/tmp") ? "/tmp" : nil)
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    env = {"MSB_HOME" => home, "MICROSANDBOX_NO_AUTO_INSTALL" => "1"}
    pid = Process.spawn(env, RbConfig.ruby, "-I", File.join(root, "lib"), probe, scenario,
      out: out_w, err: err_w, pgroup: true)
    out_w.close
    err_w.close
    readers = [out_r, err_r].map { |io| Thread.new { io.read } }
    _, status = begin
      Timeout.timeout(deadline) { Process.wait2(pid) }
    rescue Timeout::Error
      nil
    end
    # The whole process group: the probe's children hold the pipes open, and a
    # hung one would otherwise outlive the example.
    begin
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      # already gone
    end
    _, status = Process.wait2(pid) if status.nil?
    out, err = readers.map(&:value)
    steps = out.each_line.filter_map do |line|
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
    {steps: steps.to_h { |s| [s["step"], s] }, status: status, out: out, err: err}
  ensure
    [out_r, err_r].each { |io| io&.close }
    FileUtils.remove_entry(home, true) if home
  end

  def describe_run(run)
    "probe #{run[:status].inspect}\n--- stdout\n#{run[:out]}--- stderr\n#{run[:err]}"
  end

  # The probe finished on its own, and its forked child exited 0 through a
  # normal `exit` (which frees every wrapped native object on the way out).
  def expect_clean(run)
    expect(run[:status]).to be_success, describe_run(run)
    expect(run[:steps].fetch("child.status")).to include("ok" => true, "exit" => 0, "signal" => nil)
  end

  def expect_instant(run, *names)
    names.each do |name|
      step = run[:steps].fetch(name) { raise "probe never reported #{name}\n#{describe_run(run)}" }
      expect(step).to include("ok" => true), describe_run(run)
      expect(step["elapsed"]).to be < instant, "#{name} took #{step["elapsed"]}s"
    end
  end

  it "control: a child forked before any SDK use works" do
    run = run_probe("fresh", root: root, probe: probe)
    expect_clean(run)
    expect_instant(run, "child.list1", "child.list2")
  end

  it "a child forked after the parent used the backend reads the catalog at once" do
    run = run_probe("warm", root: root, probe: probe)
    expect_clean(run)
    expect_instant(run, "parent.warm", "child.list1", "child.list2")
  end

  it "leaves the parent working after its child has exited" do
    run = run_probe("warm", root: root, probe: probe)
    expect_clean(run)
    expect_instant(run, "parent.after")
  end

  it "refuses a handle inherited from the parent and survives destroying it" do
    run = run_probe("handle", root: root, probe: probe)
    expect_clean(run)

    refused = run[:steps].fetch("child.inherited")
    parent_pid = run[:steps].fetch("parent.create")["pid"]
    expect(refused).to include("ok" => false, "error" => "Microsandbox::ForkedHandleError")
    expect(refused["message"]).to include("Microsandbox::VolumeFs")
      .and include("created in process #{parent_pid}")
      .and include("forked process #{refused["pid"]}")
    expect(refused["pid"]).not_to eq(parent_pid)

    # The child's own handle sees what the parent wrote; so does the parent's,
    # still, once the child (which garbage-collected the inherited one) is gone.
    expect_instant(run, "child.own_fs", "child.list", "child.gc", "parent.after")
    expect(run[:steps]["child.own_fs"]["value"]).to eq("from the parent")
    expect(run[:steps]["child.list"]["value"]).to eq(1)
    expect(run[:steps]["parent.after"]["value"]).to eq("from the parent")
  end

  # On macOS destroying an inherited backend kills the process (on Linux it
  # happens to be harmless), so this is the example that fails there when a
  # forked child runs an inherited handle's destructor instead of leaking it.
  it "does not destroy a backend that only an inherited handle still owns" do
    run = run_probe("sole_owner", root: root, probe: probe)
    expect_clean(run)
    expect_instant(run, "child.list1", "child.gc", "parent.after")
  end

  it "lets a child close a with_backend scope its parent opened" do
    run = run_probe("with_backend", root: root, probe: probe)
    expect_clean(run)
    expect_instant(run, "child.close", "child.list1", "child.list2", "parent.close", "parent.after")
    expect(run[:steps]["child.kind"]).to include("ok" => true, "value" => "local")
  end

  it "keeps working in a grandchild" do
    run = run_probe("grandchild", root: root, probe: probe)
    expect_clean(run)
    expect(run[:steps].fetch("grandchild.status")).to include("ok" => true, "exit" => 0, "signal" => nil)
    expect_instant(run, "child.list1", "grandchild.list1", "grandchild.list2")
  end

  it "lets a child start by selecting a backend" do
    run = run_probe("select_first", root: root, probe: probe)
    expect_clean(run)
    expect_instant(run, "child.select", "child.list1", "parent.after")
  end

  # The parent's backend came from the environment ladder, which the child has
  # since broken (cloud selected, no credentials). Plain calls report that, and
  # keep reporting it; an explicit selection gets the child out regardless.
  it "lets a child select a backend when the inherited selection no longer resolves" do
    run = run_probe("select_recovers", root: root, probe: probe)
    expect_clean(run)
    expect(run[:steps].fetch("child.broken")).to include("ok" => false, "error" => "Microsandbox::InvalidConfigError")
    expect_instant(run, "child.select", "child.list1", "parent.after")
    expect(run[:steps]["child.kind"]).to include("ok" => true, "value" => "local")
  end

  # The backend a parent-opened scope should restore cannot be chosen again in
  # the child, and the child leaves the block by raising: the block's exception
  # is the one that propagates, the restore failure is a warning, and the
  # temporary backend stays selected (and usable).
  it "keeps the block's exception when a child cannot restore the scope's backend" do
    run = run_probe("scope_restore_fails", root: root, probe: probe)
    expect_clean(run)
    expect(run[:steps].fetch("child.block")).to include("ok" => false, "error" => "RuntimeError", "message" => "sentinel")
    expect(run[:err]).to include("with_backend could not restore the previous backend: ")
      .and include("MSB_BACKEND=cloud")
    expect(run[:steps]["child.kind"]).to include("ok" => true, "value" => "local")
    expect_instant(run, "child.list1", "parent.close", "parent.after")
  end
end
