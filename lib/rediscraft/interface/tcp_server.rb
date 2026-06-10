# frozen_string_literal: true

require "socket"
require "rediscraft/application/response"
require "rediscraft/interface/protocol_error"
require "rediscraft/interface/text_protocol"

module Rediscraft
  module Interface
    # Single-threaded reactor: one thread multiplexes every client with
    # IO.select and non-blocking sockets. Each connection keeps its own read and
    # write buffers, so a command can arrive or leave in several TCP segments.
    class TcpServer
      attr_reader :port

      READ_CHUNK = 4096

      Connection = Struct.new(:socket, :read_buffer, :write_buffer, :close_after_flush) do
        def write_pending?
          !write_buffer.empty?
        end
      end

      def initialize(host:, port:, executor:, protocol: TextProtocol.new)
        @host = host
        @requested_port = port
        @executor = executor
        @protocol = protocol
        @connections = {}
        @connections_mutex = Mutex.new
      end

      def start
        @server = TCPServer.new(@host, @requested_port)
        @shutdown_reader, @shutdown_writer = IO.pipe
        @port = @server.addr[1]

        event_loop
      ensure
        shutdown_all
      end

      # Called from another thread (test harness) or a signal handler. It only
      # wakes the loop through the self-pipe; the loop thread owns the cleanup.
      def stop
        @shutdown_writer&.write("x")
      rescue IOError
        nil
      end

      def tracked_client_count
        @connections_mutex.synchronize { @connections.size }
      end

      private

      def event_loop
        loop do
          ready = IO.select([@server, @shutdown_reader] + connection_sockets, pending_write_sockets, nil)
          next unless ready

          break if ready[0].include?(@shutdown_reader)

          ready[0].each { |io| handle_readable(io) }
          ready[1].each { |io| flush(@connections[io]) if @connections[io] }
        end
      end

      def handle_readable(io)
        if io == @server
          accept_connection
        elsif io != @shutdown_reader
          conn = @connections[io]
          read_from(conn) if conn
        end
      end

      def accept_connection
        socket = @server.accept_nonblock
        socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        @connections_mutex.synchronize do
          @connections[socket] = Connection.new(socket, +"", +"", false)
        end
      rescue IO::WaitReadable, Errno::ECONNABORTED
        nil
      end

      def read_from(conn)
        conn.read_buffer << conn.socket.read_nonblock(READ_CHUNK)
        process_buffer(conn)
      rescue IO::WaitReadable
        nil
      rescue EOFError, Errno::ECONNRESET
        close_connection(conn)
      rescue ProtocolError
        enqueue_write(conn, @protocol.format(Rediscraft::Application::Response.error("ERR protocol error")))
        conn.close_after_flush = true
        flush(conn)
      end

      def process_buffer(conn)
        loop do
          result = @protocol.consume(conn.read_buffer)
          break if result.nil?

          parts, rest = result
          conn.read_buffer.replace(rest)
          enqueue_write(conn, @protocol.format(dispatch(parts, conn)))
          break if conn.close_after_flush
        end

        flush(conn)
      end

      def dispatch(parts, conn)
        if parts.first&.upcase == "QUIT"
          conn.close_after_flush = true
          return Rediscraft::Application::Response.simple("OK")
        end

        @executor.execute(parts)
      end

      def enqueue_write(conn, bytes)
        conn.write_buffer << bytes
      end

      def flush(conn)
        until conn.write_buffer.empty?
          written = conn.socket.write_nonblock(conn.write_buffer)
          conn.write_buffer.replace(conn.write_buffer.byteslice(written..) || "")
        end

        close_connection(conn) if conn.close_after_flush
      rescue IO::WaitWritable
        nil
      rescue EOFError, Errno::ECONNRESET, Errno::EPIPE
        close_connection(conn)
      end

      def close_connection(conn)
        @connections_mutex.synchronize { @connections.delete(conn.socket) }
        conn.socket.close unless conn.socket.closed?
      rescue IOError
        nil
      end

      def connection_sockets
        @connections_mutex.synchronize { @connections.keys }
      end

      def pending_write_sockets
        @connections_mutex.synchronize do
          @connections.values.select(&:write_pending?).map(&:socket)
        end
      end

      def shutdown_all
        @connections_mutex.synchronize { @connections.values.dup }.each do |conn|
          close_connection(conn)
        end

        @server.close if @server && !@server.closed?
        [@shutdown_reader, @shutdown_writer].each { |io| io.close if io && !io.closed? }
      end
    end
  end
end
