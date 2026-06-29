# frozen_string_literal: true

# Real microVM integration coverage for the lifecycle-control and streaming
# surface added on top of the initial release. Opt-in via MICROSANDBOX_INTEGRATION=1.
RSpec.describe "lifecycle controls + streaming", :integration do
  let(:image) { default_test_image }

  describe "async lifecycle" do
    it "owns_lifecycle? is true and a handle's wait_until_stopped reports a terminal result" do
      sb = Microsandbox::Sandbox.create(unique_sandbox_name, image: image)
      begin
        expect(sb.owns_lifecycle?).to be(true)
        # The fine-grained request_*/wait_until_stopped controls live on the
        # controllable SandboxHandle (v0.5.8 lifecycle split), not the live object.
        handle = Microsandbox::Sandbox.get(sb.name)
        handle.request_stop
        result = handle.wait_until_stopped
        expect(result).to be_a(Microsandbox::SandboxStopResult)
        expect(result.status).to be_a(Symbol)
        expect(result.observed_at).to be_a(Time)
      ensure
        # The sandbox is already stopped by wait_until_stopped; a best-effort
        # kill here just guards against an early failure leaving it running.
        begin
          sb.kill
        rescue Microsandbox::Error
          # ignore stop/kill failures during teardown
        end
      end
    end

    it "filters sandboxes by label via list_with" do
      name = unique_sandbox_name
      sb = Microsandbox::Sandbox.create(name, image: image, labels: {role: "rb-itest"})
      begin
        names = Microsandbox::Sandbox.list_with(labels: {role: "rb-itest"}).map(&:name)
        expect(names).to include(name)
        # A non-matching filter must exclude it.
        other = Microsandbox::Sandbox.list_with(labels: {role: "nope"}).map(&:name)
        expect(other).not_to include(name)
      ensure
        sb.stop
      end
    end
  end

  describe "metrics" do
    it "exposes all_sandbox_metrics keyed by name" do
      name = unique_sandbox_name
      Microsandbox::Sandbox.create(name, image: image) do |sb|
        sb.exec("true")
        # Wait out the post-create metrics-slot startup window so the new sandbox
        # actually appears in the registry snapshot. Without it, all.key?(name) is
        # false during the ~0.2-0.5s window on the v0.6.1 runtime and the
        # assertion below would silently no-op (passing green having asserted
        # nothing). See wait_for_metrics_slot.
        wait_for_metrics_slot(sb)
        all = Microsandbox.all_sandbox_metrics
        expect(all).to be_a(Hash)
        # The running sandbox must now appear with a Metrics snapshot.
        expect(all[name]).to be_a(Microsandbox::Metrics)
      end
    end

    it "streams metrics snapshots" do
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
        # Wait out the post-create metrics-slot startup window before opening the
        # stream: the stream's first tick fires immediately and would otherwise
        # race the slot (and a single-pass stream can't be re-iterated once that
        # first tick errors). See wait_for_metrics_slot.
        wait_for_metrics_slot(sb)
        snapshot = sb.metrics_stream(interval: 0.2).first
        expect(snapshot).to be_a(Microsandbox::Metrics)
        expect(snapshot.uptime_secs).to be >= 0
      end
    end
  end

  describe "log streaming" do
    it "streams historical log entries without follow" do
      Microsandbox::Sandbox.create(unique_sandbox_name, image: image) do |sb|
        sb.exec("sh", ["-c", "echo log-line-marker"])
        entries = sb.log_stream(sources: %i[stdout output], follow: false).first(50)
        text = entries.map(&:text).join
        expect(text).to include("log-line-marker")
      end
    end
  end
end
