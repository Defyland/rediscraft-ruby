# Engineering Case Study

## 1. Product Context

Rediscraft is a study product for backend engineers. It recreates a small
Redis-like server in Ruby so the reader can inspect command parsing, TCP
clients, shared state, TTL, AOF, and replay without depending on Redis itself.

## 2. Domain Model

The core aggregate is an entry with a string value and optional absolute
expiration. The invariant is simple: expired keys must not be visible through
public reads, existence checks, or TTL.

## 3. Architecture

The repository uses four boundaries:

- Domain: `Rediscraft::Domain::Store`.
- Application: `Rediscraft::Application::CommandExecutor`.
- Infrastructure: `Rediscraft::Infrastructure::AofLog`.
- Interface: `Rediscraft::Interface::TcpServer` and `TextProtocol`.

This shape is intentionally small. It teaches where logic belongs without
turning the project into framework ceremony.

## 4. Key Trade-offs

The text protocol is easier to learn than RESP, but it is not binary-safe. A
single mutex is easy to reason about, but limits write throughput. AOF teaches
replay, but grows forever without compaction.

## 5. Data Model

Live data is a Ruby hash protected by `Mutex`. Durable data is a length-prefixed
AOF frame containing command parts. Public `EXPIRE` is persisted internally as
`EXPIREAT` so restarts preserve the absolute expiration time instead of
resetting TTL.

## 6. Consistency Model

Commands execute in a single process. Store mutation is synchronized by one
mutex. In AOF mode, durable records are appended before the in-memory mutation
is applied, so append failure prevents the store from changing.

## 7. Failure Scenarios

Partial trailing AOF frames are ignored. Client disconnects close only that
connection in the event loop, and closed connections are removed from tracking.
Expired entries are removed lazily.

## 8. Performance Strategy

The first strategy is correctness before speed. Benchmarks are deferred until
the command set and durability behavior are stable.

## 9. Scalability Strategy

The current server is a single process running a single-threaded event loop
(`IO.select` with non-blocking sockets), the same model Redis uses. Future scale
work would measure per-command cost, then consider sharded maps or multiple event
loops before reintroducing threads.

## 10. Security Model

There is no authentication, TLS, or ACL. The server is for trusted local
networks only.

## 11. Observability

The first release has tests and documented failure modes. `INFO`, counters, and
structured logs are planned after core semantics.

## 12. Operational Cost

The operating footprint is one Ruby process and one AOF file. Debug cost remains
low because the protocol is human-readable and the AOF frame format is small,
although less readable than plain text lines.

## 13. Maintainability

Boundaries are small and testable. Future commands should first be added in
application/domain tests, then exposed through TCP if needed.

## 14. Product Decisions

The product is intentionally not a production Redis replacement. It is a
learning artifact for backend fundamentals.

## 15. What I Would Do Next

Add `INFO`, AOF fsync policy, compaction, snapshots, RESP parsing, and local
benchmarks in that order.
