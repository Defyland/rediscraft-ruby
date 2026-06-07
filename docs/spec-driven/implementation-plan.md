# Implementation Plan

## Scope

Build the first Rediscraft release with a text TCP protocol, concurrent clients,
basic Redis-like commands, TTL, and AOF replay.

## Files to Create or Update

- `lib/rediscraft/domain/*`
- `lib/rediscraft/application/*`
- `lib/rediscraft/interface/*`
- `lib/rediscraft/infrastructure/*`
- `test/unit/*`
- `test/integration/*`
- `docs/learning-journal.md`

## Acceptance Criteria Mapping

| Acceptance criterion | Planned evidence |
| --- | --- |
| Commands execute without TCP dependency | `test/unit/command_executor_test.rb` |
| Store owns TTL behavior | `test/unit/store_test.rb` |
| TCP adapter handles clients | `test/integration/tcp_server_test.rb` |
| AOF replays durable state | `test/unit/aof_test.rb` |
| Boundaries are documented | `docs/architecture/module-boundaries.md` |

## Verification Commands

```sh
bin/test
bin/check
```

## Risks

- Ruby thread scheduling is sufficient for learning concurrency but not a
  production Redis performance model.
- A line-oriented protocol is easier to teach but cannot represent arbitrary
  binary-safe values like RESP.

## Deferred Work

- RESP compatibility.
- Snapshot and compaction.
- Metrics and `INFO`.
- Authentication and ACLs.
