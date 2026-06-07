# ADR 0003 - Use AOF before snapshot

## Status

Accepted.

## Context

The learning goal is to understand durable command replay before optimizing
startup time or disk footprint.

## Decision

Persist successful mutating commands as append-only text records and replay them
on startup.

## Alternatives Rejected

- Snapshot first: simpler to restore, but hides command history and recovery
  ordering.
- Embedded database: reliable, but skips the persistence lesson.

## Consequences

AOF is readable and easy to test. It can grow without bound and needs future
compaction or snapshots.
