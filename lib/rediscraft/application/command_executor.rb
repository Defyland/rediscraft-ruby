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
          Response.simple("PONG")
        when "SET"
          execute_set(parts)
        when "GET"
          execute_get(parts)
        when "DEL"
          execute_del(parts)
        when "EXISTS"
          execute_exists(parts)
        when "EXPIRE"
          execute_expire(parts)
        when "TTL"
          execute_ttl(parts)
        when "PERSIST"
          execute_persist(parts)
        else
          Response.error("ERR unknown command")
        end
      end

      private

      def execute_set(parts)
        return Response.error("ERR wrong number of arguments for SET") unless parts.length == 3

        @store.set(parts[1], parts[2])
        Response.simple("OK")
      end

      def execute_get(parts)
        return Response.error("ERR wrong number of arguments for GET") unless parts.length == 2

        Response.bulk(@store.get(parts[1]))
      end

      def execute_del(parts)
        return Response.error("ERR wrong number of arguments for DEL") unless parts.length == 2

        Response.integer(@store.delete(parts[1]))
      end

      def execute_exists(parts)
        return Response.error("ERR wrong number of arguments for EXISTS") unless parts.length == 2

        Response.integer(@store.exist?(parts[1]))
      end

      def execute_expire(parts)
        return Response.error("ERR wrong number of arguments for EXPIRE") unless parts.length == 3

        ttl_seconds = parse_non_negative_integer(parts[2])
        return Response.error("ERR invalid expire time") if ttl_seconds.nil?

        Response.integer(@store.expire(parts[1], ttl_seconds))
      end

      def execute_ttl(parts)
        return Response.error("ERR wrong number of arguments for TTL") unless parts.length == 2

        Response.integer(@store.ttl(parts[1]))
      end

      def execute_persist(parts)
        return Response.error("ERR wrong number of arguments for PERSIST") unless parts.length == 2

        Response.integer(@store.persist(parts[1]))
      end

      def parse_non_negative_integer(value)
        Integer(value, 10).then { |number| number.negative? ? nil : number }
      rescue ArgumentError
        nil
      end
    end
  end
end
