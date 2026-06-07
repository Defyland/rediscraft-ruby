require "test_helper"
require "socket"
require "rediscraft/application/command_executor"
require "rediscraft/domain/store"
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

  def test_removes_finished_client_threads_from_tracking
    socket = TCPSocket.new("127.0.0.1", @server.port)
    socket.write("QUIT\n")
    assert_equal "+OK\n", socket.gets
    socket.close

    wait_until { @server.tracked_client_count.zero? }

    assert_equal 0, @server.tracked_client_count
  end

  private

  def wait_until(timeout: 1)
    deadline = Time.now + timeout
    until yield
      raise "condition not reached" if Time.now > deadline

      sleep 0.01
    end
  end
end
