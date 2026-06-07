# frozen_string_literal: true

require "rediscraft/application/response"

module Rediscraft
  module Interface
    class TextProtocol
      VALUE_TAIL_COMMANDS = ["SET"].freeze

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

        if response.is_a?(Rediscraft::Application::Response)
          return "-#{response.payload}\n" if response.status == :error

          return "$-1\n" if response.kind == :bulk && response.payload.nil?
          return bulk(response.payload) if response.kind == :bulk
          return ":#{response.payload}\n" if response.kind == :integer
          return "+#{response.payload}\n" if response.kind == :simple

          format(response.payload)
        elsif response.is_a?(Integer)
          ":#{response}\n"
        else
          value = response.to_s
          simple_string?(value) ? "+#{value}\n" : "$#{value.bytesize} #{value}\n"
        end
      end

      private

      def simple_string?(value)
        value.match?(/\A[A-Z][A-Z0-9 _-]*\z/)
      end

      def bulk(value)
        string = value.to_s
        "$#{string.bytesize} #{string}\n"
      end
    end
  end
end
