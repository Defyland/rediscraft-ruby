# frozen_string_literal: true

require "thread"
require "rediscraft/domain/entry"

module Rediscraft
  module Domain
    # Raised when a command meets a key holding a different type, e.g. a list
    # command on a string key. The application layer turns it into WRONGTYPE.
    class TypeMismatch < StandardError; end

    class Store
      def initialize(clock: -> { Time.now })
        @clock = clock
        @entries = {}
        @mutex = Mutex.new
        # Physical counters maintained on every insert/remove so INFO is O(1)
        # instead of walking the keyspace. Like Redis DBSIZE, they count entries
        # that are still present, including ones that expired but were not evicted
        # yet; lazy and active expiration converge them toward the live count.
        @key_count = 0
        @volatile_count = 0
        # Keys that carry an expiry, so active expiration can sample them without
        # walking the whole keyspace.
        @expires = {}
      end

      def set(key, value, ttl_seconds: nil)
        expires_at = ttl_seconds.nil? ? nil : @clock.call + ttl_seconds

        @mutex.synchronize do
          store_entry(key, Entry.new(value: value, expires_at: expires_at))
        end

        true
      end

      def get(key)
        @mutex.synchronize do
          entry = live_entry_for(key)
          return nil if entry.nil?
          raise TypeMismatch if entry.value.is_a?(Array)

          entry.value
        end
      end

      def list_push(key, values, side:)
        @mutex.synchronize do
          entry = live_entry_for(key)
          list = entry.nil? ? [] : string_list!(entry)
          list = side == :left ? values.reverse + list : list + values
          store_entry(key, Entry.new(value: list, expires_at: entry&.expires_at))
          list.length
        end
      end

      def list_length(key)
        @mutex.synchronize do
          entry = live_entry_for(key)
          entry.nil? ? 0 : string_list!(entry).length
        end
      end

      def list_range(key, start, stop)
        @mutex.synchronize do
          entry = live_entry_for(key)
          return [] if entry.nil?

          slice_range(string_list!(entry), start, stop)
        end
      end

      def delete(key)
        @mutex.synchronize do
          return 0 if live_entry_for(key).nil?

          remove_entry(key)
          1
        end
      end

      def exist?(key)
        @mutex.synchronize do
          live_entry_for(key).nil? ? 0 : 1
        end
      end

      def expire(key, ttl_seconds)
        expire_at(key, @clock.call + ttl_seconds)
      end

      def expire_at(key, expires_at)
        @mutex.synchronize do
          entry = live_entry_for(key)
          return 0 if entry.nil?

          store_entry(key, Entry.new(value: entry.value, expires_at: expires_at))
          1
        end
      end

      def ttl(key)
        @mutex.synchronize do
          entry = live_entry_for(key)
          return -2 if entry.nil?
          return -1 if entry.expires_at.nil?

          remaining = (entry.expires_at - @clock.call).ceil
          remaining.positive? ? remaining : -2
        end
      end

      def persist(key)
        @mutex.synchronize do
          entry = live_entry_for(key)
          return 0 if entry.nil? || entry.expires_at.nil?

          store_entry(key, Entry.new(value: entry.value, expires_at: nil))
          1
        end
      end

      def keyspace_summary
        @mutex.synchronize do
          { keys: @key_count, keys_with_expiry: @volatile_count }
        end
      end

      def snapshot
        @mutex.synchronize do
          now = @clock.call
          @entries.filter_map do |key, entry|
            next if entry.expired?(now)

            { key: key, value: entry.value, expires_at: entry.expires_at }
          end
        end
      end

      # Lazy expiration only evicts a key when it is read, so a key that is set
      # with a TTL and never touched again leaks forever. Active expiration samples
      # a bounded number of keys-with-expiry and evicts the expired ones. Bounded
      # is the whole point: an O(N) sweep would stall the single-threaded loop it
      # runs on. Sampling is insertion-ordered here, a simplification of Redis's
      # random sampling, and it is not adaptive (no repeat on a high hit rate).
      def active_expire_cycle(sample: 20)
        @mutex.synchronize do
          now = @clock.call
          evicted = 0
          @expires.keys.first(sample).each do |key|
            entry = @entries[key]
            next unless entry&.expired?(now)

            remove_entry(key)
            evicted += 1
          end
          evicted
        end
      end

      private

      def string_list!(entry)
        raise TypeMismatch unless entry.value.is_a?(Array)

        entry.value
      end

      # Redis LRANGE semantics: inclusive bounds, negative indexes count from the
      # end, and out-of-range bounds clamp rather than error.
      def slice_range(list, start, stop)
        length = list.length
        from = start.negative? ? [length + start, 0].max : start
        to = stop.negative? ? length + stop : [stop, length - 1].min
        return [] if from > to || from >= length

        list[from..to] || []
      end

      # The only two methods that touch @entries directly, so the counters can
      # never drift: every code path mutates the keyspace through them.
      def store_entry(key, entry)
        remove_entry(key)
        @entries[key] = entry
        @key_count += 1
        unless entry.expires_at.nil?
          @volatile_count += 1
          @expires[key] = entry.expires_at
        end
      end

      def remove_entry(key)
        entry = @entries.delete(key)
        return if entry.nil?

        @key_count -= 1
        unless entry.expires_at.nil?
          @volatile_count -= 1
          @expires.delete(key)
        end
      end

      def live_entry_for(key)
        entry = @entries[key]
        return nil if entry.nil?

        if entry.expired?(@clock.call)
          remove_entry(key)
          return nil
        end

        entry
      end
    end
  end
end
