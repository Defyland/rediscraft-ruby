# Benchmark Methodology

The harness is [`benchmarks/bench.rb`](../../benchmarks/bench.rb), Ruby stdlib
only. Run it with `ruby benchmarks/bench.rb` (use the project Ruby, 3.4.9). It
spawns its own server, preloads a keyspace, and reports throughput and latency
percentiles per workload.

## Why benchmark at all

The journal makes performance claims ("the single mutex bottlenecks under write
load", "an O(N) command stalls the event loop"). A claim you cannot reproduce
with a number is a hypothesis, not a result. The harness exists to turn those
hypotheses into measurements, and to refute them when they are wrong.

## What it measures and why

- **Closed loop.** A fixed number of connections each send one command, wait for
  the reply, then send the next. This measures service time at a fixed
  concurrency, which is exactly what a single-threaded server offers.
- **Warmup.** The first ops per client are discarded. Connection setup, page
  faults, and code warmup are not steady state.
- **Barrier.** Clients warm up, are released together, and only the measured
  window is timed. Warmup never pollutes throughput.
- **Percentiles, not the mean.** The tail (p99, p999) is what a user feels. A
  mean hides a server that is fast most of the time and frozen the rest.
- **RESP2 on the wire.** Length-prefixed replies parse unambiguously, including
  the multi-line `INFO` bulk that the text protocol cannot frame by line.
- **Server RSS.** Memory after preloading the keyspace, read via `ps`.

## Two traps this harness teaches

- **Nagle on the client.** The first naive version showed a ~48ms p999 that
  vanished once the client set `TCP_NODELAY`. With Nagle on, a small request sits
  in the client kernel while the server's delayed ACK waits to piggyback,
  producing ~40ms stalls that have nothing to do with the server. A benchmark
  with Nagle on the client measures the socket stack, not the server. The harness
  now disables Nagle on every client socket, and the server disables it on every
  accepted socket.
- **Coordinated omission.** A closed loop does not model it: if the server
  stalls, the client simply waits and issues fewer requests, so the stall is
  undercounted. An open-loop client at a fixed arrival rate would queue and show
  the stall more sharply. Read the tail with that caveat.

## Workloads

- `GET` — 100% reads against preloaded keys.
- `SET` — 100% writes.
- `MIXED 90/10` — 90% reads, 10% writes.
- `GET+INFO 1%` — reads with 1% `INFO`, to expose an O(N) command on the
  single-threaded loop.

See [`benchmarks/baseline.md`](../../benchmarks/baseline.md) for collected
numbers and the findings.
