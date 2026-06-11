require "test_helper"
require "socket"
require "rediscraft/application/command_executor"
require "rediscraft/domain/store"
require "rediscraft/interface/resp2_protocol"
require "rediscraft/interface/tcp_server"

class TcpServerTest < Minitest::Test
  def setup
    store = Rediscraft::Domain::Store.new
    executor = Rediscraft::Application::CommandExecutor.new(store: store)
    @server = Rediscraft::Interface::TcpServer.new(
      host: "127.0.0.1",
      port: 0,
      executor: executor
    )
    @thread = Thread.new { @server.start }
    sleep 0.05 until @server.port
  end

  def teardown
    @server.stop
    @thread.join(1)
  end

  def test_handles_commands_over_tcp
    socket = TCPSocket.new("127.0.0.1", @server.port)

    socket.write("PING\n")
    assert_equal "+PONG\n", socket.gets

    socket.write("SET name Ada\n")
    assert_equal "+OK\n", socket.gets

    socket.write("GET name\n")
    assert_equal "$3 Ada\n", socket.gets

    socket.write("QUIT\n")
    assert_equal "+OK\n", socket.gets
  ensure
    socket&.close
  end

  def test_handles_concurrent_clients
    clients = 5.times.map do |index|
      Thread.new do
        socket = TCPSocket.new("127.0.0.1", @server.port)
        socket.write("SET key#{index} value#{index}\n")
        set_response = socket.gets
        socket.write("GET key#{index}\n")
        get_response = socket.gets
        socket.close
        [set_response, get_response]
      end
    end

    responses = clients.map(&:value)

    responses.each_with_index do |(set_response, get_response), index|
      assert_equal "+OK\n", set_response
      assert_equal "$6 value#{index}\n", get_response
    end
  end

  def test_removes_closed_connections_from_tracking
    socket = TCPSocket.new("127.0.0.1", @server.port)
    socket.write("QUIT\n")
    assert_equal "+OK\n", socket.gets
    socket.close

    wait_until { @server.tracked_client_count.zero? }

    assert_equal 0, @server.tracked_client_count
  end

  def test_handles_a_command_split_across_writes
    socket = TCPSocket.new("127.0.0.1", @server.port)

    socket.write("SET split ")
    sleep 0.05
    socket.write("value\n")
    assert_equal "+OK\n", socket.gets

    socket.write("GET split\n")
    assert_equal "$5 value\n", socket.gets
  ensure
    socket&.close
  end

  def test_stop_returns_without_blocking
    socket = TCPSocket.new("127.0.0.1", @server.port)
    socket.write("QUIT\n")
    assert_equal "+OK\n", socket.gets
    socket.close

    wait_until { @server.tracked_client_count.zero? }

    started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    @server.stop
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at

    assert_operator elapsed, :<, 0.2
  end

  def test_stop_closes_idle_client_sockets
    socket = TCPSocket.new("127.0.0.1", @server.port)
    wait_until { @server.tracked_client_count == 1 }

    @server.stop

    wait_until { @server.tracked_client_count.zero? }
    assert IO.select([socket], nil, nil, 1), "client socket should observe server shutdown"
    assert_nil socket.gets
  ensure
    socket&.close
  end

  def test_handles_resp2_commands_over_tcp
    resp_server = build_server(protocol: Rediscraft::Interface::Resp2Protocol.new)
    thread = Thread.new { resp_server.start }
    sleep 0.05 until resp_server.port
    socket = TCPSocket.new("127.0.0.1", resp_server.port)

    socket.write("*1\r\n$4\r\nPING\r\n")
    assert_equal "+PONG\r\n", socket.gets

    socket.write("*3\r\n$3\r\nSET\r\n$7\r\nmessage\r\n$12\r\nhello\r\nworld\r\n")
    assert_equal "+OK\r\n", socket.gets

    socket.write("*2\r\n$3\r\nGET\r\n$7\r\nmessage\r\n")
    assert_equal "$12\r\n", socket.gets
    assert_equal "hello\r\n", socket.gets
    assert_equal "world\r\n", socket.gets

    socket.write("*1\r\n$4\r\nQUIT\r\n")
    assert_equal "+OK\r\n", socket.gets
  ensure
    socket&.close
    resp_server&.stop
    thread&.join(1)
  end

  def test_handles_list_commands_over_resp2
    resp_server = build_server(protocol: Rediscraft::Interface::Resp2Protocol.new)
    thread = Thread.new { resp_server.start }
    sleep 0.05 until resp_server.port
    socket = TCPSocket.new("127.0.0.1", resp_server.port)

    socket.write("*4\r\n$5\r\nRPUSH\r\n$1\r\nq\r\n$1\r\na\r\n$1\r\nb\r\n")
    assert_equal ":2\r\n", socket.gets

    socket.write("*4\r\n$6\r\nLRANGE\r\n$1\r\nq\r\n$1\r\n0\r\n$2\r\n-1\r\n")
    assert_equal "*2\r\n", socket.gets
    assert_equal "$1\r\n", socket.gets
    assert_equal "a\r\n", socket.gets
    assert_equal "$1\r\n", socket.gets
    assert_equal "b\r\n", socket.gets
  ensure
    socket&.close
    resp_server&.stop
    thread&.join(1)
  end

  def test_reports_resp2_protocol_errors_over_tcp
    resp_server = build_server(protocol: Rediscraft::Interface::Resp2Protocol.new)
    thread = Thread.new { resp_server.start }
    sleep 0.05 until resp_server.port
    socket = TCPSocket.new("127.0.0.1", resp_server.port)

    socket.write("*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$-1\r\n")

    assert_equal "-ERR protocol error\r\n", socket.gets
  ensure
    socket&.close
    resp_server&.stop
    thread&.join(1)
  end

  def test_drops_a_client_that_will_not_drain_its_replies
    store = Rediscraft::Domain::Store.new
    store.set("big", "x" * 10_000)
    executor = Rediscraft::Application::CommandExecutor.new(store: store)
    slow_server = Rediscraft::Interface::TcpServer.new(
      host: "127.0.0.1", port: 0, executor: executor, max_write_buffer: 1024
    )
    thread = Thread.new { slow_server.start }
    sleep 0.05 until slow_server.port

    socket = TCPSocket.new("127.0.0.1", slow_server.port)
    # Pipeline many large replies and never read them: a slow-client backlog. The
    # server drops the connection once the backlog passes the cap, so our own
    # writes start failing -- that broken pipe is the signal we are looking for.
    begin
      500.times { socket.write("GET big\n") }
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil
    end

    wait_until(timeout: 2) { slow_server.tracked_client_count.zero? }

    assert_equal 0, slow_server.tracked_client_count
  ensure
    socket&.close
    slow_server&.stop
    thread&.join(1)
  end

  def test_an_unexpected_executor_error_drops_only_that_connection
    boom_executor = Object.new
    def boom_executor.execute(parts)
      raise "boom" if parts.first == "BOOM"

      Rediscraft::Application::Response.simple("PONG")
    end
    def boom_executor.active_expire_cycle; end

    boom_server = Rediscraft::Interface::TcpServer.new(
      host: "127.0.0.1", port: 0, executor: boom_executor
    )
    thread = Thread.new { boom_server.start }
    sleep 0.05 until boom_server.port

    victim = TCPSocket.new("127.0.0.1", boom_server.port)
    victim.write("BOOM\n")
    # The reactor drops the offending connection instead of crashing the loop, so
    # the client observes a closed socket (EOF) rather than a hung server.
    assert_nil victim.gets

    # The server is still alive: a fresh client is served normally.
    survivor = TCPSocket.new("127.0.0.1", boom_server.port)
    survivor.write("PING\n")
    assert_equal "+PONG\n", survivor.gets
  ensure
    victim&.close
    survivor&.close
    boom_server&.stop
    thread&.join(1)
  end

  private

  def build_server(protocol:)
    store = Rediscraft::Domain::Store.new
    executor = Rediscraft::Application::CommandExecutor.new(store: store)
    Rediscraft::Interface::TcpServer.new(
      host: "127.0.0.1",
      port: 0,
      executor: executor,
      protocol: protocol
    )
  end

  def wait_until(timeout: 1)
    deadline = Time.now + timeout
    until yield
      raise "condition not reached" if Time.now > deadline

      sleep 0.01
    end
  end
end
