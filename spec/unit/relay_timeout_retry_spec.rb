# frozen_string_literal: true

# Locks the retry filter that spec/spec_helper.rb feeds to rspec-retry's
# exceptions_to_retry for :integration examples. The relay timeout is a base
# Microsandbox::Error (no typed subclass), so the filter MUST key on the message
# — keying on the class would also retry image-pull/cleanup/SSH/FS and other
# intermittent runtime errors and mask real regressions.
RSpec.describe RelayTimeoutRetry do
  describe ".===" do
    it "matches a base Microsandbox::Error carrying the relay-timeout message" do
      err = Microsandbox::Error.new(
        "runtime error: timed out waiting for agent relay: deadline has elapsed"
      )
      expect(RelayTimeoutRetry === err).to be(true)
    end

    it "does not match a base Microsandbox::Error with an unrelated message" do
      err = Microsandbox::Error.new("runtime error: something else went wrong")
      expect(RelayTimeoutRetry === err).to be(false)
    end

    it "does not match other intermittent typed runtime errors (e.g. image pull)" do
      err = Microsandbox::ImagePullFailedError.new("temporary registry hiccup")
      expect(RelayTimeoutRetry === err).to be(false)
    end

    it "does not match a non-microsandbox exception even if its message matches" do
      # Guards against retrying e.g. an assertion failure that happens to mention
      # the phrase: the class gate (is_a?(Microsandbox::Error)) must still hold.
      expect(RelayTimeoutRetry === RuntimeError.new("timed out waiting for agent relay")).to be(false)
    end
  end

  # rspec-retry evaluates `exception.is_a?(klass) || klass === exception`, so the
  # filter entry must survive is_a? without raising. is_a? against a Module the
  # exception doesn't mix in returns false (not TypeError), letting the `===`
  # message check run.
  it "is safe as an exceptions_to_retry entry: is_a? returns false rather than raising" do
    err = Microsandbox::Error.new("timed out waiting for agent relay")
    expect(err.is_a?(RelayTimeoutRetry)).to be(false)
  end
end
