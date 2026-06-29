# Roadmap

1. Add an `INFO` request counter through a shared metrics object.
2. Add auto-compaction by AOF growth ratio on top of manual compaction.
3. Expand the benchmark matrix to AOF-on and slow-client/backpressure workloads.
4. Add a bounded keyspace with `maxmemory` and an eviction policy.
5. Add replication over the durable-command stream.
6. Keep auth local-only unless the repo is explicitly reframed as an ops product.
