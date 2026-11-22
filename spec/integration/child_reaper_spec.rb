# frozen_string_literal: true

# Real-VM check of Microsandbox::ChildReaper (upstream #1950): a stopped
# detached sandbox's VM child must not stay <defunct> in this process. Linux
# only; macOS reaps these children already.
RSpec.describe "Detached VM children on Linux", :integration, if: RUBY_PLATFORM.include?("linux") do
  let(:reaper) { Microsandbox::ChildReaper }

  def stat_of(pid)
    reaper.send(:read_stat, "/proc", pid)
  end

  def vm_children
    reaper.send(:child_pids, "/proc", Process.pid).select do |pid|
      (stat = stat_of(pid)) && stat[:ppid] == Process.pid && reaper.vm_comm?(stat[:comm])
    end
  end

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until yield
      return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.5
    end
    true
  end

  it "collects the VM child of a stopped detached sandbox" do
    before = vm_children
    sandbox = Microsandbox::Sandbox.create(unique_sandbox_name, image: default_test_image, detached: true)
    begin
      # The running VM is a direct child carrying a name the reaper matches.
      new_pids = vm_children - before
      expect(new_pids.size).to eq(1), "VM children before #{before.inspect}, after #{vm_children.inspect}"
      vm_pid = new_pids.first
    ensure
      sandbox.stop_with_timeout(30)
    end

    expect(reaper.running?).to be(true)
    # Exited, and then collected within one grace period plus two scans.
    budget = reaper::GRACE + (2 * reaper::INTERVAL) + 10
    collected = wait_until(budget) { stat_of(vm_pid).nil? }
    expect(collected).to be(true), "VM pid #{vm_pid} still present: #{stat_of(vm_pid).inspect}"
  end
end
