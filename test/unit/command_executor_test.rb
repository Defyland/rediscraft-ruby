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

  def test_del_on_expired_key_reports_zero
    @executor.execute(["SET", "session", "abc"])
    @executor.execute(["EXPIRE", "session", "10"])

    @now += 11

    assert_equal 0, @executor.execute(["DEL", "session"]).payload
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

  def test_info_reports_keyspace_summary
    @executor.execute(["SET", "name", "Ada"])
    @executor.execute(["SET", "session", "abc"])
    @executor.execute(["EXPIRE", "session", "10"])

    response = @executor.execute(["INFO"])

    assert_equal :bulk, response.kind
    assert_equal "keys:2\nkeys_with_expiry:1", response.payload
  end

  def test_info_tracks_mutations_in_constant_time
    assert_equal "keys:0\nkeys_with_expiry:0", @executor.execute(["INFO"]).payload

    @executor.execute(["SET", "a", "1"])
    @executor.execute(["SET", "b", "2"])
    @executor.execute(["SET", "a", "again"])
    assert_equal "keys:2\nkeys_with_expiry:0", @executor.execute(["INFO"]).payload

    @executor.execute(["EXPIRE", "a", "100"])
    assert_equal "keys:2\nkeys_with_expiry:1", @executor.execute(["INFO"]).payload

    @executor.execute(["PERSIST", "a"])
    assert_equal "keys:2\nkeys_with_expiry:0", @executor.execute(["INFO"]).payload

    @executor.execute(["DEL", "b"])
    assert_equal "keys:1\nkeys_with_expiry:0", @executor.execute(["INFO"]).payload
  end

  def test_info_counts_keys_until_lazy_eviction
    @executor.execute(["SET", "session", "abc"])
    @executor.execute(["EXPIRE", "session", "10"])

    @now += 11

    # Physical count, like Redis DBSIZE: a logically expired key is still counted
    # until something evicts it.
    assert_equal "keys:1\nkeys_with_expiry:1", @executor.execute(["INFO"]).payload

    @executor.execute(["GET", "session"]) # lazy access evicts it

    assert_equal "keys:0\nkeys_with_expiry:0", @executor.execute(["INFO"]).payload
  end

  def test_active_expire_cycle_evicts_untouched_expired_keys
    @executor.execute(["SET", "a", "1"])
    @executor.execute(["EXPIRE", "a", "10"])
    @executor.execute(["SET", "b", "2"])

    @now += 11

    # "a" is logically expired but nobody touched it, so it is still physical.
    assert_equal "keys:2\nkeys_with_expiry:1", @executor.execute(["INFO"]).payload

    evicted = @executor.active_expire_cycle

    assert_equal 1, evicted
    assert_equal "keys:1\nkeys_with_expiry:0", @executor.execute(["INFO"]).payload
  end

  def test_list_push_length_and_range
    assert_equal 1, @executor.execute(["RPUSH", "items", "a"]).payload
    assert_equal 3, @executor.execute(["RPUSH", "items", "b", "c"]).payload
    assert_equal 4, @executor.execute(["LPUSH", "items", "z"]).payload
    assert_equal 4, @executor.execute(["LLEN", "items"]).payload

    response = @executor.execute(["LRANGE", "items", "0", "-1"])
    assert_equal :array, response.kind
    assert_equal %w[z a b c], response.payload

    assert_equal %w[a b], @executor.execute(["LRANGE", "items", "1", "2"]).payload
  end

  def test_list_commands_reject_string_keys_and_vice_versa
    @executor.execute(["SET", "s", "v"])
    wrong = @executor.execute(["RPUSH", "s", "x"])
    assert_equal :error, wrong.status
    assert_includes wrong.payload, "WRONGTYPE"

    @executor.execute(["RPUSH", "l", "x"])
    wrong_get = @executor.execute(["GET", "l"])
    assert_equal :error, wrong_get.status
    assert_includes wrong_get.payload, "WRONGTYPE"
  end

  def test_llen_and_lrange_on_missing_key
    assert_equal 0, @executor.execute(["LLEN", "missing"]).payload
    assert_equal [], @executor.execute(["LRANGE", "missing", "0", "-1"]).payload
  end

  def test_expire_at_is_not_a_public_command
    response = @executor.execute(["EXPIREAT", "session", "1767268860"])

    assert_equal :error, response.status
    assert_equal "ERR unknown command", response.payload
  end
end
