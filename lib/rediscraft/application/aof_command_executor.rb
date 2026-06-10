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

      private

      def durable_parts_for(parts)
        CommandRegistry.durable_parts_for(parts, clock: @clock)
      end
    end
  end
end
