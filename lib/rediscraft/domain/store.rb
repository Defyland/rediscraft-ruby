# frozen_string_literal: true

require "thread"
require "rediscraft/domain/entry"

module Rediscraft
  module Domain
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
          entry&.value
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

      private

      # The only two methods that touch @entries directly, so the counters can
      # never drift: every code path mutates the keyspace through them.
      def store_entry(key, entry)
        remove_entry(key)
        @entries[key] = entry
        @key_count += 1
        @volatile_count += 1 unless entry.expires_at.nil?
      end

      def remove_entry(key)
        entry = @entries.delete(key)
        return if entry.nil?

        @key_count -= 1
        @volatile_count -= 1 unless entry.expires_at.nil?
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
