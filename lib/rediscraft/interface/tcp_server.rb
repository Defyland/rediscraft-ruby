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

          start_gate = Queue.new
          thread = Thread.new do
            start_gate.pop

            begin
              handle_client(socket)
            ensure
              @clients_mutex.synchronize { @clients.delete(Thread.current) }
            end
          end
          @clients_mutex.synchronize { @clients << thread }
          start_gate << true
        end
      ensure
        @server&.close unless @server&.closed?
      end

      def stop
        @running = false
        @server&.close unless @server&.closed?
        clients = @clients_mutex.synchronize { @clients.dup }
        clients.each { |thread| thread.join(1) }
      end

      def tracked_client_count
        @clients_mutex.synchronize { @clients.count }
      end

      private

      def handle_client(socket)
        while (line = socket.gets)
          parts = @protocol.parse(line)

          if parts.first&.upcase == "QUIT"
            socket.write(@protocol.format(Rediscraft::Application::Response.simple("OK")))
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
