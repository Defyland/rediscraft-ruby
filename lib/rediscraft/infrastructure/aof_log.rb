# frozen_string_literal: true

require "fileutils"
require "rediscraft/interface/text_protocol"

module Rediscraft
  module Infrastructure
    class AofLog
      def initialize(path:, protocol: Rediscraft::Interface::TextProtocol.new)
        @path = path
        @protocol = protocol
        FileUtils.mkdir_p(File.dirname(path))
      end

      def append(parts)
        File.open(@path, "a") do |file|
          file.write(encode(parts))
          file.flush
        end
      end

      def replay(executor)
        return unless File.exist?(@path)

        File.foreach(@path) do |line|
          next unless line.end_with?("\n")

          executor.execute(@protocol.parse(line))
        end
      end

      private

      def encode(parts)
        "#{parts.join(" ")}\n"
      end
    end
  end
end
