# frozen_string_literal: true

require "rediscraft/application/response"

module Rediscraft
  module Application
    class CommandExecutor
      def initialize(store:)
        @store = store
      end

      def execute(parts)
        command = parts.first&.upcase

        case command
        when "PING"
          Response.ok("PONG")
        when "SET"
          execute_set(parts)
        when "GET"
          execute_get(parts)
        else
          Response.error("ERR unknown command")
        end
      end

      private

      def execute_set(parts)
        return Response.error("ERR wrong number of arguments for SET") unless parts.length == 3

        @store.set(parts[1], parts[2])
        Response.ok("OK")
      end

      def execute_get(parts)
        return Response.error("ERR wrong number of arguments for GET") unless parts.length == 2

        Response.ok(@store.get(parts[1]))
      end
    end
  end
end
