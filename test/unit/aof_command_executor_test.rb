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
        [
          "@21\n*3 3 SET 4 name 3 Ada",
          "@15\n*2 3 DEL 4 name",
          "@18\n*2 3 DEL 7 missing",
          "@24\n*3 3 SET 7 session 3 abc",
          "@37\n*3 8 EXPIREAT 7 session 10 1767268860"
        ].join,
        File.read(path)
    end
  end

  def test_replays_aof_into_store
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      File.write(path, "@21\n*3 3 SET 4 name 3 Ada@34\n*3 8 EXPIREAT 4 name 10 1767268860@99\npartial")

      store = Rediscraft::Domain::Store.new(clock: -> { now })
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)

      aof.replay(store)

      assert_equal "Ada", store.get("name")
      assert_equal 60, store.ttl("name")
    end
  end

  def test_replays_values_without_losing_spaces_or_newlines
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      store = Rediscraft::Domain::Store.new
      inner = Rediscraft::Application::CommandExecutor.new(store: store)
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)
      executor = Rediscraft::Application::AofCommandExecutor.new(inner: inner, aof: aof)

      executor.execute(["SET", "message", " leading\nand trailing "])

      replayed_store = Rediscraft::Domain::Store.new
      aof.replay(replayed_store)

      assert_equal " leading\nand trailing ", replayed_store.get("message")
    end
  end

  def test_ignores_aof_frame_with_trailing_bytes
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      payload = "*3 3 SET 4 name 3 Ada 4 junk"
      File.binwrite(path, "@#{payload.bytesize}\n#{payload}")

      store = Rediscraft::Domain::Store.new
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)

      aof.replay(store)

      assert_nil store.get("name")
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
