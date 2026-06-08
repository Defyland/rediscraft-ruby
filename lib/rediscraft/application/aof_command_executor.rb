# frozen_string_literal: true

require "rediscraft/application/command_registry"

module Rediscraft
  module Application
    class AofCommandExecutor
      def initialize(inner:, aof:, clock: -> { Time.now })
        @inner = inner
        @aof = aof
        @clock = clock
      end

      def execute(parts)
        durable_parts = durable_parts_for(parts)
        @aof.append(durable_parts) if durable_parts
        response = @inner.execute(parts)
        response
      end

      private

      def durable_parts_for(parts)
        CommandRegistry.durable_parts_for(parts, clock: @clock)
      end
    end
  end
end
