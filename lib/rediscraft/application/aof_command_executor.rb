# frozen_string_literal: true

require "rediscraft/application/command_registry"

module Rediscraft
  module Application
    class AofCommandExecutor
      def initialize(inner:, aof:, clock: -> { Time.now })
        @inner = inner
        @aof = aof
        @clock = clock
        @write_mutex = Mutex.new
      end

      def execute(parts)
        durable_parts = durable_parts_for(parts)
        return @inner.execute(parts) if durable_parts.nil?

        @write_mutex.synchronize do
          @aof.append(durable_parts)
          @inner.apply_durable(durable_parts)
        end
      end

      def compact
        @write_mutex.synchronize do
          records = @inner.snapshot.flat_map { |entry| records_for(entry) }
          @aof.rewrite(records)
        end
      end

      def active_expire_cycle
        @inner.active_expire_cycle
      end

      private

      def durable_parts_for(parts)
        CommandRegistry.durable_parts_for(parts, clock: @clock)
      end

      def records_for(entry)
        records = [["SET", entry[:key], entry[:value]]]
        records << ["EXPIREAT", entry[:key], entry[:expires_at].to_f.to_s] unless entry[:expires_at].nil?
        records
      end
    end
  end
end
