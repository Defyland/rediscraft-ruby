# Rediscraft Ruby

## 1. What is this product?

Rediscraft Ruby is a Redis-like in-memory key-value server built from scratch in
CRuby. It is a study repository for backend engineers who want to understand the
mechanics behind cache servers: command parsing, TCP clients, shared mutable
state, TTL expiration, append-only persistence, and recovery.

## 2. Problem it solves

Backend engineers often use Redis without seeing the hidden costs behind simple
commands. Rediscraft makes those mechanics explicit in a small Ruby codebase
that can be read in order and extended one feature at a time.

## 3. Target users

The main user is a backend engineer studying storage, networking, and
operability fundamentals. The repository is not a Redis replacement.

## 4. Main features

- Text protocol over TCP, plus RESP2 as an alternate protocol adapter.
- Commands: `PING`, `SET`, `GET`, `DEL`, `EXISTS`, `EXPIRE`, `TTL`, `PERSIST`,
  `INFO`, and `QUIT`.
- Single-threaded event-loop server (`IO.select`) over a thread-safe in-memory store.
- Lazy TTL expiration, deterministic between live execution and AOF replay.
- Append-only file persistence with replay on startup, optional `fsync`, and
  compaction that rewrites the log from live state.
- `INFO` keyspace gauges (`keys`, `keys_with_expiry`).
- Minitest coverage for domain, application, protocol, server, and AOF behavior.

## 5. Architecture overview

Rediscraft keeps the code split by responsibility:

- `lib/rediscraft/domain`: key/value state and TTL rules.
- `lib/rediscraft/application`: command execution use case.
- `lib/rediscraft/infrastructure`: AOF persistence.
- `lib/rediscraft/interface`: TCP protocol and server adapter.

The TCP layer parses input and formats output. The application layer executes
commands. The domain owns value and expiration behavior.

## 6. Tech stack

- Ruby 3.4.x, CRuby.
- Ruby standard library: `socket`, `thread`, `time`, and `minitest`.
- No Rails and no runtime gems.

## 7. Domain model

The core aggregate is a key entry: string key, string value, and optional
absolute expiration time. Expired entries may remain physically present until a
read or mutation observes them, but public reads must treat them as missing.

## 8. API documentation

The public API is TCP. The first protocol is a line-oriented text protocol; the
second is RESP2. See [docs/api/protocol.md](docs/api/protocol.md). `openapi.yaml`
is intentionally a non-HTTP marker because this is not an HTTP API.

## 9. Async or event architecture

The TCP server is a single-threaded reactor: one thread multiplexes every client
with `IO.select` and non-blocking sockets, buffering partial frames per
connection. There is no broker or domain event stream; AOF records are internal
durability records. See
[docs/adr/0004-use-event-loop-over-thread-per-client.md](docs/adr/0004-use-event-loop-over-thread-per-client.md).

## 10. Database design

There is no external database. Live state is an in-memory hash protected by a
mutex. Durability is provided by append-only command records and startup replay.

## 11. Testing strategy

The suite covers command behavior, TTL invariants, parser/formatter behavior,
TCP request handling, concurrent clients, and AOF replay.

## 12. Performance benchmarks

Performance work is intentionally deferred until the protocol and durability
rules are stable. Benchmark methodology is documented in
[docs/benchmarks/methodology.md](docs/benchmarks/methodology.md).

## 13. Observability

`INFO` exposes keyspace gauges (`keys`, `keys_with_expiry`) read from live store
state. A request counter is intentionally deferred until a shared metrics object
justifies coupling the executor to the dispatch point; full metrics
(Prometheus/tracing) remain out of scope.

## 14. Security considerations

The server has no authentication and should bind only to trusted local
interfaces. See [docs/security/threat-model.md](docs/security/threat-model.md).

## 15. Trade-offs and decisions

Key decisions live under [docs/adr](docs/adr). The first version chooses a text
protocol before RESP, one process before clustering, and a mutex-protected hash
before sharding.

## 16. How to run locally

```sh
ruby bin/rediscraft --host 127.0.0.1 --port 7379 --aof data/rediscraft.aof
ruby bin/rediscraft --host 127.0.0.1 --port 7379 --protocol resp2
ruby bin/rediscraft --aof data/rediscraft.aof --fsync --compact-on-start
```

Then connect:

```sh
nc 127.0.0.1 7379
```

## 17. How to run tests

```sh
bin/test
bin/check
```

## 18. Failure scenarios

- A partial trailing AOF record is ignored during replay.
- Expired keys are removed lazily when read or mutated.
- A TCP client disconnect closes only that connection in the event loop.
- The server is not safe for untrusted networks.

## 19. Roadmap

- Add an `INFO` request counter once a shared metrics object justifies it.
- Add auto-compaction by growth ratio on top of the existing manual compaction.
- Expand RESP compatibility and add protocol negotiation only if it teaches a
  concrete boundary lesson.
- Add simple benchmarks for throughput and memory growth.
