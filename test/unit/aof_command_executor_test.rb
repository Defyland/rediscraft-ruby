require "test_helper"
require "rediscraft/application/aof_command_executor"
require "rediscraft/application/command_executor"
require "rediscraft/domain/store"
require "rediscraft/infrastructure/aof_log"

class AofCommandExecutorTest < Minitest::Test
  def test_records_only_successful_mutating_commands
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
        "SET name Ada\nDEL name\nSET session abc\nEXPIREAT session 1767268860\n",
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
end
