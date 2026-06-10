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

      def delete(key)
        @mutex.synchronize do
          return 0 if live_entry_for(key).nil?

          @entries.delete(key)
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

          @entries[key] = Entry.new(value: entry.value, expires_at: expires_at)
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

          @entries[key] = Entry.new(value: entry.value, expires_at: nil)
          1
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
