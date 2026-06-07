# Senior Readiness Spec

## Product Bar

Rediscraft must read as a backend foundations project, not as a Redis clone
claiming production readiness. The product problem is learning how cache servers
work internally.

## Domain Bar

The domain must own key/value and TTL behavior. It must not depend on TCP,
command parsing, AOF files, or CLI flags.

## Architecture Bar

The project uses a small layered shape: domain, application, infrastructure, and
interface. This is intentionally lighter than a framework architecture.

## API Bar

The first API is a TCP text protocol. RESP compatibility is deferred.

## Data and Consistency Bar

The live source of truth is an in-memory hash guarded by a mutex. AOF replay is
the durability mechanism for the first release.

## Security Bar

Authentication, ACLs, TLS, and protected admin surfaces are out of scope.

## Observability Bar

Observability starts as documentation and testable failure behavior. Metrics are
planned after the core command path is stable.

## Performance Bar

Performance is planned through local benchmarks after command semantics and AOF
replay are implemented.

## Scalability Bar

The first implementation is single-process and thread-per-client. Sharding,
replication, and clustering are out of scope.

## Operational Cost Bar

Operational cost is intentionally low: one Ruby process and one AOF file.

## Maintainability Bar

Future features must preserve the current boundary rule: protocol at the edge,
command orchestration in application, state rules in domain, file concerns in
infrastructure.

## Readability Bar

Tests should read in command language and explain why each behavior matters.

## Test and CI Bar

Local tests and syntax checks are required in the first slice. CI is planned
after the repository has a stable command set.

## Evidence Matrix

| Criterion | Evidence | Status | Notes |
| --- | --- | --- | --- |
| Product problem is explicit | README.md | Done | Names backend learning as the product problem. |
| Domain can execute basic commands | test/unit/command_executor_test.rb | Partial | `PING`, `SET`, and `GET` covered first. |
| TCP protocol is implemented | test/integration | Planned | Added after application behavior. |
| AOF replay is implemented | test/unit | Planned | Added after command set stabilizes. |
| Quality review is recorded | docs/learning-journal.md | Planned | Required before final handoff. |
