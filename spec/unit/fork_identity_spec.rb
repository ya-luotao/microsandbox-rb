# frozen_string_literal: true

# Process identity for fork safety is the pid AND the fork generation
# (DESIGN.md, "Fork safety"). A real fork changes both, so the fork specs
# (fork_safety_spec.rb) cannot tell whether each half takes part, and pid
# reuse — the case the generation exists for — cannot be staged on demand.
# These examples feed chosen identities to the real comparisons through two
# spec-only diagnostics on Microsandbox::Native:
#
# * fork_identity_equal(pid_a, gen_a, pid_b, gen_b) => [equal, same_bits]:
#   ProcessIdentity's `==` (runtime cell, handles, with_backend scopes) and its
#   packed word (the backend record);
# * fork_identity_guard(born_pid, born_gen, cur_pid, cur_gen): the real
#   ForkGuarded ownership check — nil when allowed, else the
#   ForkedHandleError a handle would raise.
RSpec.describe "process identity (pid + fork generation)" do
  native = Microsandbox::Native
  max = 2**32 - 1

  def equal(a, b) = Microsandbox::Native.fork_identity_equal(*a, *b)

  def guard(born, cur) = Microsandbox::Native.fork_identity_guard(*born, *cur)

  it "is the same process only when both the pid and the generation match" do
    expect(equal([4242, 3], [4242, 3])).to eq([true, true])
    expect(guard([4242, 3], [4242, 3])).to be_nil
  end

  # The pid reuse case: a descendant the kernel handed its ancestor's pid.
  it "tells apart an equal pid with another generation" do
    [[0, 1], [1, 2], [0, max], [max, 0]].each do |born_gen, cur_gen|
      expect(equal([4242, born_gen], [4242, cur_gen])).to eq([false, false]), "generations #{born_gen}/#{cur_gen}"
    end
  end

  # A process created without the atfork handler (vfork, raw clone) keeps its
  # parent's generation; only the pid tells it apart.
  it "tells apart another pid with the same generation" do
    [[4242, 4243, 0], [1, max, 7], [4242, 4243, max]].each do |born_pid, cur_pid, gen|
      expect(equal([born_pid, gen], [cur_pid, gen])).to eq([false, false]), "pids #{born_pid}/#{cur_pid}"
    end
  end

  it "refuses a handle used under its creator's pid in a later generation, without naming two processes" do
    expect { guard([4242, 1], [4242, 2]) }.to raise_error(Microsandbox::ForkedHandleError) { |e|
      expect(e.message).to eq("Microsandbox::VolumeFs was created in an earlier process that also had pid 4242 " \
        "and cannot be used in this forked process; create a new handle after fork")
    }
  end

  it "refuses a handle used under another pid in the same generation, naming both pids" do
    expect { guard([4242, 1], [4243, 1]) }.to raise_error(Microsandbox::ForkedHandleError) { |e|
      expect(e.message).to include("created in process 4242")
        .and include("cannot be used in forked process 4243")
        .and include("the original keeps working in process 4242")
    }
  end

  it "rejects values that are not a pid or a generation" do
    expect { native.fork_identity_equal(-1, 0, 1, 0) }.to raise_error(RangeError)
    expect { native.fork_identity_equal(1, 2**32, 1, 0) }.to raise_error(RangeError)
  end
end
