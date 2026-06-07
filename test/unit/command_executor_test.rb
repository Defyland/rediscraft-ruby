require "test_helper"
require "rediscraft/application/command_executor"
require "rediscraft/domain/store"

class CommandExecutorTest < Minitest::Test
  def setup
    @now = Time.utc(2026, 1, 1, 12, 0, 0)
    @store = Rediscraft::Domain::Store.new(clock: -> { @now })
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

  def test_del_removes_existing_key_and_reports_count
    @executor.execute(["SET", "name", "Ada"])

    assert_equal 1, @executor.execute(["DEL", "name"]).payload
    assert_nil @executor.execute(["GET", "name"]).payload
  end

  def test_exists_reports_presence_as_integer
    @executor.execute(["SET", "name", "Ada"])

    assert_equal 1, @executor.execute(["EXISTS", "name"]).payload
    assert_equal 0, @executor.execute(["EXISTS", "missing"]).payload
  end

  def test_expire_ttl_and_persist
    @executor.execute(["SET", "session", "abc"])

    assert_equal 1, @executor.execute(["EXPIRE", "session", "10"]).payload
    assert_equal 10, @executor.execute(["TTL", "session"]).payload
    assert_equal 1, @executor.execute(["PERSIST", "session"]).payload
    assert_equal(-1, @executor.execute(["TTL", "session"]).payload)
  end

  def test_expired_keys_are_not_publicly_visible
    @executor.execute(["SET", "session", "abc"])
    @executor.execute(["EXPIRE", "session", "10"])

    @now += 11

    assert_nil @executor.execute(["GET", "session"]).payload
    assert_equal 0, @executor.execute(["EXISTS", "session"]).payload
    assert_equal(-2, @executor.execute(["TTL", "session"]).payload)
  end

  def test_expire_at_is_not_a_public_command
    response = @executor.execute(["EXPIREAT", "session", "1767268860"])

    assert_equal :error, response.status
    assert_equal "ERR unknown command", response.payload
  end
end
