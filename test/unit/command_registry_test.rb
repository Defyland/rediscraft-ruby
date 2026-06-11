require "test_helper"
require "rediscraft/application/command_registry"

class CommandRegistryTest < Minitest::Test
  def test_defines_public_commands_with_arity_and_durability
    registry = Rediscraft::Application::CommandRegistry

    assert_equal %w[PING SET GET DEL EXISTS EXPIRE TTL PERSIST INFO LPUSH RPUSH LLEN LRANGE], registry.public_names
    assert registry.valid_arity?(["SET", "name", "Ada"])
    refute registry.valid_arity?(["SET", "name"])
    assert registry.durable?("SET")
    assert registry.durable?("expire")
    refute registry.durable?("GET")
  end

  def test_translates_valid_durable_commands_to_aof_records
    now = Time.utc(2026, 1, 1, 12, 0, 0)
    registry = Rediscraft::Application::CommandRegistry

    assert_equal ["SET", "name", "Ada"], registry.durable_parts_for(["SET", "name", "Ada"], clock: -> { now })
    assert_equal ["EXPIREAT", "session", "1767268860.0"], registry.durable_parts_for(["EXPIRE", "session", "60"], clock: -> { now })
    assert_nil registry.durable_parts_for(["GET", "name"], clock: -> { now })
    assert_nil registry.durable_parts_for(["EXPIRE", "session", "-1"], clock: -> { now })
    assert_nil registry.durable_parts_for(["SET", "name"], clock: -> { now })
  end

  def test_parses_non_negative_integer_arguments
    registry = Rediscraft::Application::CommandRegistry

    assert_equal 60, registry.parse_non_negative_integer("60")
    assert_nil registry.parse_non_negative_integer("-1")
    assert_nil registry.parse_non_negative_integer("abc")
  end
end
