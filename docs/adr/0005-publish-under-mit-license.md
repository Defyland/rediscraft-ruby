# ADR 0005 - Publish the repository under the MIT License

## Status

Accepted.

## Context

Rediscraft is already structured as a didactic systems repository with
architecture notes, protocol decisions, benchmarks, runbooks, and code
walkthrough material. Without an explicit license, that teaching intent stays
visible but the reuse boundary remains legally ambiguous.

## Decision

Publish the repository under the MIT License and expose that decision in the
README.

## Alternatives Rejected

- Keep the default all-rights-reserved posture.
- Delay licensing until more protocol features land.
- Use a more restrictive source-available license.

## Consequences

Readers can fork and adapt the event-loop cache implementation with a clear
reuse boundary. The tradeoff is that downstream users may copy only the code and
drop some of the surrounding operational caveats. That is acceptable because the
repository exists to teach the architecture directly.
