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
        durable_parts = durable_parts_for(parts)
        @aof.append(durable_parts) if durable_parts
        response = @inner.execute(parts)
        response
      end

      private

      def durable_parts_for(parts)
        command = parts.first&.upcase
        return nil unless MUTATING_COMMANDS.include?(command)

        case command
        when "SET"
          return nil unless parts.length == 3

          parts
        when "DEL", "PERSIST"
          return nil unless parts.length == 2

          parts
        when "EXPIRE"
          return nil unless parts.length == 3

          ttl_seconds = parse_non_negative_integer(parts[2])
          return nil if ttl_seconds.nil?

          expires_at = @clock.call + ttl_seconds
          ["EXPIREAT", parts[1], expires_at.to_i.to_s]
        end
      end

      def parse_non_negative_integer(value)
        Integer(value, 10).then { |number| number.negative? ? nil : number }
      rescue ArgumentError
        nil
      end
    end
  end
end
