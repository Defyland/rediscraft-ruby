#!/usr/bin/env ruby
# frozen_string_literal: true

# Benchmark harness for Rediscraft.
#
# Why this exists: the journal makes many performance claims ("the single mutex
# is a bottleneck", "an O(N) command stalls the event loop") that were never
# measured. A claim you cannot reproduce with a number is a hypothesis, not a
# result. This harness turns those hypotheses into measurements.
#
# How it measures (the parts that matter):
#   - Closed loop: a fixed number of client connections each send one command,
#     wait for the reply, then send the next. This measures service time under a
#     fixed concurrency, which is what a single-threaded server actually offers.
#   - Warmup: the first ops per client are discarded (connection setup, page
#     faults, code warmup). You measure steady state, not cold start.
#   - Barrier: every client warms up, then they are released together, and only
#     the measured window is timed. Warmup never pollutes throughput.
#   - Percentiles, not mean: the tail (p99, p999) is what a user feels. A mean
#     hides a server that is fast 90% of the time and frozen the other 10%.
#   - RESP2 on the wire: length-prefixed replies parse unambiguously, including
#     the multi-line INFO bulk that the text protocol cannot frame by line.
#
# What it does NOT capture (be honest): this is a closed loop, so it does not
# model coordinated omission. If the server stalls, a closed-loop client simply
# waits and sends fewer requests; an open-loop client at a fixed arrival rate
# would queue and expose the stall more sharply. Read the tail with that caveat.

require "socket"
require "optparse"
require "rbconfig"

# --- RESP2 wire helpers ---------------------------------------------------

# TCP_NODELAY disables Nagle's algorithm on the client side. Without it, a small
# request can sit in the client kernel waiting to coalesce, and the server's
# delayed ACK waits to piggyback, producing ~40ms stalls that have nothing to do
# with the server. Measurement hygiene: take Nagle off the client so the harness
# measures the server, not the socket stack.
def connect(host, port)
  socket = TCPSocket.new(host, port)
  socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
  socket.sync = true
  socket
end

def encode(args)
  out = +"*#{args.length}\r\n"
  args.each do |arg|
    text = arg.to_s
    out << "$#{text.bytesize}\r\n#{text}\r\n"
  end
  out
end

def read_reply(socket)
  header = socket.gets("\r\n")
  raise "connection closed" if header.nil?

  type = header[0]
  body = header[1..].chomp("\r\n")

  case type
  when "+", "-", ":"
    body
  when "$"
    length = body.to_i
    return nil if length.negative?

    payload = socket.read(length)
    socket.read(2) # trailing CRLF
    payload
  when "*"
    count = body.to_i
    count.negative? ? nil : Array.new(count) { read_reply(socket) }
  else
    raise "unexpected reply prefix: #{type.inspect}"
  end
end

# --- statistics -----------------------------------------------------------

def percentile(sorted_seconds, p)
  return 0.0 if sorted_seconds.empty?

  index = ((p / 100.0) * (sorted_seconds.length - 1)).round
  sorted_seconds[index]
end

def ms(seconds)
  format("%.3f", seconds * 1000)
end

# --- server lifecycle -----------------------------------------------------

def with_server(aof:)
  root = File.expand_path("..", __dir__)
  port = 7390 + rand(1000)
  args = [RbConfig.ruby, File.join(root, "bin", "rediscraft"),
          "--host", "127.0.0.1", "--port", port.to_s, "--protocol", "resp2"]
  aof_path = nil
  if aof
    aof_path = File.join(Dir.tmpdir, "rediscraft-bench-#{port}.aof")
    args += ["--aof", aof_path]
  end

  pid = Process.spawn(*args, out: File::NULL, err: File::NULL)
  wait_for_port("127.0.0.1", port)
  yield "127.0.0.1", port, pid
ensure
  if pid
    Process.kill("TERM", pid)
    Process.wait(pid)
  end
  File.delete(aof_path) if aof_path && File.exist?(aof_path)
end

def wait_for_port(host, port, timeout: 5)
  deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
  loop do
    TCPSocket.new(host, port).close
    return
  rescue Errno::ECONNREFUSED, Errno::ECONNRESET
    raise "server did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

    sleep 0.02
  end
end

def server_rss_mb(pid)
  rss_kb = `ps -o rss= -p #{pid}`.strip.to_i
  rss_kb / 1024.0
end

def preload(host, port, keys)
  socket = connect(host, port)
  keys.times do |i|
    socket.write(encode(["SET", "key#{i}", "value#{i}"]))
    read_reply(socket)
  end
  socket.close
end

# --- one scenario ---------------------------------------------------------

Scenario = Struct.new(:name, :generator, keyword_init: true)

def run_scenario(scenario, host:, port:, clients:, ops:, warmup:, keyspace:)
  ready = Queue.new
  go = Queue.new

  threads = Array.new(clients) do
    Thread.new do
      socket = connect(host, port)
      warmup.times do
        socket.write(encode(scenario.generator.call(keyspace)))
        read_reply(socket)
      end
      ready << true
      go.pop

      latencies = Array.new(ops) do
        command = encode(scenario.generator.call(keyspace))
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        socket.write(command)
        read_reply(socket)
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
      socket.close
      latencies
    end
  end

  clients.times { ready.pop }
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  clients.times { go << true }
  latencies = threads.flat_map(&:value)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

  sorted = latencies.sort
  {
    name: scenario.name,
    throughput: (latencies.length / elapsed).round,
    p50: percentile(sorted, 50),
    p99: percentile(sorted, 99),
    p999: percentile(sorted, 99.9)
  }
end

# --- workloads ------------------------------------------------------------

WORKLOADS = [
  Scenario.new(name: "GET", generator: ->(k) { ["GET", "key#{rand(k)}"] }),
  Scenario.new(name: "SET", generator: ->(k) { ["SET", "key#{rand(k)}", "v#{rand(1000)}"] }),
  Scenario.new(name: "MIXED 90/10", generator: lambda do |k|
    rand(10).zero? ? ["SET", "key#{rand(k)}", "v"] : ["GET", "key#{rand(k)}"]
  end),
  Scenario.new(name: "GET+INFO 1%", generator: lambda do |k|
    rand(100).zero? ? ["INFO"] : ["GET", "key#{rand(k)}"]
  end)
].freeze

# --- main -----------------------------------------------------------------

options = { clients: 16, ops: 5000, warmup: 1000, keys: 50_000, aof: false }
OptionParser.new do |parser|
  parser.banner = "Usage: ruby benchmarks/bench.rb [options]"
  parser.on("--clients N", Integer, "Concurrent connections") { |v| options[:clients] = v }
  parser.on("--ops N", Integer, "Measured ops per client") { |v| options[:ops] = v }
  parser.on("--warmup N", Integer, "Warmup ops per client") { |v| options[:warmup] = v }
  parser.on("--keys N", Integer, "Keyspace preloaded before measuring") { |v| options[:keys] = v }
  parser.on("--aof", "Run the server with AOF enabled") { options[:aof] = true }
end.parse!

require "tmpdir"

with_server(aof: options[:aof]) do |host, port, pid|
  warn "preloading #{options[:keys]} keys..."
  preload(host, port, options[:keys])
  rss = server_rss_mb(pid)

  puts "Rediscraft benchmark  (RESP2, AOF=#{options[:aof]})"
  puts "clients=#{options[:clients]} ops/client=#{options[:ops]} warmup=#{options[:warmup]} " \
       "keyspace=#{options[:keys]} server_rss=#{format('%.1f', rss)}MB"
  puts
  puts format("%-14s %14s %10s %10s %10s", "workload", "throughput/s", "p50 ms", "p99 ms", "p999 ms")
  puts "-" * 62

  WORKLOADS.each do |scenario|
    result = run_scenario(scenario, host: host, port: port,
      clients: options[:clients], ops: options[:ops], warmup: options[:warmup], keyspace: options[:keys])
    puts format("%-14s %14d %10s %10s %10s",
      result[:name], result[:throughput], ms(result[:p50]), ms(result[:p99]), ms(result[:p999]))
  end
end
