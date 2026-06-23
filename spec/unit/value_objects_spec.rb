# frozen_string_literal: true

RSpec.describe "value objects" do
  describe Microsandbox::ExecOutput do
    subject(:output) do
      described_class.new(
        "exit_code" => 0,
        "success" => true,
        "stdout" => "hello\n".b,
        "stderr" => "".b
      )
    end

    it "exposes exit_code and success?" do
      expect(output.exit_code).to eq(0)
      expect(output).to be_success
      expect(output).not_to be_failure
    end

    it "decodes stdout/stderr as UTF-8 and keeps raw bytes" do
      expect(output.stdout).to eq("hello\n")
      expect(output.stdout.encoding).to eq(Encoding::UTF_8)
      expect(output.stdout_bytes.encoding).to eq(Encoding::ASCII_8BIT)
      expect(output.to_s).to eq("hello\n")
    end

    it "reports failure for non-zero exit" do
      out = described_class.new("exit_code" => 1, "success" => false, "stdout" => "".b, "stderr" => "boom".b)
      expect(out).to be_failure
      expect(out.stderr).to eq("boom")
    end
  end

  describe Microsandbox::FsEntry do
    subject(:entry) do
      described_class.new(
        "path" => "/tmp/file.txt",
        "type" => "file",
        "size" => 42,
        "mode" => 0o644,
        "modified_ms" => 1_700_000_000_000
      )
    end

    it "parses fields and derives name/type predicates" do
      expect(entry.path).to eq("/tmp/file.txt")
      expect(entry.name).to eq("file.txt")
      expect(entry.type).to eq(:file)
      expect(entry).to be_file
      expect(entry).not_to be_directory
      expect(entry.size).to eq(42)
      expect(entry.modified).to be_a(Time)
    end

    it "treats missing modified as nil" do
      e = described_class.new("path" => "/d", "type" => "directory", "size" => 0, "mode" => 0o755, "modified_ms" => nil)
      expect(e.modified).to be_nil
      expect(e).to be_directory
    end
  end

  describe Microsandbox::FsMetadata do
    subject(:meta) do
      described_class.new(
        "type" => "symlink", "size" => 10, "mode" => 0o777,
        "readonly" => true, "modified_ms" => nil, "created_ms" => 1_700_000_000_000
      )
    end

    it "parses fields and predicates" do
      expect(meta.type).to eq(:symlink)
      expect(meta).to be_symlink
      expect(meta).to be_readonly
      expect(meta.created).to be_a(Time)
      expect(meta.modified).to be_nil
    end
  end

  describe Microsandbox::Metrics do
    subject(:metrics) do
      described_class.new(
        "cpu_percent" => 12.5, "vcpu_time_ns" => 1_000, "memory_bytes" => 2_048,
        "memory_available_bytes" => 1_024, "memory_host_resident_bytes" => nil,
        "memory_limit_bytes" => 536_870_912, "disk_read_bytes" => 1, "disk_write_bytes" => 2,
        "net_rx_bytes" => 3, "net_tx_bytes" => 4, "uptime_secs" => 9.5,
        "timestamp_ms" => 1_700_000_000_000
      )
    end

    it "parses numeric fields and timestamp" do
      expect(metrics.cpu_percent).to eq(12.5)
      expect(metrics.memory_bytes).to eq(2_048)
      expect(metrics.memory_limit_bytes).to eq(536_870_912)
      expect(metrics.uptime_secs).to eq(9.5)
      expect(metrics.timestamp).to be_a(Time)
    end

    it "exposes the OCI upper-layer fields (nil when absent)" do
      expect(metrics.upper_used_bytes).to be_nil
      with_upper = described_class.new(
        "cpu_percent" => 0.0, "vcpu_time_ns" => 0, "memory_bytes" => 0,
        "memory_limit_bytes" => 0, "disk_read_bytes" => 0, "disk_write_bytes" => 0,
        "net_rx_bytes" => 0, "net_tx_bytes" => 0, "uptime_secs" => 0.0,
        "timestamp_ms" => 1, "upper_used_bytes" => 100, "upper_free_bytes" => 900,
        "upper_host_allocated_bytes" => 1_000
      )
      expect(with_upper.upper_used_bytes).to eq(100)
      expect(with_upper.upper_free_bytes).to eq(900)
      expect(with_upper.upper_host_allocated_bytes).to eq(1_000)
    end
  end

  describe Microsandbox::SnapshotInfo do
    it "parses the full manifest shape (create/open/list_dir path)" do
      info = described_class.new(
        "digest" => "sha256:abc", "path" => "/snaps/x", "size_bytes" => 4096,
        "image_ref" => "alpine:latest", "image_manifest_digest" => "sha256:img",
        "format" => "raw", "fstype" => "ext4", "parent_digest" => nil,
        "created_at_ms" => 1_700_000_000_000, "source_sandbox" => "base",
        "labels" => {"team" => "infra"}
      )
      expect(info.digest).to eq("sha256:abc")
      expect(info.image_manifest_digest).to eq("sha256:img")
      expect(info.fstype).to eq("ext4")
      expect(info.format).to eq(:raw)
      expect(info.source_sandbox).to eq("base")
      expect(info.labels).to eq({"team" => "infra"})
      expect(info.created_at).to be_a(Time)
    end

    it "defaults labels to {} on the index path (get/list/import)" do
      info = described_class.new("digest" => "sha256:abc", "path" => "/snaps/x", "name" => "x")
      expect(info.labels).to eq({})
      expect(info.fstype).to be_nil
      expect(info.source_sandbox).to be_nil
    end
  end

  describe Microsandbox::LogEntry do
    subject(:entry) do
      described_class.new(
        "timestamp_ms" => 1_700_000_000_000, "source" => "stdout",
        "session_id" => 7, "cursor" => "abc", "data" => "line\n".b
      )
    end

    it "parses source, cursor, and decodes text" do
      expect(entry.source).to eq(:stdout)
      expect(entry.session_id).to eq(7)
      expect(entry.cursor).to eq("abc")
      expect(entry.text).to eq("line\n")
      expect(entry.data.encoding).to eq(Encoding::ASCII_8BIT)
      expect(entry.timestamp).to be_a(Time)
    end
  end

  # Captured process output is arbitrary bytes: invalid UTF-8 is common (binary
  # output, or a relay boundary that splits a multibyte sequence). The text/
  # stdout/stderr accessors must decode losslessly to *valid* UTF-8 (matching
  # Python's from_utf8_lossy and Node's TextDecoder{fatal:false}); otherwise
  # downstream regex/concat/JSON.generate raise Encoding::CompatibilityError.
  describe "lossy UTF-8 decoding of captured bytes" do
    # 0xff is never a valid UTF-8 byte; "\xe4\xb8" is a truncated 3-byte char.
    let(:invalid) { "ok\xff\xe4\xb8".b }

    it "scrubs invalid bytes in LogEntry#text" do
      entry = Microsandbox::LogEntry.new(
        "timestamp_ms" => 1, "source" => "stdout", "session_id" => nil,
        "cursor" => "", "data" => invalid
      )
      expect(entry.text.encoding).to eq(Encoding::UTF_8)
      expect(entry.text).to be_valid_encoding
      expect(entry.data.encoding).to eq(Encoding::ASCII_8BIT) # raw bytes untouched
    end

    it "scrubs invalid bytes in ExecOutput#stdout/#stderr" do
      out = Microsandbox::ExecOutput.new(
        "exit_code" => 0, "success" => true, "stdout" => invalid, "stderr" => invalid
      )
      expect(out.stdout).to be_valid_encoding
      expect(out.stderr).to be_valid_encoding
      expect(out.stdout_bytes.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "scrubs invalid bytes in ExecEvent#text (and keeps nil for non-data events)" do
      ev = Microsandbox::ExecEvent.new("type" => "stdout", "data" => invalid)
      expect(ev.text).to be_valid_encoding
      exited = Microsandbox::ExecEvent.new("type" => "exited", "code" => 0, "data" => nil)
      expect(exited.text).to be_nil
    end

    it "scrubs invalid bytes in SshOutput#stdout/#stderr" do
      out = Microsandbox::SshOutput.new(
        "status" => 0, "success" => true, "stdout" => invalid, "stderr" => invalid
      )
      expect(out.stdout).to be_valid_encoding
      expect(out.stderr).to be_valid_encoding
    end
  end

  describe Microsandbox::PullSession do
    let(:native) { instance_double(Microsandbox::Native::PullSession) }
    subject(:session) { described_class.new(native) }

    it "iterates progress-event Hashes until recv returns nil" do
      allow(native).to receive(:recv).and_return(
        {"kind" => "resolving", "reference" => "python"},
        {"kind" => "complete", "reference" => "python", "layer_count" => 3},
        nil
      )
      expect(session.map { |ev| ev["kind"] }).to eq(%w[resolving complete])
    end

    it "wraps #result in a live Sandbox" do
      native_sandbox = instance_double(Microsandbox::Native::Sandbox, name: "box")
      allow(native).to receive(:result).and_return(native_sandbox)
      expect(session.sandbox).to be_a(Microsandbox::Sandbox)
      expect(session.sandbox.name).to eq("box")
    end
  end

  describe Microsandbox::FsReadStream do
    it "iterates byte chunks until recv returns nil, and #read drains them" do
      native = instance_double(Microsandbox::Native::FsReadStream)
      allow(native).to receive(:recv).and_return("ab".b, "cd".b, nil)
      expect(described_class.new(native).read).to eq("abcd".b)
    end
  end

  describe Microsandbox::FsWriteSink do
    let(:native) { instance_double(Microsandbox::Native::FsWriteSink) }
    subject(:sink) { described_class.new(native) }

    it "writes String bytes (chainable) and rejects non-String" do
      allow(native).to receive(:write)
      expect(sink.write("x".b)).to equal(sink)
      expect(native).to have_received(:write).with("x")
      expect { sink.write(42) }.to raise_error(TypeError, /must be a String/)
    end

    it "closes returning nil" do
      allow(native).to receive(:close)
      expect(sink.close).to be_nil
    end
  end

  describe Microsandbox::SandboxHandle do
    it "exposes name/status and timestamps from the native handle" do
      native = instance_double(
        Microsandbox::Native::SandboxHandle,
        name: "box", status: "running",
        created_at_ms: 1_700_000_000_000, updated_at_ms: nil
      )
      handle = described_class.new(native)
      expect(handle.name).to eq("box")
      expect(handle.status).to eq(:running)
      expect(handle).to be_running
      expect(handle).not_to be_stopped
      expect(handle.created_at).to be_a(Time)
      expect(handle.updated_at).to be_nil
    end

    it "is still reachable through the deprecated SandboxInfo alias" do
      expect(Microsandbox::SandboxInfo).to equal(Microsandbox::SandboxHandle)
    end
  end

  describe Microsandbox::SandboxStopResult do
    it "parses status/exit_code/signal and the observation timestamp" do
      result = described_class.new(
        "name" => "box", "status" => "crashed", "exit_code" => nil,
        "signal" => 9, "observed_at_ms" => 1_700_000_000_000, "source" => "owned process handle"
      )
      expect(result.name).to eq("box")
      expect(result.status).to eq(:crashed)
      expect(result).to be_crashed
      expect(result).not_to be_stopped
      expect(result.exit_code).to be_nil
      expect(result.signal).to eq(9)
      expect(result.source).to eq("owned process handle")
      expect(result.observed_at).to be_a(Time)
    end
  end
end
