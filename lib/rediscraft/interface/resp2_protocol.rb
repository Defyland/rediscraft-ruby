# frozen_string_literal: true

require "rediscraft/application/response"
require "rediscraft/interface/protocol_error"
require "rediscraft/interface/response_formatting"

module Rediscraft
  module Interface
    class Resp2Protocol
      include ResponseFormatting

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

      # Wire encoders for each Response kind; ResponseFormatting routes to them.
      def simple_frame(payload)
        "+#{payload}#{CRLF}"
      end

      def error_frame(payload)
        "-#{payload}#{CRLF}"
      end

      def integer_frame(payload)
        ":#{payload}#{CRLF}"
      end

      def null_bulk
        "$-1#{CRLF}"
      end

      def bulk_frame(value)
        string = value.to_s
        "$#{string.bytesize}#{CRLF}#{string}#{CRLF}"
      end

      def array_frame(elements)
        "*#{elements.length}#{CRLF}#{elements.map { |element| bulk_frame(element) }.join}"
      end
    end
  end
end
