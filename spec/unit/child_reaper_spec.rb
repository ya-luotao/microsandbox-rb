# frozen_string_literal: true

require "fileutils"
require "tmpdir"

RSpec.describe Microsandbox::ChildReaper do
  # A fake /proc: one directory per pid with a `stat` line, plus the parent's
  # task/<tid>/children list.
  def fake_proc(dir, parent:, procs:)
    FileUtils.mkdir_p(File.join(dir, parent.to_s, "task", parent.to_s))
    File.write(File.join(dir, parent.to_s, "task", parent.to_s, "children"), procs.keys.join(" ") + " ")
    procs.each do |pid, (comm, state, ppid)|
      FileUtils.mkdir_p(File.join(dir, pid.to_s))
      File.write(File.join(dir, pid.to_s, "stat"), "#{pid} (#{comm}) #{state} #{ppid} 1 1 0 -1 4194560 0 0\n")
    end
  end

  describe ".vm_comm?" do
    it "matches the names a sandbox VM process carries" do
      expect(described_class.vm_comm?("libkrun VM")).to be(true)
      expect(described_class.vm_comm?("VM:sandbox-1")).to be(true)
      expect(described_class.vm_comm?("msb")).to be(true)
    end

    it "leaves other children alone" do
      expect(described_class.vm_comm?("git")).to be(false)
      expect(described_class.vm_comm?("msb-helper")).to be(false)
      expect(described_class.vm_comm?("python3")).to be(false)
    end
  end

  describe ".vm_zombie_children" do
    it "lists only zombie VM processes whose parent is this process" do
      Dir.mktmpdir do |dir|
        fake_proc(dir, parent: 100, procs: {
          101 => ["libkrun VM", "Z", 100], # exited VM: collect
          102 => ["libkrun VM", "S", 100], # running VM: leave
          103 => ["git", "Z", 100],        # the application's own child: leave
          104 => ["VM:host (1)", "Z", 100], # parentheses in comm still parse
          105 => ["msb", "Z", 1]           # reparented elsewhere: leave
        })
        expect(described_class.vm_zombie_children(proc_root: dir, parent: 100)).to contain_exactly(101, 104)
      end
    end

    it "falls back to scanning every pid when the children list is missing" do
      Dir.mktmpdir do |dir|
        fake_proc(dir, parent: 100, procs: {201 => ["msb", "Z", 100], 202 => ["msb", "Z", 7]})
        FileUtils.rm_rf(File.join(dir, "100", "task"))
        expect(described_class.vm_zombie_children(proc_root: dir, parent: 100)).to eq([201])
      end
    end

    it "returns nothing when /proc is unreadable" do
      expect(described_class.vm_zombie_children(proc_root: "/nonexistent-proc", parent: 100)).to eq([])
    end
  end

  describe ".enabled?" do
    around do |example|
      saved = ENV[described_class::DISABLE_ENV]
      example.run
    ensure
      saved.nil? ? ENV.delete(described_class::DISABLE_ENV) : ENV[described_class::DISABLE_ENV] = saved
    end

    it "is off when MICROSANDBOX_NO_CHILD_REAPER is set" do
      ENV[described_class::DISABLE_ENV] = "1"
      expect(described_class.enabled?).to be(false)
      expect(described_class.ensure_started).to be(false)
    end

    it "is on for Linux only" do
      ENV.delete(described_class::DISABLE_ENV)
      expect(described_class.enabled?).to eq(RUBY_PLATFORM.include?("linux"))
    end
  end

  # Real zombies, so Linux only. A symlink named `msb` gives the child the VM's
  # `comm`, and a plain `Process.spawn` is never waited for, so the child
  # stays <defunct> after it exits.
  describe ".reap_once", if: RUBY_PLATFORM.include?("linux") do
    def spawn_zombie(dir, name)
      link = File.join(dir, name)
      File.symlink(File.realpath(`command -v true`.strip), link) unless File.exist?(link)
      pid = Process.spawn(link)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      until described_class.send(:read_stat, "/proc", pid)&.dig(:state) == "Z"
        raise "child #{pid} did not exit" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep 0.01
      end
      pid
    end

    it "collects a VM zombie only after the grace period" do
      Dir.mktmpdir do |dir|
        pid = spawn_zombie(dir, "msb")
        expect(described_class.reap_once(now: 1000.0)).to eq([])
        expect(File.exist?("/proc/#{pid}")).to be(true)
        expect(described_class.reap_once(now: 1000.0 + described_class::GRACE)).to eq([pid])
        expect(File.exist?("/proc/#{pid}")).to be(false)
      end
    end

    it "never collects a zombie that is not a VM process" do
      Dir.mktmpdir do |dir|
        pid = spawn_zombie(dir, "app-child")
        described_class.reap_once(now: 2000.0)
        expect(described_class.reap_once(now: 2000.0 + described_class::GRACE)).to eq([])
        expect(Process.waitpid(pid, Process::WNOHANG)).to eq(pid)
      end
    end

    it "ignores a zombie someone else collected first" do
      Dir.mktmpdir do |dir|
        pid = spawn_zombie(dir, "msb")
        described_class.reap_once(now: 3000.0)
        Process.waitpid(pid)
        expect(described_class.reap_once(now: 3000.0 + described_class::GRACE)).to eq([])
      end
    end
  end
end
