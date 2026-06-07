# frozen_string_literal: true

require "fileutils"
require "rediscraft/interface/text_protocol"

module Rediscraft
  module Infrastructure
    class AofLog
      def initialize(path:, protocol: Rediscraft::Interface::TextProtocol.new)
        @path = path
        @protocol = protocol
        @mutex = Mutex.new
        FileUtils.mkdir_p(File.dirname(path))
      end

      def append(parts)
        @mutex.synchronize do
          File.open(@path, "a") do |file|
            file.write(encode(parts))
            file.flush
          end
        end
      end

      def replay(store)
        return unless File.exist?(@path)

        File.foreach(@path) do |line|
          next unless line.end_with?("\n")

          apply_record(store, @protocol.parse(line))
        end
      end

      private

      def apply_record(store, parts)
        command = parts.first&.upcase

        case command
        when "SET"
          store.set(parts[1], parts[2]) if parts.length == 3
        when "DEL"
          store.delete(parts[1]) if parts.length == 2
        when "EXPIREAT"
          store.expire_at(parts[1], Time.at(Integer(parts[2], 10)).utc) if parts.length == 3
        when "PERSIST"
          store.persist(parts[1]) if parts.length == 2
        end
      rescue ArgumentError
        nil
      end

      def encode(parts)
        "#{parts.join(" ")}\n"
      end
    end
  end
end
