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

The protocol is easy to read and replay in AOF. It is not binary-safe and cannot
represent arbitrary values yet.
