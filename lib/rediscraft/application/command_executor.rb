# frozen_string_literal: true

require "rediscraft/application/response"
require "rediscraft/application/command_registry"
require "rediscraft/domain/store"

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
        when "LPUSH"
          execute_push(parts, side: :left)
        when "RPUSH"
          execute_push(parts, side: :right)
        when "LLEN"
          execute_llen(parts)
        when "LRANGE"
          execute_lrange(parts)
        else
          Response.error("ERR unknown command")
        end
      rescue Rediscraft::Domain::TypeMismatch
        wrong_type_error
      end

      # Apply a durable record, on replay and on the live AOF write path. Every
      # public command routes back through `execute`, so a command's effect and
      # its reply have a single source of truth: there is no second dispatch that
      # could silently disagree with the live one. EXPIREAT is the one record the
      # public dispatch does not know -- it is the internal, absolute-instant form
      # of EXPIRE, carrying the moment computed when EXPIRE first ran so replay
      # reproduces the exact expiry instead of recomputing it from a fresh clock.
      def apply_durable(record)
        return apply_expire_at(record) if record.first == "EXPIREAT"

        execute(record)
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

      def execute_push(parts, side:)
        Response.integer(@store.list_push(parts[1], parts[2..], side: side))
      end

      def execute_llen(parts)
        Response.integer(@store.list_length(parts[1]))
      end

      def execute_lrange(parts)
        start = Integer(parts[2], 10)
        stop = Integer(parts[3], 10)
        Response.array(@store.list_range(parts[1], start, stop))
      rescue ArgumentError
        Response.error("ERR value is not an integer or out of range")
      end

      def apply_expire_at(record)
        return nil unless record.length == 3

        Response.integer(@store.expire_at(record[1], Time.at(Float(record[2])).utc))
      rescue ArgumentError
        nil
      end

      def wrong_type_error
        Response.error("WRONGTYPE Operation against a key holding the wrong kind of value")
      end
    end
  end
end
