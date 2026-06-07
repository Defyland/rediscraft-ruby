# frozen_string_literal: true

require "socket"
require "thread"
require "rediscraft/interface/text_protocol"

module Rediscraft
  module Interface
    class TcpServer
      attr_reader :port

      def initialize(host:, port:, executor:, protocol: TextProtocol.new)
        @host = host
        @requested_port = port
        @executor = executor
        @protocol = protocol
        @clients = []
        @clients_mutex = Mutex.new
        @running = false
      end

      def start
        @server = TCPServer.new(@host, @requested_port)
        @port = @server.addr[1]
        @running = true

        while @running
          begin
            socket = @server.accept
          rescue IOError, Errno::EBADF
            break
          end

          thread = Thread.new { handle_client(socket) }
          @clients_mutex.synchronize { @clients << thread }
        end
      ensure
        @server&.close unless @server&.closed?
      end

      def stop
        @running = false
        @server&.close unless @server&.closed?
        @clients_mutex.synchronize { @clients.each { |thread| thread.join(1) } }
      end

      private

      def handle_client(socket)
        while (line = socket.gets)
          parts = @protocol.parse(line)

          if parts.first&.upcase == "QUIT"
            socket.write(@protocol.format(Rediscraft::Application::Response.ok("OK")))
            break
          end

          socket.write(@protocol.format(@executor.execute(parts)))
        end
      rescue IOError, Errno::ECONNRESET
        nil
      ensure
        socket.close unless socket.closed?
      end
    end
  end
end
