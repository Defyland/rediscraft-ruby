# frozen_string_literal: true

require "rediscraft/application/response"
require "rediscraft/application/command_registry"

module Rediscraft
  module Application
    class CommandExecutor
      def initialize(store:)
        @store = store
      end

      def execute(parts)
        command = CommandRegistry.normalize(parts.first)
        spec = CommandRegistry.fetch(command)
        return Response.error("ERR unknown command") if spec.nil?
        return Response.error("ERR wrong number of arguments for #{command}") unless spec.valid_arity?(parts)

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
        when "INFO"
          execute_info(parts)
        else
          Response.error("ERR unknown command")
        end
      end

      def apply_durable(record)
        case record.first
        when "SET"
          return nil unless record.length == 3

          @store.set(record[1], record[2])
          Response.simple("OK")
        when "DEL"
          return nil unless record.length == 2

          Response.integer(@store.delete(record[1]))
        when "EXPIREAT"
          return nil unless record.length == 3

          Response.integer(@store.expire_at(record[1], Time.at(Float(record[2])).utc))
        when "PERSIST"
          return nil unless record.length == 2

          Response.integer(@store.persist(record[1]))
        end
      rescue ArgumentError
        nil
      end

      def snapshot
        @store.snapshot
      end

      def active_expire_cycle
        @store.active_expire_cycle
      end

      private

      def execute_set(parts)
        @store.set(parts[1], parts[2])
        Response.simple("OK")
      end

      def execute_get(parts)
        Response.bulk(@store.get(parts[1]))
      end

      def execute_del(parts)
        Response.integer(@store.delete(parts[1]))
      end

      def execute_exists(parts)
        Response.integer(@store.exist?(parts[1]))
      end

      def execute_expire(parts)
        ttl_seconds = CommandRegistry.parse_non_negative_integer(parts[2])
        return Response.error("ERR invalid expire time") if ttl_seconds.nil?

        Response.integer(@store.expire(parts[1], ttl_seconds))
      end

      def execute_ttl(parts)
        Response.integer(@store.ttl(parts[1]))
      end

      def execute_persist(parts)
        Response.integer(@store.persist(parts[1]))
      end

      def execute_info(_parts)
        summary = @store.keyspace_summary

        Response.bulk("keys:#{summary[:keys]}\nkeys_with_expiry:#{summary[:keys_with_expiry]}")
      end
    end
  end
end
