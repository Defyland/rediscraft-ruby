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

The first API is a TCP text protocol. RESP2 now exists as an alternate protocol
adapter for the implemented command set. Full Redis protocol compatibility is
still deferred.

## Data and Consistency Bar

The live source of truth is an in-memory hash guarded by a mutex. AOF replay is
the durability mechanism for the first release.

## Security Bar

Authentication, ACLs, TLS, and protected admin surfaces are out of scope.

## Observability Bar

Observability already includes documentation, testable failure behavior, and
`INFO` keyspace gauges. Request counters and structured metrics remain deferred
until a shared metrics object justifies the coupling.

## Performance Bar

Performance now includes a local benchmark harness plus collected baseline
evidence for GET/SET/MIXED/GET+INFO workloads. Open-loop load testing and AOF-on
profiles remain future work.

## Scalability Bar

The implementation is single-process and runs a single-threaded event loop
(`IO.select` with non-blocking sockets). Sharding, replication, and clustering are
out of scope.

## Operational Cost Bar

Operational cost is intentionally low: one Ruby process and one AOF file.

## Maintainability Bar

Future features must preserve the current boundary rule: protocol at the edge,
command orchestration in application, state rules in domain, file concerns in
infrastructure.

## Readability Bar

Tests should read in command language and explain why each behavior matters.

## Test and CI Bar

Local tests, syntax checks, and GitHub Actions running `bin/check` are part of
the current contract.

## Evidence Matrix

| Criterion | Evidence | Status | Notes |
| --- | --- | --- | --- |
| Product problem is explicit | README.md | Done | Names backend learning as the product problem. |
| Domain can execute the shipped command set | test/unit/command_executor_test.rb | Done | Strings, TTL, `INFO`, and list behavior are covered. |
| TCP protocol is implemented | test/integration/tcp_server_test.rb | Done | Uses real TCP sockets. |
| AOF replay is implemented | test/unit/aof_command_executor_test.rb | Done | Includes partial trailing line behavior. |
| Benchmark evidence exists | benchmarks/baseline.md | Done | Records the `INFO` O(N) stall and O(1) recovery. |
| CI runs the repository contract | .github/workflows/ci.yml | Done | Executes `bin/check` on pushes and pull requests. |
| Quality review is recorded | docs/learning-journal.md | Partial | Structural/Ruby review recorded; no external reviewer. |
