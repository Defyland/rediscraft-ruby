# ADR 0003 - Use AOF before snapshot

## Status

Accepted.

## Context

The learning goal is to understand durable command replay before optimizing
startup time or disk footprint.

## Decision

Persist valid durable commands as append-only length-prefixed records before
applying them to memory. Replay applies internal records directly to the store.

## Alternatives Rejected

- Snapshot first: simpler to restore, but hides command history and recovery
  ordering.
- Embedded database: reliable, but skips the persistence lesson.

## Consequences

AOF is deterministic and safe for values containing whitespace or newlines. It
is less human-readable than the first text-line version, can grow without bound,
and needs future compaction or snapshots.
