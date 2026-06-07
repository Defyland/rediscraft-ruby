# frozen_string_literal: true

module Rediscraft
  module Application
    class AofCommandExecutor
      MUTATING_COMMANDS = ["SET", "DEL", "EXPIRE", "PERSIST"].freeze

      def initialize(inner:, aof:, clock: -> { Time.now })
        @inner = inner
        @aof = aof
        @clock = clock
      end

      def execute(parts)
        response = @inner.execute(parts)
        @aof.append(durable_parts(parts)) if durable_command?(parts, response)
        response
      end

      private

      def durable_command?(parts, response)
        command = parts.first&.upcase
        return false unless MUTATING_COMMANDS.include?(command) && response.status == :ok
        return true if command == "SET"

        response.payload == 1
      end

      def durable_parts(parts)
        command = parts.first&.upcase
        return parts unless command == "EXPIRE"

        expires_at = @clock.call + Integer(parts[2], 10)
        ["EXPIREAT", parts[1], expires_at.to_i.to_s]
      end
    end
  end
end
