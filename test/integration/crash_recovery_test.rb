require "test_helper"
require "socket"
require "rbconfig"
require "tmpdir"

# Validates durability against a real process crash (SIGKILL), not a fake AOF.
# This proves the write-ahead ordering: a write that was acknowledged to the
# client survives the death of the process and replays into a fresh one.
#
# It does NOT prove fsync. SIGKILL ends the process, but the OS keeps the page
# cache, so a flushed (write(2)'d) record is still on disk for the next process.
# fsync and directory fsync protect against power loss / kernel panic, which a
# user-space test cannot simulate. That boundary is the point: crash recovery is
# testable here; power-loss durability is reasoned, not tested.
class CrashRecoveryTest < Minitest::Test
  def setup
    @root = File.expand_path("../..", __dir__)
    @aof = File.join(Dir.tmpdir, "rediscraft-crash-#{rand(100_000)}.aof")
    @pids = []
  end

  def teardown
    @pids.each { |pid| stop(pid) }
    File.delete(@aof) if File.exist?(@aof)
  end

  def test_recovers_acknowledged_write_after_process_kill
    port = spawn_server
    socket = connect(port)
    socket.write(encode(["SET", "durable", "value"]))
    assert_equal "OK", read_reply(socket) # write acknowledged before the crash
    socket.close

    # Hard kill: no graceful shutdown trap runs, like a real crash.
    kill_server(@pids.last)

    recovery_port = spawn_server
    socket = connect(recovery_port)
    socket.write(encode(["GET", "durable"]))

    assert_equal "value", read_reply(socket)
  ensure
    socket&.close
  end

  private

  def spawn_server
    port = 7500 + rand(2000)
    pid = Process.spawn(
      RbConfig.ruby, File.join(@root, "bin", "rediscraft"),
      "--host", "127.0.0.1", "--port", port.to_s, "--protocol", "resp2", "--aof", @aof,
      out: File::NULL, err: File::NULL
    )
    @pids << pid
    wait_for_port(port)
    port
  end

  def kill_server(pid)
    Process.kill("KILL", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def stop(pid)
    Process.kill("TERM", pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  def connect(port)
    socket = TCPSocket.new("127.0.0.1", port)
    socket.sync = true
    socket
  end

  def wait_for_port(port, timeout: 5)
    deadline = Time.now + timeout
    begin
      TCPSocket.new("127.0.0.1", port).close
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      raise "server did not start" if Time.now > deadline

      sleep 0.02
      retry
    end
  end

  def encode(args)
    out = +"*#{args.length}\r\n"
    args.each { |arg| text = arg.to_s; out << "$#{text.bytesize}\r\n#{text}\r\n" }
    out
  end

  def read_reply(socket)
    header = socket.gets("\r\n")
    raise "connection closed" if header.nil?

    type = header[0]
    body = header[1..].chomp("\r\n")
    case type
    when "+", "-", ":"
      body
    when "$"
      length = body.to_i
      return nil if length.negative?

      payload = socket.read(length)
      socket.read(2)
      payload
    end
  end
end
