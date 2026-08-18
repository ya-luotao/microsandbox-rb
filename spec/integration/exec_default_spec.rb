# frozen_string_literal: true

# Real microVM integration coverage for v0.6.9 default-workload execution:
# create is strictly boot-only, and exec_default runs the image's resolved
# ENTRYPOINT+CMD (with cmd: overriding the durable image CMD).
# Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "default-workload execution", :integration do
  let(:image) { default_test_image }

  it "runs the cmd:-overridden default workload via exec_default" do
    Microsandbox::Sandbox.create(
      unique_sandbox_name("rb-execdefault"), image: image, memory: 512,
      cmd: ["echo", "hello from default workload"]
    ) do |sb|
      out = sb.exec_default(timeout: 60)
      expect(out).to be_success
      expect(out.stdout).to include("hello from default workload")
    end
  end

  it "streams the default workload via exec_default_stream" do
    Microsandbox::Sandbox.create(
      unique_sandbox_name("rb-execdefstream"), image: image, memory: 512,
      cmd: ["sh", "-c", "echo line1; echo line2"]
    ) do |sb|
      events = sb.exec_default_stream.to_a
      text = events.select(&:stdout?).map(&:text).join
      expect(text).to include("line1").and include("line2")
      expect(events.find(&:exited?).code).to eq(0)
    end
  end

  it "raises NoDefaultCommandError when the CMD is explicitly cleared" do
    Microsandbox::Sandbox.create(
      unique_sandbox_name("rb-nodefault"), image: image, memory: 512,
      cmd: [], entrypoint: []
    ) do |sb|
      expect { sb.exec_default }.to raise_error(Microsandbox::NoDefaultCommandError)
    end
  end
end
