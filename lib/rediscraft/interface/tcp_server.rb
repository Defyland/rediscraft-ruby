# frozen_string_literal: true

require "socket"
require "thread"
require "rediscraft/application/response"
require "rediscraft/interface/protocol_error"
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
        @clients = {}
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
          @clients_mutex.synchronize { @clients[thread] = socket }
          start_gate << true
        end
      ensure
        @server&.close unless @server&.closed?
      end

      def stop
        @running = false
        @server&.close unless @server&.closed?
        clients = @clients_mutex.synchronize { @clients.dup }
        clients.each_value { |socket| close_client_socket(socket) }
        clients.each_key { |thread| thread.join(1) }
      end

      def tracked_client_count
        @clients_mutex.synchronize { @clients.count }
      end

      private

      def handle_client(socket)
        while (parts = @protocol.read_request(socket))

          if parts.first&.upcase == "QUIT"
            socket.write(@protocol.format(Rediscraft::Application::Response.simple("OK")))
            break
          end

          socket.write(@protocol.format(@executor.execute(parts)))
        end
      rescue ProtocolError
        write_protocol_error(socket)
      rescue IOError, Errno::ECONNRESET
        nil
      ensure
        socket.close unless socket.closed?
      end

      def write_protocol_error(socket)
        response = Rediscraft::Application::Response.error("ERR protocol error")
        socket.write(@protocol.format(response))
      rescue IOError, Errno::ECONNRESET, Errno::EPIPE
        nil
      end

      def close_client_socket(socket)
        return if socket.closed?

        begin
          socket.shutdown(Socket::SHUT_RDWR)
        rescue IOError, Errno::ENOTCONN, Errno::EBADF
          nil
        end

        socket.close unless socket.closed?
      rescue IOError, Errno::EBADF
        nil
      end
    end
  end
end
