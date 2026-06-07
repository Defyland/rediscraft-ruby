# Benchmark Methodology

Benchmarks are deferred until the command and AOF semantics are stable. The
first useful benchmark should measure:

- single-client `SET`/`GET` latency
- concurrent clients
- AOF enabled vs disabled
- memory growth with many keys
