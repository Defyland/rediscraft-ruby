require "test_helper"
require "rediscraft/application/aof_command_executor"
require "rediscraft/application/command_executor"
require "rediscraft/application/command_registry"
require "rediscraft/domain/store"
require "rediscraft/infrastructure/aof_log"

class AofCommandExecutorTest < Minitest::Test
  def build_recording_file
    recorded = { written: +"", flushes: 0, fsyncs: 0 }
    file = Object.new
    file.define_singleton_method(:write) { |chunk| recorded[:written] << chunk }
    file.define_singleton_method(:flush) { recorded[:flushes] += 1 }
    file.define_singleton_method(:fsync) { recorded[:fsyncs] += 1 }
    [file, recorded]
  end

  # Hand-rolled stub: the project intentionally has no mocking gem, so we swap
  # File.open for the block and restore it afterwards.
  def with_file_open_returning(file)
    original = File.singleton_class.instance_method(:open)
    File.singleton_class.define_method(:open) { |*_args, &block| block.call(file) }
    yield
  ensure
    File.singleton_class.define_method(:open, original)
  end

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
          "@39\n*3 8 EXPIREAT 7 session 12 1767268860.0"
        ].join,
        File.read(path)
    end
  end

  def test_durable_expire_replays_to_the_exact_live_instant
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      base = Time.utc(2026, 1, 1, 12, 0, 0)
      now = base + 0.7
      clock = -> { now }
      store = Rediscraft::Domain::Store.new(clock: clock)
      inner = Rediscraft::Application::CommandExecutor.new(store: store)
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)
      executor = Rediscraft::Application::AofCommandExecutor.new(inner: inner, aof: aof, clock: clock)

      executor.execute(["SET", "session", "abc"])
      executor.execute(["EXPIRE", "session", "60"])

      replayed = Rediscraft::Domain::Store.new(clock: clock)
      aof.replay(Rediscraft::Application::CommandExecutor.new(store: replayed))

      now = base + 60.3

      assert_equal store.get("session"), replayed.get("session")
      assert_equal store.ttl("session"), replayed.ttl("session")
    end
  end

  def test_replays_aof_into_store
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      File.write(path, "@21\n*3 3 SET 4 name 3 Ada@34\n*3 8 EXPIREAT 4 name 10 1767268860@99\npartial")

      store = Rediscraft::Domain::Store.new(clock: -> { now })
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)

      aof.replay(Rediscraft::Application::CommandExecutor.new(store: store))

      assert_equal "Ada", store.get("name")
      assert_equal 60, store.ttl("name")
    end
  end

  def test_replays_every_public_durable_command
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      registry = Rediscraft::Application::CommandRegistry
      covered_commands = %w[SET DEL EXPIRE PERSIST LPUSH RPUSH]
      store = Rediscraft::Domain::Store.new(clock: -> { now })
      inner = Rediscraft::Application::CommandExecutor.new(store: store)
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)
      executor = Rediscraft::Application::AofCommandExecutor.new(
        inner: inner,
        aof: aof,
        clock: -> { now }
      )

      assert_equal covered_commands, registry.public_names.select { |name| registry.durable?(name) }

      executor.execute(["SET", "name", "Ada"])
      executor.execute(["SET", "stale", "value"])
      executor.execute(["DEL", "stale"])
      executor.execute(["SET", "session", "abc"])
      executor.execute(["EXPIRE", "session", "60"])
      executor.execute(["SET", "persistent", "value"])
      executor.execute(["EXPIRE", "persistent", "60"])
      executor.execute(["PERSIST", "persistent"])
      executor.execute(["RPUSH", "queue", "a", "b"])
      executor.execute(["LPUSH", "queue", "z"])

      replayed_store = Rediscraft::Domain::Store.new(clock: -> { now })
      aof.replay(Rediscraft::Application::CommandExecutor.new(store: replayed_store))

      assert_equal "Ada", replayed_store.get("name")
      assert_nil replayed_store.get("stale")
      assert_equal "abc", replayed_store.get("session")
      assert_equal 60, replayed_store.ttl("session")
      assert_equal "value", replayed_store.get("persistent")
      assert_equal(-1, replayed_store.ttl("persistent"))
      assert_equal %w[z a b], replayed_store.list_range("queue", 0, -1)
    end
  end

  def test_compaction_rebuilds_lists
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      store = Rediscraft::Domain::Store.new
      inner = Rediscraft::Application::CommandExecutor.new(store: store)
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)
      executor = Rediscraft::Application::AofCommandExecutor.new(inner: inner, aof: aof)

      executor.execute(["RPUSH", "queue", "a"])
      executor.execute(["RPUSH", "queue", "b"])
      executor.execute(["LPUSH", "queue", "z"])
      executor.compact

      replayed = Rediscraft::Domain::Store.new
      aof.replay(Rediscraft::Application::CommandExecutor.new(store: replayed))

      assert_equal %w[z a b], replayed.list_range("queue", 0, -1)
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
      aof.replay(Rediscraft::Application::CommandExecutor.new(store: replayed_store))

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

      aof.replay(Rediscraft::Application::CommandExecutor.new(store: store))

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

  def test_serializes_durable_record_with_store_mutation
    store = Rediscraft::Domain::Store.new
    inner = Rediscraft::Application::CommandExecutor.new(store: store)

    appended = []
    release = Queue.new
    first_parked = Queue.new
    parked = false

    recording_aof = Object.new
    recording_aof.define_singleton_method(:append) do |parts|
      appended << parts
      unless parked
        parked = true
        first_parked << true
        release.pop
      end
    end

    executor = Rediscraft::Application::AofCommandExecutor.new(inner: inner, aof: recording_aof)

    first_writer = Thread.new { executor.execute(["SET", "key", "first"]) }
    first_parked.pop
    second_writer = Thread.new { executor.execute(["SET", "key", "second"]) }
    second_writer.join(0.2)
    release << true
    [first_writer, second_writer].each { |thread| thread.join(1) }

    assert_equal store.get("key"), appended.last[2],
      "durable record order must match the order mutations reached the store"
  end

  def test_compact_rewrites_aof_to_minimal_replayable_state
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      now = Time.utc(2026, 1, 1, 12, 0, 0)
      store = Rediscraft::Domain::Store.new(clock: -> { now })
      inner = Rediscraft::Application::CommandExecutor.new(store: store)
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)
      executor = Rediscraft::Application::AofCommandExecutor.new(inner: inner, aof: aof, clock: -> { now })

      executor.execute(["SET", "name", "Ada"])
      executor.execute(["SET", "name", "Grace"])
      executor.execute(["SET", "temp", "x"])
      executor.execute(["DEL", "temp"])
      executor.execute(["SET", "session", "abc"])
      executor.execute(["EXPIRE", "session", "60"])

      size_before = File.size(path)
      executor.compact
      size_after = File.size(path)

      assert_operator size_after, :<, size_before

      replayed = Rediscraft::Domain::Store.new(clock: -> { now })
      aof.replay(Rediscraft::Application::CommandExecutor.new(store: replayed))

      assert_equal "Grace", replayed.get("name")
      assert_nil replayed.get("temp")
      assert_equal "abc", replayed.get("session")
      assert_equal 60, replayed.ttl("session")
    end
  end

  def test_flushes_without_fsync_by_default
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      aof = Rediscraft::Infrastructure::AofLog.new(path: path)
      file, recorded = build_recording_file

      with_file_open_returning(file) do
        aof.append(["SET", "name", "Ada"])
      end

      assert_includes recorded[:written], "SET"
      assert_equal 1, recorded[:flushes]
      assert_equal 0, recorded[:fsyncs]
    end
  end

  def test_fsyncs_data_and_directory_when_creating_with_fsync
    Dir.mktmpdir do |dir|
      path = File.join(dir, "rediscraft.aof")
      aof = Rediscraft::Infrastructure::AofLog.new(path: path, fsync: true)
      file, recorded = build_recording_file

      with_file_open_returning(file) do
        aof.append(["SET", "name", "Ada"])
      end

      # One flush of the data, then two fsyncs: the file data and the directory
      # entry, because the file was created by this append.
      assert_equal 1, recorded[:flushes]
      assert_equal 2, recorded[:fsyncs]
    end
  end
end
