# frozen_string_literal: true

require "rediscraft/application/response"
require "rediscraft/interface/protocol_error"

module Rediscraft
  module Interface
    class Resp2Protocol
      CRLF = "\r\n"
      INCOMPLETE = :incomplete

      # Incremental parse for the event loop. Returns [parts, rest] once a full
      # RESP frame is buffered, nil when more bytes are needed, and raises
      # ProtocolError on a malformed frame.
      def consume(buffer)
        result = scan_value(buffer, 0)
        return nil if result == INCOMPLETE

        value, cursor = result
        command = value.is_a?(Array) ? normalize_array(value) : [value.to_s]
        [command, buffer.byteslice(cursor..) || ""]
      rescue ArgumentError
        raise ProtocolError, "invalid integer"
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

      def normalize_array(value)
        raise ProtocolError, "null command argument" if value.any?(&:nil?)

        value.map(&:to_s)
      end

      # Cursor-based scanners over a byte buffer. Each returns [value, next_cursor]
      # or INCOMPLETE when the buffer does not yet hold the full token.
      def scan_value(buffer, cursor)
        return INCOMPLETE if cursor >= buffer.bytesize

        prefix = buffer.byteslice(cursor, 1)
        body = cursor + 1

        case prefix
        when "+", "-"
          scan_line(buffer, body)
        when ":"
          line = scan_line(buffer, body)
          line == INCOMPLETE ? INCOMPLETE : [Integer(line[0], 10), line[1]]
        when "$"
          scan_bulk(buffer, body)
        when "*"
          scan_array(buffer, body)
        else
          raise ProtocolError, "unknown RESP prefix"
        end
      end

      def scan_array(buffer, cursor)
        line = scan_line(buffer, cursor)
        return INCOMPLETE if line == INCOMPLETE

        count = Integer(line[0], 10)
        return [nil, line[1]] if count == -1
        raise ProtocolError, "invalid array length" if count.negative?

        position = line[1]
        values = []
        count.times do
          element = scan_value(buffer, position)
          return INCOMPLETE if element == INCOMPLETE

          values << element[0]
          position = element[1]
        end

        [values, position]
      end

      def scan_bulk(buffer, cursor)
        line = scan_line(buffer, cursor)
        return INCOMPLETE if line == INCOMPLETE

        length = Integer(line[0], 10)
        return [nil, line[1]] if length == -1
        raise ProtocolError, "invalid bulk length" if length.negative?

        payload_start = line[1]
        frame_end = payload_start + length + CRLF.bytesize
        return INCOMPLETE if buffer.bytesize < frame_end

        terminator = buffer.byteslice(payload_start + length, CRLF.bytesize)
        raise ProtocolError, "invalid bulk terminator" unless terminator == CRLF

        [buffer.byteslice(payload_start, length), frame_end]
      end

      def scan_line(buffer, cursor)
        ending = buffer.index(CRLF, cursor)
        return INCOMPLETE if ending.nil?

        [buffer.byteslice(cursor, ending - cursor), ending + CRLF.bytesize]
      end

      def bulk(value)
        string = value.to_s
        "$#{string.bytesize}#{CRLF}#{string}#{CRLF}"
      end
    end
  end
end
