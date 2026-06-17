# frozen_string_literal: true

# Real-microVM integration coverage for interactive attach. Opt-in via
# MICROSANDBOX_INTEGRATION=1, and additionally gated on a real controlling TTY:
# attach puts the host terminal in raw mode, so it cannot run headless (CI).
RSpec.describe "Sandbox#attach", :integration do
  let(:image) { default_test_image }

  before do
    skip "attach requires a real TTY on stdin/stdout" unless $stdin.tty? && $stdout.tty?
  end

  it "runs a non-interactive command to completion and returns its exit code" do
    Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
      # `true` exits 0 immediately without needing input, so it terminates the
      # attach session on its own even though a TTY is allocated.
      expect(sb.attach("true")).to eq(0)
      expect(sb.attach("sh", ["-c", "exit 7"])).to eq(7)
    end
  end
end
