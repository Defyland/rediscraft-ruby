# frozen_string_literal: true

require "fileutils"
module Rediscraft
  module Infrastructure
    class AofLog
      def initialize(path:)
        @path = path
        @mutex = Mutex.new
        FileUtils.mkdir_p(File.dirname(path))
      end

      def append(parts)
        @mutex.synchronize do
          File.open(@path, "ab") do |file|
            file.write(encode(parts))
            file.flush
          end
        end
      end

      def replay(applicator)
        return unless File.exist?(@path)

        File.open(@path, "rb") do |file|
          while (payload = read_frame(file))
            parts = decode(payload)
            next if parts.nil?

            applicator.apply_durable(parts)
          end
        end
      end

      private

      def encode(parts)
        encoded_parts = parts.map do |part|
          value = part.to_s
          "#{value.bytesize} #{value}"
        end

        payload = "*#{parts.length} #{encoded_parts.join(" ")}"
        "@#{payload.bytesize}\n#{payload}"
      end

      def decode(source)
        cursor = 0
        return nil unless source.start_with?("*")

        count_text, cursor = read_token(source, 1)
        count = Integer(count_text, 10)

        parts = count.times.map do |index|
          length_text, cursor = read_token(source, cursor)
          length = Integer(length_text, 10)
          value = source.byteslice(cursor, length)
          return nil if value.nil? || value.bytesize != length

          cursor += length
          if index < count - 1
            return nil unless source.byteslice(cursor, 1) == " "

            cursor += 1
          end
          value
        end

        return nil unless cursor == source.bytesize

        parts
      rescue ArgumentError
        nil
      end

      def read_token(source, cursor)
        ending = source.index(" ", cursor)
        raise ArgumentError, "missing token" if ending.nil?

        [source.byteslice(cursor, ending - cursor), ending + 1]
      end

      def read_frame(file)
        header = file.gets
        return nil if header.nil?
        return nil unless header.start_with?("@") && header.end_with?("\n")

        length = Integer(header[1..].strip, 10)
        payload = file.read(length)
        return nil if payload.nil? || payload.bytesize != length

        payload
      rescue ArgumentError
        nil
      end
    end
  end
end
