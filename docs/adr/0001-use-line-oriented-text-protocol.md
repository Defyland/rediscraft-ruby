# ADR 0001 - Use a line-oriented text protocol first

## Status

Accepted.

## Context

The project goal is to learn Redis-like mechanics from scratch. RESP is a better
Redis compatibility target, but it adds binary framing and array parsing before
the repository has proved command execution, TCP handling, TTL, and durability.

## Decision

Use one text command per line for the first release.

## Alternatives Rejected

- RESP first: more realistic, but it would make the first slice larger.
- JSON over TCP: easy to parse, but less useful for learning Redis-like command
  protocols.

## Consequences

The client protocol is easy to read. AOF now uses a separate length-prefixed
record format so replay is not limited by the client protocol. The client
protocol itself is still not binary-safe.

## Follow-up

RESP2 was later added as an alternate adapter after the command path, TCP
server, TTL, and AOF were already stable. The original decision remains useful:
it kept the first implementation small and made the later RESP adapter easier to
compare against the text protocol.
