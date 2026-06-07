# ADR 0002 - Use a mutex-protected hash for v1 state

## Status

Accepted.

## Context

The first server supports multiple TCP clients. Ruby threads can interleave
access to shared state even with the GVL, so the store needs an explicit
correctness boundary.

## Decision

Use a single `Mutex` around a Ruby hash in `Rediscraft::Domain::Store`.

## Alternatives Rejected

- No lock: simpler, but it teaches the wrong concurrency lesson.
- Sharded locks: useful later, but speculative before benchmarks.
- Actor loop: clear ownership, but larger than the current command set needs.

## Consequences

The store is easy to reason about and test. Write-heavy throughput will be
limited by the single mutex.
