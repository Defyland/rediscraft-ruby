# frozen_string_literal: true

require "fileutils"
module Rediscraft
  module Infrastructure
    class AofLog
      def initialize(path:, fsync: false)
        @path = path
        @fsync = fsync
        @mutex = Mutex.new
        FileUtils.mkdir_p(File.dirname(path))
      end

      def append(parts)
        @mutex.synchronize do
          created = !File.exist?(@path)
          File.open(@path, "ab") do |file|
            file.write(encode(parts))
            file.flush
            file.fsync if @fsync
          end
          # A new file's directory entry is only durable once the directory is
          # fsynced. fsyncing the file data alone can survive a process crash but
          # not power loss before the entry is persisted.
          fsync_directory if @fsync && created
        end
      end

      def rewrite(records)
        @mutex.synchronize do
          temp_path = "#{@path}.tmp"
          File.open(temp_path, "wb") do |file|
            records.each { |parts| file.write(encode(parts)) }
            file.flush
            file.fsync if @fsync
          end
          File.rename(temp_path, @path)
          # The rename is atomic, but the new directory entry is only durable
          # after the directory itself is fsynced.
          fsync_directory if @fsync
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

      def fsync_directory
        File.open(File.dirname(@path)) do |dir|
          dir.fsync
        rescue Errno::EINVAL, NotImplementedError
          # Some platforms reject fsync on a directory handle; nothing else to do.
          nil
        end
      end

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
