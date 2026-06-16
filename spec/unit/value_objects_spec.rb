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

  describe Microsandbox::SandboxInfo do
    it "parses name/status and timestamps" do
      info = described_class.new(
        "name" => "box", "status" => "running",
        "created_at_ms" => 1_700_000_000_000, "updated_at_ms" => nil
      )
      expect(info.name).to eq("box")
      expect(info.status).to eq(:running)
      expect(info).to be_running
      expect(info).not_to be_stopped
      expect(info.created_at).to be_a(Time)
      expect(info.updated_at).to be_nil
    end
  end
end
