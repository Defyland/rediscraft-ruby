# frozen_string_literal: true

require "rediscraft/application/response"
require "rediscraft/interface/protocol_error"

module Rediscraft
  module Interface
    class Resp2Protocol
      CRLF = "\r\n"

      def read_request(io)
        value = read_value(io)
        return nil if value.nil?

        return normalize_array(value) if value.is_a?(Array)

        [value.to_s]
      end

      def format(response)
        if response.is_a?(Rediscraft::Application::Response)
          return "-#{response.payload}#{CRLF}" if response.status == :error
          return "$-1#{CRLF}" if response.kind == :bulk && response.payload.nil?
          return bulk(response.payload) if response.kind == :bulk
          return ":#{response.payload}#{CRLF}" if response.kind == :integer
          return "+#{response.payload}#{CRLF}" if response.kind == :simple
        end

        bulk(response)
      end

      private

      def read_value(io)
        prefix = io.read(1)
        return nil if prefix.nil?

        case prefix
        when "+"
          read_line(io)
        when "-"
          read_line(io)
        when ":"
          Integer(read_line(io), 10)
        when "$"
          read_bulk(io)
        when "*"
          read_array(io)
        else
          raise ProtocolError, "unknown RESP prefix"
        end
      rescue ArgumentError
        raise ProtocolError, "invalid integer"
      end

      def read_array(io)
        count = Integer(read_line(io), 10)
        return nil if count == -1
        raise ProtocolError, "invalid array length" if count < 0

        count.times.map { read_value(io) }
      end

      def normalize_array(value)
        raise ProtocolError, "null command argument" if value.any?(&:nil?)

        value.map(&:to_s)
      end

      def read_bulk(io)
        length = Integer(read_line(io), 10)
        return nil if length == -1
        raise ProtocolError, "invalid bulk length" if length < 0

        payload = io.read(length)
        terminator = io.read(2)
        raise ProtocolError, "incomplete bulk" if payload.nil? || payload.bytesize != length
        raise ProtocolError, "invalid bulk terminator" unless terminator == CRLF

        payload
      end

      def read_line(io)
        line = io.gets(CRLF)
        raise ProtocolError, "missing line" if line.nil? || !line.end_with?(CRLF)

        line.delete_suffix(CRLF)
      end

      def bulk(value)
        string = value.to_s
        "$#{string.bytesize}#{CRLF}#{string}#{CRLF}"
      end
    end
  end
end
