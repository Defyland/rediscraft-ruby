# Benchmark Baseline

Collected with [`benchmarks/bench.rb`](bench.rb). Numbers are machine-specific
(here: Apple Silicon, Ruby 3.4.9, loopback, AOF off) and are meant to show shape
and relative cost, not absolute peak. Reproduce with:

```sh
ruby benchmarks/bench.rb --clients 8 --ops 3000 --warmup 1000 --keys 50000
```

## Result

```
clients=8 ops/client=3000 warmup=1000 keyspace=50000 server_rss~41MB

workload         throughput/s     p50 ms     p99 ms    p999 ms
--------------------------------------------------------------
GET                     27072      0.207      1.473      5.433
SET                     33138      0.195      0.527      2.373
MIXED 90/10             29651      0.194      1.461      6.192
GET+INFO 1%              9691      0.273      7.034     11.781
```

## Findings

1. **GET and SET are in the same range (~27k-33k ops/s).** Both are O(1) under a
   single mutex; the read and write paths cost about the same. An early run
   showed GET 7x slower with a 48ms tail; that was Nagle on the *client*, not the
   server. See the methodology note on measurement hygiene.

2. **1% `INFO` cuts throughput ~3x and triples the tail.** `GET+INFO 1%` drops to
   ~9.7k ops/s with p999 ~12ms, versus `MIXED` at ~30k ops/s and p999 ~6ms. Only
   1% of operations are `INFO`, yet every client slows down. This is the
   single-threaded event loop meeting an O(N) command: `INFO` walks the whole
   keyspace ([`Store#keyspace_summary`](../lib/rediscraft/domain/store.rb)) on the
   one thread that serves everyone, so while it runs no other client is served.
   The journal asserted "an O(N) command stalls the loop"; this is that assertion
   measured. The fix is to make `INFO` O(1) with incremental counters.

3. **Server-side `TCP_NODELAY` had an effect within noise here.** It is still the
   right default (Redis sets it), but in this workload the server always has a
   reply ready to send, so Nagle rarely engages. It matters more under pipelining
   and partial writes.
