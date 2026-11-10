# frozen_string_literal: true

require_relative "fake_runtime_helper"
require "digest"
require "open3"
require "rbconfig"

# The cleanup that a block form (or an interrupted create) runs on exit must
# return within its budgets even when another process holds the sandbox's
# transition lock. Runtime v0.7.14's `kill` waits for that lock without a
# deadline, so the gem bounds the whole kill natively; these examples hold
# the lock in a child process past every budget and time the caller.
RSpec.describe "bounded cleanup under a held transition lock", :fake_runtime do
  # Holds an exclusive flock on ARGV[0] until its stdin closes or ARGV[1]
  # seconds pass. The second bound is the watchdog: a regression that waits
  # for the lock becomes a failed elapsed-time assertion, not a hung run.
  holder = <<~RUBY
    f = File.open(ARGV[0], File::RDWR | File::CREAT, 0o600)
    f.flock(File::LOCK_EX)
    $stdout.puts "locked"
    $stdout.flush
    IO.select([$stdin], nil, nil, Float(ARGV[1]))
  RUBY
  let(:holder_script) { holder }
  let(:watchdog) { 20 }
  let(:margin) { 3 }

  def lock_path(name)
    File.join(ENV.fetch("MSB_HOME"), "run", "creation-locks", "#{Digest::SHA256.hexdigest(name)[0, 32]}.lock")
  end

  def now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  # Take the name's transition lock in another process; released by
  # `release_lock` (in `after`, so only once the caller has returned).
  def hold_lock(name)
    @holder_in, @holder_out, @holder_err, @holder = Open3.popen3(RbConfig.ruby, "-e", holder_script, lock_path(name), watchdog.to_s)
    expect(@holder_out.gets&.strip).to eq("locked")
  end

  after do
    next unless @holder
    @holder_in.close unless @holder_in.closed?
    @holder.join(watchdog)
    [@holder_out, @holder_err].each(&:close)
  end

  def run_block_form(name)
    started = nil
    error = nil
    stderr = capture_stderr do
      Microsandbox::Sandbox.create(name, image: FakeRuntime.rootfs) do
        hold_lock(name)
        started = now
        raise "original block exception"
      end
    rescue => e
      error = e
    end
    [error, now - started, stderr]
  end

  def capture_stderr
    original = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = original
  end

  it "returns the block's exception within the stop and kill budgets (zero stop budget)" do
    stub_const("Microsandbox::Sandbox::BLOCK_STOP_TIMEOUT", 0)
    stub_const("Microsandbox::Sandbox::BLOCK_KILL_TIMEOUT", 1)

    error, elapsed, stderr = run_block_form("cleanup-lock-zero")

    expect(error).to be_a(RuntimeError)
    expect(error.message).to eq("original block exception")
    expect(elapsed).to be < 1 + margin
    expect(stderr).to include('cleanup gave up on sandbox "cleanup-lock-zero", which may still be running')
    expect(stderr.scan("cleanup gave up").size).to eq(1)
  end

  # A non-zero stop budget makes the graceful stop wait on the lock too: its
  # bound is upstream's single deadline over locks, dispatch and observation.
  it "bounds a graceful stop that waits on the lock, then the kill" do
    stub_const("Microsandbox::Sandbox::BLOCK_STOP_TIMEOUT", 1)
    stub_const("Microsandbox::Sandbox::BLOCK_KILL_TIMEOUT", 1)

    error, elapsed, stderr = run_block_form("cleanup-lock-stop")

    expect(error.message).to eq("original block exception")
    expect(elapsed).to be >= 1
    expect(elapsed).to be < 2 + margin
    expect(stderr).to include('cleanup gave up on sandbox "cleanup-lock-stop"')
  end

  # The interrupted-create path hands the native object, not the Ruby
  # wrapper, to the same cleanup.
  it "bounds the cleanup of a create that fails before the sandbox is handed over" do
    stub_const("Microsandbox::Sandbox::BLOCK_STOP_TIMEOUT", 0)
    stub_const("Microsandbox::Sandbox::BLOCK_KILL_TIMEOUT", 1)
    name = "cleanup-lock-native"
    started = nil
    allow(Microsandbox::Sandbox).to receive(:new) do |native|
      expect(native).to be_a(Microsandbox::Native::Sandbox)
      hold_lock(name)
      started = now
      raise "handover failed"
    end

    error = nil
    stderr = capture_stderr do
      Microsandbox::Sandbox.create(name, image: FakeRuntime.rootfs)
    rescue => e
      error = e
    end

    expect(error.message).to eq("handover failed")
    expect(now - started).to be < 1 + margin
    expect(stderr).to include(%(cleanup gave up on sandbox "#{name}"))
  end

  it "keeps kill_with_timeout's budget over the transition lock" do
    name = "cleanup-lock-public"
    sandbox = Microsandbox::Sandbox.create(name, image: FakeRuntime.rootfs)
    hold_lock(name)
    started = now
    expect { sandbox.kill_with_timeout(1) }
      .to raise_error(Microsandbox::Error, /timed out killing sandbox '#{name}' within 1\.000s/)
    expect(now - started).to be < 1 + margin
  end
end
