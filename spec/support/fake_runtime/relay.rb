# frozen_string_literal: true

# A fake `msb sandbox` runtime + agent relay, for driving the Ruby SDK's LOCAL
# backend with no microVM. It is exec'd by the generated `fake_msb` script (see
# fake_runtime.rb), which has already printed the startup JSON on stdout.
#
#   * reads the LaunchConfig JSON the SDK hands over on fd 96 to learn the agent
#     socket path
#   * serves the agent-relay wire protocol on that Unix socket:
#       handshake  = [id_min u32 BE][id_max u32 BE] + a core.ready frame
#       frame      = [len u32 BE][id u32 BE][flags u8][CBOR {v, t, p(bytes)}]
#   * exits when the SDK closes the parent-watchdog pipe (fd 97), on
#     core.shutdown, or on SIGTERM
#
# Scripted "guest commands" (core.exec.request .cmd):
#   echo <text>            -> started, stdout(text), exited(0)
#   hang                   -> started, then silence until core.exec.signal -> exited(128+sig)
#   tick <interval_s>      -> started, a stdout line every interval until signalled
#   flood <frames> <bytes> -> started, <frames> stdout frames of <bytes> each, exited(0)
#   cat                    -> started, echoes core.exec.stdin back as stdout; empty stdin -> exited(0)
#
# Guest filesystem (core.fs.*): just enough for a streaming write —
#   OpenFile -> a handle; Write -> a stream that accepts core.fs.data chunks and
#   answers the empty (EOF) chunk with a terminal ok response; CloseHandle -> ok.
#
# Timing knobs (environment, read when the relay starts, i.e. at sandbox boot):
#   FAKE_RELAY_BOOT_DELAY   seconds to wait before the FIRST connection's
#                           handshake, so `Sandbox.create` takes at least that long
#   FAKE_RELAY_CONN_DELAY   the same for every LATER connection (exec, fs, connect)
#   FAKE_RELAY_FS_ACK_DELAY seconds to wait before acknowledging a write stream's EOF
require "socket"
require "json"
require "fileutils"
require_relative "cbor"

LOG = File.open(ENV.fetch("FAKE_RELAY_LOG", File::NULL), "a").tap { |f| f.sync = true }
T0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

def log(msg)
  LOG.puts(format("[relay %d +%.3f] %s", Process.pid, Process.clock_gettime(Process::CLOCK_MONOTONIC) - T0, msg))
end

CONFIG_FD = 96
PARENT_WATCH_FD = 97
PROTOCOL_VERSION = 7
FLAG_TERMINAL = 1

BOOT_DELAY = ENV["FAKE_RELAY_BOOT_DELAY"].to_f
CONN_DELAY = ENV["FAKE_RELAY_CONN_DELAY"].to_f
FS_ACK_DELAY = ENV["FAKE_RELAY_FS_ACK_DELAY"].to_f

launch = JSON.parse(IO.for_fd(CONFIG_FD, autoclose: false).read)
sock_path = launch.fetch("agent_sock")
log "started; args=#{ARGV.first(5).inspect} agent_sock=#{sock_path}"
FileUtils.mkdir_p(File.dirname(sock_path))
File.unlink(sock_path) if File.exist?(sock_path)
server = UNIXServer.new(sock_path)

# Parent watchdog: EOF on fd 97 == the owning SDK process dropped its handle (or
# died). This line is the structural "the Rust Sandbox value was dropped" signal
# the specs look for.
watch = begin
  IO.for_fd(PARENT_WATCH_FD, autoclose: false)
rescue
  nil
end
if watch
  Thread.new do
    loop do
      b = watch.read(1)
      if b.nil?
        log "parent-watchdog EOF -> exiting (this is what an attached sandbox does when its owner goes away)"
        exit!(0)
      elsif b.getbyte(0) == 1
        log "parent-watchdog DETACH byte received -> staying alive"
        break
      end
    end
  end
end
trap("TERM") { exit!(143) }

def frame(id, flags, type, payload)
  body = MiniCbor.encode({"v" => PROTOCOL_VERSION, "t" => type, "p" => MiniCbor::Bytes.new(MiniCbor.encode(payload))})
  [5 + body.bytesize, id, flags].pack("NNC") + body
end

def read_exact(sock, n)
  buf = +"".b
  while buf.bytesize < n
    chunk = sock.read(n - buf.bytesize)
    return nil if chunk.nil? || chunk.empty?
    buf << chunk
  end
  buf
end

conn_seq = 0
next_fs_handle = 0
loop do
  sock = server.accept
  conn_seq += 1
  cid = conn_seq
  Thread.new(sock, cid) do |s, c|
    wlock = Mutex.new
    send_frame = ->(id, flags, type, payload) { wlock.synchronize { s.write(frame(id, flags, type, payload)) } }
    sessions = {}   # exec id -> {cmd:, thread:}
    writes = {}     # fs write-stream id -> bytes received so far
    begin
      # Logged BEFORE the delay below: a spec that sees this line knows the
      # native call that opened the connection is now blocked on the handshake.
      log "conn#{c}: connected"
      # Make the boot (first connection) or a later exec/fs/connect call slow
      # enough for a spec to interrupt it mid-flight.
      delay = (c == 1) ? BOOT_DELAY : CONN_DELAY
      sleep delay if delay > 0
      id_min = c * 0x10_0000 + 1
      id_max = (c + 1) * 0x10_0000
      s.write([id_min, id_max].pack("NN"))
      s.write(frame(0, 0, "core.ready", {"boot_time_ns" => 1, "init_time_ns" => 2, "ready_time_ns" => 3, "agent_version" => "fake-0.0.0"}))
      log "conn#{c}: accepted, handshake sent (ids #{id_min}...#{id_max})"
      loop do
        hdr = read_exact(s, 4) or break
        len = hdr.unpack1("N")
        data = read_exact(s, len) or break
        id, flags = data.unpack("NC")
        msg = MiniCbor.decode(data.byteslice(5..))
        type = msg["t"]
        payload = (msg["p"].is_a?(MiniCbor::Bytes) && !msg["p"].data.empty?) ? MiniCbor.decode(msg["p"].data) : {}
        case type
        when "core.exec.request"
          cmd = payload["cmd"]
          args = payload["args"] || []
          log "conn#{c}: exec.request id=#{id} cmd=#{cmd.inspect} args=#{args.inspect}"
          send_frame.call(id, 0, "core.exec.started", {"pid" => 4242})
          case cmd
          when "echo"
            send_frame.call(id, 0, "core.exec.stdout", {"data" => MiniCbor::Bytes.new(args.join(" ") + "\n")})
            send_frame.call(id, FLAG_TERMINAL, "core.exec.exited", {"code" => 0})
          when "hang", "cat"
            sessions[id] = {cmd: cmd}
          when "tick"
            interval = (args[0] || "0.2").to_f
            sessions[id] = {cmd: cmd, thread: Thread.new do
              n = 0
              loop do
                send_frame.call(id, 0, "core.exec.stdout", {"data" => MiniCbor::Bytes.new("tick #{n += 1}\n")})
                sleep interval
              end
            rescue IOError, SystemCallError
              nil
            end}
          when "flood"
            frames = (args[0] || "100").to_i
            size = (args[1] || "1024").to_i
            sessions[id] = {cmd: cmd, thread: Thread.new do
              blob = MiniCbor::Bytes.new("x" * size)
              frames.times { send_frame.call(id, 0, "core.exec.stdout", {"data" => blob}) }
              send_frame.call(id, FLAG_TERMINAL, "core.exec.exited", {"code" => 0})
              log "conn#{c}: flood id=#{id} finished writing #{frames} frames"
            rescue IOError, SystemCallError => e
              log "conn#{c}: flood id=#{id} aborted: #{e.class}"
            end}
          else
            send_frame.call(id, FLAG_TERMINAL, "core.exec.exited", {"code" => 127})
          end
        when "core.exec.signal"
          sig = payload["signal"]
          log "conn#{c}: exec.signal id=#{id} signal=#{sig}"
          if (sess = sessions.delete(id))
            sess[:thread]&.kill
            send_frame.call(id, FLAG_TERMINAL, "core.exec.exited", {"code" => 128 + sig.to_i})
          end
        when "core.exec.stdin"
          bytes = payload["data"].is_a?(MiniCbor::Bytes) ? payload["data"].data : ""
          log "conn#{c}: exec.stdin id=#{id} #{bytes.bytesize}B"
          if sessions[id] && sessions[id][:cmd] == "cat"
            if bytes.empty?
              sessions.delete(id)
              send_frame.call(id, FLAG_TERMINAL, "core.exec.exited", {"code" => 0})
            else
              send_frame.call(id, 0, "core.exec.stdout", {"data" => MiniCbor::Bytes.new(bytes)})
            end
          end
        when "core.exec.resize"
          log "conn#{c}: exec.resize id=#{id} #{payload.inspect}"
        when "core.fs.request"
          # `op` is an externally tagged enum: {"OpenFile" => {...}} and so on.
          op, body = (payload["op"] || {}).first
          case op
          when "OpenFile"
            handle = (next_fs_handle += 1)
            log "conn#{c}: fs.open id=#{id} path=#{body["path"].inspect} handle=#{handle}"
            send_frame.call(id, FLAG_TERMINAL, "core.fs.response", {"ok" => true, "data" => {"Handle" => handle}})
          when "Write"
            writes[id] = 0
            log "conn#{c}: fs.write id=#{id} handle=#{body["handle"]} stream opened"
          when "CloseHandle"
            log "conn#{c}: fs.close_handle id=#{id} handle=#{body["handle"]}"
            send_frame.call(id, FLAG_TERMINAL, "core.fs.response", {"ok" => true})
          else
            log "conn#{c}: fs.request id=#{id} unsupported op #{op.inspect}"
            send_frame.call(id, FLAG_TERMINAL, "core.fs.response", {"ok" => false, "error" => "fake relay: unsupported fs op #{op}"})
          end
        when "core.fs.data"
          bytes = payload["data"].is_a?(MiniCbor::Bytes) ? payload["data"].data : ""
          if !writes.key?(id)
            log "conn#{c}: fs.data id=#{id} for an unknown stream"
          elsif bytes.empty?
            # The empty chunk is EOF; the sink's close waits for this response.
            log "conn#{c}: fs.write id=#{id} EOF after #{writes.delete(id)}B"
            sleep FS_ACK_DELAY if FS_ACK_DELAY > 0
            send_frame.call(id, FLAG_TERMINAL, "core.fs.response", {"ok" => true})
          else
            writes[id] += bytes.bytesize
          end
        when "core.ping"
          send_frame.call(id, FLAG_TERMINAL, "core.pong", {})
        when "core.touch"
          send_frame.call(id, FLAG_TERMINAL, "core.touched", {"activity_seq" => 1})
        when "core.shutdown"
          log "conn#{c}: core.shutdown -> exiting"
          exit!(0)
        else
          log "conn#{c}: unhandled #{type} id=#{id} flags=#{flags} payload=#{payload.inspect[0, 120]}"
        end
      end
      log "conn#{c}: client disconnected (live exec sessions at disconnect: #{sessions.keys.inspect}; " \
          "open fs write streams: #{writes.keys.inspect})"
    rescue IOError, SystemCallError => e
      log "conn#{c}: closed with #{e.class}: #{e.message}"
    ensure
      sessions.each_value { |sess| sess[:thread]&.kill }
      begin
        s.close
      rescue IOError, SystemCallError
        nil
      end
    end
  end
end
