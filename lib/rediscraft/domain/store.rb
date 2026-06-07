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
      end

      def set(key, value, ttl_seconds: nil)
        expires_at = ttl_seconds.nil? ? nil : @clock.call + ttl_seconds

        @mutex.synchronize do
          @entries[key] = Entry.new(value: value, expires_at: expires_at)
        end

        true
      end

      def get(key)
        @mutex.synchronize do
          entry = live_entry_for(key)
          entry&.value
        end
      end

      private

      def live_entry_for(key)
        entry = @entries[key]
        return nil if entry.nil?

        if entry.expired?(@clock.call)
          @entries.delete(key)
          return nil
        end

        entry
      end
    end
  end
end
