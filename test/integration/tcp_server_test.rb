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
