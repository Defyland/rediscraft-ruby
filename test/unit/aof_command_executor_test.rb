require "test_helper"
require "rediscraft/application/aof_command_executor"
require "rediscraft/application/command_executor"
require "rediscraft/domain/store"
require "rediscraft/infrastructure/aof_log"

class AofCommandExecutorTest < Minitest::Test
  def test_records_valid_durable_commands_before_applying_them
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      store = Rediscraft::Domain::Store.new
      inner = Rediscraft::Application::CommandExecutor.new(store: store)
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)
      executor = Rediscraft::Application::AofCommandExecutor.new(
        inner: inner,
        aof: aof,
        clock: -> { now }
      )

      executor.execute(["SET", "name", "Ada"])
      executor.execute(["GET", "name"])
      executor.execute(["DEL", "name"])
      executor.execute(["DEL", "missing"])
      executor.execute(["SET", "session", "abc"])
      executor.execute(["EXPIRE", "session", "60"])
      executor.execute(["UNKNOWN"])

      assert_equal \
        "SET name Ada\nDEL name\nDEL missing\nSET session abc\nEXPIREAT session 1767268860\n",
        File.read(path)
    end
  end

  def test_replays_aof_into_store
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      File.write(path, "SET name Ada\nEXPIREAT name 1767268860\npartial")

      store = Rediscraft::Domain::Store.new(clock: -> { now })
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)

      aof.replay(store)

      assert_equal "Ada", store.get("name")
      assert_equal 60, store.ttl("name")
    end
  end

  def test_does_not_mutate_store_when_aof_append_fails
    store = Rediscraft::Domain::Store.new
    inner = Rediscraft::Application::CommandExecutor.new(store: store)
    failing_aof = Object.new

    def failing_aof.append(_parts)
      raise IOError, "disk unavailable"
    end

    executor = Rediscraft::Application::AofCommandExecutor.new(inner: inner, aof: failing_aof)

    assert_raises(IOError) { executor.execute(["SET", "name", "Ada"]) }
    assert_nil store.get("name")
  end
end
