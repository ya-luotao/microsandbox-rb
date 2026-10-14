# frozen_string_literal: true

require "json"
require "rbconfig"
require "timeout"
require "tmpdir"
require "fileutils"
require_relative "../support/wire_capture"

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
  def run_probe(scenario, root:, probe:, deadline: 20, env: {})
    home = Dir.mktmpdir("msb-fork-", File.directory?("/tmp") ? "/tmp" : nil)
    out_r, out_w = IO.pipe
    err_r, err_w = IO.pipe
    env = {"MSB_HOME" => home, "MICROSANDBOX_NO_AUTO_INSTALL" => "1"}.merge(env)
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

  # The scope's TEMPORARY backend (a cloud profile) cannot be chosen again in
  # the child, the one it restores can: leaving the block must not need the
  # former. Taking over with it first used to fail the restore and leave the
  # child raising the profile error on every call.
  it "lets a child leave a scope whose temporary backend it cannot rebuild" do
    run = run_probe("scope_selection_gone", root: root, probe: probe)
    expect_clean(run)
    expect(run[:steps]["parent.scoped"]).to include("ok" => true, "value" => "cloud")
    expect(run[:steps]["child.kind"]).to include("ok" => true, "value" => "local")
    expect_instant(run, "child.close", "child.list1", "parent.close", "parent.after")
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

  # A WORKING cloud backend across fork. The fake API (in this process, the
  # probe only talks to it) keeps connections alive, so the parent's client
  # holds an idle pooled connection when it forks, and that connection's driver
  # task belongs to the parent's runtime. A child that reused the inherited
  # client would hand its request to that pooled connection and wait out the
  # 30 s request timeout (past the 20 s deadline here), or put it on the
  # parent's socket; either fails below. Every step names the logged request
  # that served it (see WireCapture::KeepAliveCloudApi), so the examples assert
  # on which connection, with which API key, each process was answered.
  describe "with a cloud backend" do
    # The probe's environment: the fake API's URL, and no ambient proxy
    # (reqwest reads the proxy variables whenever a client is built, in the
    # child too), so loopback is reached directly.
    def cloud_env(api, extra = {})
      proxy = WireCapture::PROXY_ENV_VARS.to_h { |name| [name, nil] }
      proxy.merge("NO_PROXY" => "127.0.0.1,localhost", "no_proxy" => "127.0.0.1,localhost",
        "FORK_PROBE_CLOUD_URL" => api.url).merge(extra)
    end

    # The logged request that answered step +name+ (its listing names it).
    def served(run, api, name)
      step = run[:steps].fetch(name) { raise "probe never reported #{name}\n#{describe_run(run)}" }
      expect(step["value"]).to match([a_string_matching(/\Aseq-\d+\z/)]), "#{name}: #{step.inspect}"
      seq = step["value"].first.delete_prefix("seq-").to_i
      api.requests.find { |request| request[:seq] == seq } || raise("no logged request #{seq}")
    end

    def expect_only_listings(api, count)
      expect(api.requests.map { |request| request[:line] }).to eq(["GET /v1/volumes HTTP/1.1"] * count)
    end

    let(:api) { WireCapture::KeepAliveCloudApi.new }

    after { api.close }

    # The parent's warm connection, the child's own one, the parent again.
    def expect_fresh_child_connection(run, key:)
      expect_clean(run)
      expect_instant(run, "parent.warm", "child.list1", "child.list2", "parent.after")
      expect(run[:steps]["child.kind"]).to include("ok" => true, "value" => "cloud")
      warm, first, second, after = %w[parent.warm child.list1 child.list2 parent.after].map { |name| served(run, api, name) }

      expect([warm, first, second, after].map { |request| request[:key] }).to all(eq(key))
      expect_only_listings(api, 4)
      # The child reached the API over a connection of its own...
      expect(first[:conn]).not_to eq(warm[:conn])
      expect(first[:port]).not_to eq(warm[:port])
      # ...from a working pool of its own (it reused that connection)...
      expect(second[:conn]).to eq(first[:conn])
      # ...and the parent's pooled connection was still there for the parent.
      expect(after[:conn]).to eq(warm[:conn])
      expect(api.connections).to eq(2)
    end

    it "lets a child use a cloud backend selected with set_default_backend" do
      run = run_probe("cloud_selected", root: root, probe: probe, env: cloud_env(api))
      expect_fresh_child_connection(run, key: "k-selected")
    end

    it "lets a child use a cloud backend selected by the environment" do
      env = cloud_env(api, "MSB_BACKEND" => "cloud", "MSB_API_URL" => api.url, "MSB_API_KEY" => "k-env")
      run = run_probe("cloud_env", root: root, probe: probe, env: env)
      expect_fresh_child_connection(run, key: "k-env")
    end

    # The parent forks inside a with_backend(:cloud) block over a cloud
    # default, both warm. The child uses the scoped backend, closes the scope
    # (restoring the default, which it must rebuild) and uses the default.
    it "lets a child use and close a cloud with_backend scope its parent opened" do
      run = run_probe("cloud_with_backend", root: root, probe: probe, env: cloud_env(api))
      expect(run[:status]).to be_success, describe_run(run)
      expect(run[:steps].fetch("child.status")).to include("ok" => true, "exit" => 0, "signal" => nil)
      names = %w[parent.warm parent.scoped child.scoped child.close child.after
        parent.scoped_after parent.close parent.after]
      expect_instant(run, *names)
      warm, scoped, child_scoped, child_after, scoped_after, after =
        %w[parent.warm parent.scoped child.scoped child.after parent.scoped_after parent.after]
          .map { |name| served(run, api, name) }

      expect_only_listings(api, 6)
      expect([warm, child_after, after].map { |request| request[:key] }).to all(eq("k-outer"))
      expect([scoped, child_scoped, scoped_after].map { |request| request[:key] }).to all(eq("k-scoped"))
      # Neither of the child's backends used a connection of the parent's.
      parent_conns = [warm[:conn], scoped[:conn]]
      expect(parent_conns).not_to include(child_scoped[:conn], child_after[:conn])
      expect(child_after[:conn]).not_to eq(child_scoped[:conn])
      # The parent's two pooled connections still served it after the child.
      expect(scoped_after[:conn]).to eq(scoped[:conn])
      expect(after[:conn]).to eq(warm[:conn])
      expect(api.connections).to eq(4)
    end
  end
end
