require "test_helper"
require "rediscraft/application/command_executor"
require "rediscraft/domain/store"

class CommandExecutorTest < Minitest::Test
  def setup
    @store = Rediscraft::Domain::Store.new
    @executor = Rediscraft::Application::CommandExecutor.new(store: @store)
  end

  def test_ping_returns_pong
    assert_equal "PONG", @executor.execute(["PING"]).payload
  end

  def test_set_and_get_round_trip_a_value
    assert_equal "OK", @executor.execute(["SET", "name", "Ada"]).payload

    response = @executor.execute(["GET", "name"])

    assert_equal "Ada", response.payload
  end
end
