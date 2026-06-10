# frozen_string_literal: true

require "rediscraft/application/response"

module Rediscraft
  module Interface
    class TextProtocol
      VALUE_TAIL_COMMANDS = ["SET"].freeze

      def read_request(io)
        line = io.gets
        return nil if line.nil?

        parse(line)
      end

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

      def format(response)
        return "$-1\n" if response.nil?

        return "-#{response.payload}\n" if response.status == :error
        return "$-1\n" if response.kind == :bulk && response.payload.nil?
        return bulk(response.payload) if response.kind == :bulk
        return ":#{response.payload}\n" if response.kind == :integer

        "+#{response.payload}\n"
      end

      private

      def bulk(value)
        string = value.to_s
        "$#{string.bytesize} #{string}\n"
      end
    end
  end
end
