# frozen_string_literal: true

require "rediscraft/application/response"
require "rediscraft/interface/response_formatting"

module Rediscraft
  module Interface
    class TextProtocol
      include ResponseFormatting

      VALUE_TAIL_COMMANDS = ["SET"].freeze

      # Incremental parse for the event loop. Returns [parts, rest] once a full
      # newline-terminated line is buffered, or nil when more bytes are needed.
      def consume(buffer)
        index = buffer.index("\n")
        return nil if index.nil?

        line = buffer.byteslice(0, index + 1)
        rest = buffer.byteslice(index + 1..) || ""
        [parse(line), rest]
      end

      def parse(line)
        stripped = line.to_s.strip
        return [] if stripped.empty?

        command, rest = stripped.split(/\s+/, 2)
        return [command] if rest.nil? || rest.empty?

        if VALUE_TAIL_COMMANDS.include?(command.upcase)
          key, value = rest.split(/\s+/, 2)
          [command, key, value].compact
        else
          [command, *rest.split(/\s+/)]
        end
      end

      private

      # Wire encoders for each Response kind; ResponseFormatting routes to them.
      def simple_frame(payload)
        "+#{payload}\n"
      end

      def error_frame(payload)
        "-#{payload}\n"
      end

      def integer_frame(payload)
        ":#{payload}\n"
      end

      def null_bulk
        "$-1\n"
      end

      def bulk_frame(value)
        string = value.to_s
        "$#{string.bytesize} #{string}\n"
      end

      def array_frame(elements)
        "*#{elements.length}\n#{elements.map { |element| bulk_frame(element) }.join}"
      end
    end
  end
end
