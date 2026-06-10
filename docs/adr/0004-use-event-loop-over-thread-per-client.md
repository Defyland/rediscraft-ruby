# ADR 0004 - Use a single-threaded event loop over thread-per-client

## Status

Accepted. Supersedes the concurrency model implied by ADR 0002, but not its
decision: the store keeps its mutex (see Consequences).

## Context

The first server gave each client its own thread and blocked on
`protocol.read_request(io)`. That is the most direct model to read, but it does
not teach IO multiplexing, it grows one thread per connection, and it makes the
read path block a whole thread on a slow client. The project is now mature enough
to show the model that real cache servers use.

## Decision

Replace thread-per-client with a single-threaded reactor in
`Rediscraft::Interface::TcpServer`: one thread runs `IO.select` over the listener,
a shutdown self-pipe, and every client socket, using non-blocking reads and
writes. Each connection owns a read buffer and a write buffer, so a command may
arrive or leave across several TCP segments.

The protocol contract changes from pull-based blocking `read_request(io)` to
push-based incremental `consume(buffer)`, which returns `[parts, rest]` for a
complete frame, `nil` when more bytes are needed, and raises `ProtocolError` on a
malformed frame.

## Alternatives Rejected

- Keep thread-per-client: simplest, but hides the multiplexing lesson and scales
  threads with connections.
- A thread pool: bounds threads, but still blocks a worker per slow client and
  adds a work queue before the reactor lesson is clear.
- An async library (async/nio4r): production-shaped, but a gem dependency hides
  the `IO.select` mechanics the project exists to teach.

## Consequences

The server now multiplexes all clients on one thread, handles partial frames,
and shuts down by waking the loop through a self-pipe. The concurrency model is
confined to the interface layer: the application and domain layers keep their
mutexes on purpose, so they stay correct regardless of how the interface drives
them. Those mutexes are now uncontended, not wrong. A single CPU-bound command
still stalls the loop, because there is one thread; that is the accepted trade of
the model, the same one Redis makes.
