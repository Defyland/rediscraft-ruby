# Guided Code Walkthrough

## 1. Why this document exists

The learning journal explains why the design changed over time. This document
does a different job: it walks the current codebase as code.

Use it when you want answers to questions like:

- Which file should I open first?
- What does each core method do?
- Why is this method in this layer?
- What Ruby syntax is this project using?

If you want the history of the decisions, read `docs/learning-journal.md`.
If you want to understand the code that exists today, read this file first.

## 2. The shortest useful reading order

1. `README.md`
2. `docs/api/protocol.md`
3. `bin/rediscraft`
4. `lib/rediscraft/application/command_registry.rb`
5. `lib/rediscraft/application/command_executor.rb`
6. `lib/rediscraft/domain/store.rb`
7. `lib/rediscraft/application/aof_command_executor.rb`
8. `lib/rediscraft/infrastructure/aof_log.rb`
9. `lib/rediscraft/interface/text_protocol.rb`
10. `lib/rediscraft/interface/resp2_protocol.rb`
11. `lib/rediscraft/interface/response_formatting.rb`
12. `lib/rediscraft/interface/tcp_server.rb`
13. `test/`
14. `docs/learning-journal.md`

Why this order:

- `bin/rediscraft` shows the assembly root.
- `CommandRegistry` shows the public contract.
- `CommandExecutor` shows the use cases.
- `Store` shows the business rules and data shape.
- `AofCommandExecutor` and `AofLog` show durability.
- The protocol files show framing.
- `TcpServer` shows how everything is driven over sockets.

## 3. One request from socket to reply

Take this text command:

```text
SET name Ada
```

The path is:

1. `TcpServer#read_from` appends bytes into `conn.read_buffer`.
2. `TcpServer#process_buffer` asks the selected protocol to `consume(buffer)`.
3. `TextProtocol#consume` returns `["SET", "name", "Ada"]` plus leftover bytes.
4. `TcpServer#dispatch` calls `executor.execute(parts)`.
5. `CommandExecutor#execute` validates the command against `CommandRegistry`.
6. `CommandExecutor#execute_set` calls `Store#set`.
7. `Store#set` replaces the entry under the mutex and updates counters.
8. `CommandExecutor` returns `Response.simple("OK")`.
9. `TcpServer` asks the protocol to `format(response)`.
10. `TextProtocol` turns that response into `+OK\n`.
11. `TcpServer#flush` writes bytes back to the socket.

That is the main rule of the project:

- interface parses and formats;
- application validates and orchestrates;
- domain changes state;
- infrastructure persists.

## 4. The assembly root: `bin/rediscraft`

Open `bin/rediscraft` when you want to know how the process is wired.

What it does:

- loads the library path;
- parses CLI flags with `OptionParser`;
- chooses `TextProtocol` or `Resp2Protocol`;
- creates `Store`;
- wraps the executor with AOF when `--aof` is present;
- builds `TcpServer`;
- installs `INT` and `TERM` handlers;
- starts the server.

Why it matters:

- this is the composition root;
- dependency wiring stays here instead of leaking into domain or application;
- reading it tells you what is optional and what is always on.

Ruby syntax to notice:

- `options = { host: "127.0.0.1" }`
  This is a Hash with symbol keys.
- `parser.on("--port PORT", Integer, "...") { |value| ... }`
  The block runs when the option appears.
- `case options[:protocol]`
  Standard Ruby `case`, used as a small protocol selector.

## 5. The public command contract: `CommandRegistry`

Open `lib/rediscraft/application/command_registry.rb` next.

This file owns three things:

- which commands are public;
- how many arguments each command accepts;
- whether a command must be written to AOF.

Important methods:

- `Spec#valid_arity?`
  Accepts both fixed arity and variadic arity.
- `.fetch(command)`
  Resolves a command name after normalization.
- `.durable_parts_for(parts, clock:)`
  Turns public commands into AOF records.

Why the file is useful:

- it prevents command knowledge from being duplicated between live execution and
  durability;
- it keeps the executor small;
- it makes tests read like contract checks, not implementation checks.

Ruby syntax to notice:

- `Data.define(:name, :arity, :durable)`
  `Data` is a small immutable value object built into modern Ruby.
- `arity === parts.length`
  This is deliberate. For `Integer`, `===` means equality. For `Range`, it means
  membership. That lets one method support both `3` and `(3..)`.
- `(3..)`
  Endless range. Here it means "three or more parts".
- `command&.upcase`
  Safe navigation. If `command` is `nil`, the whole expression returns `nil`
  instead of crashing.

## 6. The use-case layer: `CommandExecutor`

Open `lib/rediscraft/application/command_executor.rb` after the registry.

This is the application layer. It knows the public commands and how to turn them
into store operations, but it does not know TCP framing or files.

Read these methods in order:

- `#execute`
  Main dispatch. Validate, then route to a private command method.
- `#apply_durable`
  Replay path for AOF.
- `#execute_expire`
  Good example of application validation before reaching the domain.
- `#execute_lrange`
  Good example of input parsing that belongs in application, not in the store.

Why the rescue for `TypeMismatch` lives here:

- the domain raises a domain error;
- the application translates it into a user-facing protocol-independent error;
- the protocols later decide only how that error is encoded on the wire.

One design choice worth noticing:

- `apply_durable` reuses `execute` for all public commands and handles only
  internal `EXPIREAT` separately.

That is important because it gives live execution and replay one shared behavior
path instead of two drifting dispatch tables.

## 7. The domain core: `Store`

Open `lib/rediscraft/domain/store.rb` slowly. This is the densest file in the
project because it owns the real rules.

What the store owns:

- key existence;
- value type;
- TTL semantics;
- lazy expiration;
- active expiration;
- physical counters for `INFO`;
- snapshot extraction.

Read these methods in order:

1. `#set`, `#get`, `#delete`, `#exist?`
2. `#expire`, `#expire_at`, `#ttl`, `#persist`
3. `#list_push`, `#list_length`, `#list_range`
4. `#keyspace_summary`, `#snapshot`, `#active_expire_cycle`
5. `#store_entry`, `#remove_entry`, `#live_entry_for`

Why the private methods matter so much:

- `store_entry` and `remove_entry` are the only places allowed to touch the
  Hash directly;
- that is what keeps key counters and expiry counters from drifting.

Why `live_entry_for` is load-bearing:

- every public read goes through it;
- it performs lazy expiration;
- if a key is expired, it evicts it before the rest of the method continues.

Type handling:

- strings are stored as plain Ruby `String`;
- lists are stored as Ruby `Array`;
- `TypeMismatch` is raised when a command hits the wrong stored type.

Ruby syntax to notice:

- `@mutex.synchronize do ... end`
  The critical section. Only one thread may execute that block at a time.
- `entry&.expires_at`
  Safe navigation again, but now on an object.
- `filter_map`
  Combine "filter nils out" and "map the rest".
- `list[from..to] || []`
  Slice a range; if Ruby returns `nil`, normalize to an empty list.

## 8. The durability decorator: `AofCommandExecutor`

Open `lib/rediscraft/application/aof_command_executor.rb`.

This class is small on purpose. It is a decorator around the live executor.

What it adds:

- append-before-mutate for durable commands;
- AOF compaction;
- translation from current in-memory snapshot back into replayable records.

Read these methods:

- `#execute`
  If the command is not durable, delegate directly.
  If it is durable, append first, then apply under one mutex.
- `#compact`
  Convert the live snapshot into a minimal AOF.
- `#records_for`
  Turn one entry into one or more durable records.

Why the mutex is here even with a single-threaded reactor:

- this class belongs to application, not to TCP;
- the application should remain correct even if another driver uses threads.

## 9. The AOF file codec: `AofLog`

Open `lib/rediscraft/infrastructure/aof_log.rb`.

This file owns file IO and framing for durable records.

Read these methods:

- `#append`
  Write one frame to disk.
- `#rewrite`
  Build a temporary file and atomically rename it.
- `#replay`
  Read each frame and hand it to the applicator.
- `#encode` and `#decode`
  The durable wire format.
- `#read_frame`
  The outer frame boundary reader.

What to notice:

- this is not RESP on disk;
- the AOF has its own tiny length-prefixed format;
- `fsync` of the file and `fsync` of the directory are different guarantees;
- malformed or partial trailing data is tolerated by ignoring that frame.

Ruby syntax to notice:

- `File.open(path, "ab")`
  Open for binary append.
- `parts.map do |part| ... end`
  Build encoded pieces from each command part.
- `source.byteslice(cursor, length)`
  Byte-oriented slicing, used because framing is about bytes, not characters.

## 10. The protocol adapters: text and RESP2

Open these files together:

- `lib/rediscraft/interface/text_protocol.rb`
- `lib/rediscraft/interface/resp2_protocol.rb`
- `lib/rediscraft/interface/response_formatting.rb`

The key idea:

- both protocols solve the same two problems:
  parse bytes into command parts;
  format `Response` into wire bytes.

`TextProtocol` is the easy one:

- `consume` waits for `\n`;
- `parse` splits the line into parts;
- `VALUE_TAIL_COMMANDS = ["SET"]` preserves spaces in the value tail.

`Resp2Protocol` is the precise one:

- `consume` calls `scan_value`;
- `scan_value` branches on the RESP prefix;
- `scan_bulk` and `scan_array` are cursor-based scanners over a byte buffer;
- `INCOMPLETE` means "need more bytes", not "error".

`ResponseFormatting` is shared dispatch:

- it decides which response kind becomes simple string, error, integer, bulk, or
  array;
- `nil` is the one explicit sentinel at this boundary and means "null bulk";
- any other non-`Response` object is a bug in the adapter contract and raises
  `TypeError` on purpose;
- a `Response` with an unknown `kind` is also a bug and raises `ArgumentError`;
- each concrete protocol supplies the final wire bytes.

That split is good because:

- response routing is shared behavior;
- line endings and frame encoding are protocol-specific behavior.

## 11. The TCP edge: `TcpServer`

Open `lib/rediscraft/interface/tcp_server.rb` last among the runtime files.

This file is the edge adapter and concurrency model.

Read these methods in order:

1. `#start`
2. `#event_loop`
3. `#handle_readable`
4. `#read_from`
5. `#process_buffer`
6. `#dispatch`
7. `#flush`
8. `#run_cron`
9. `#shutdown_all`

What the reactor is doing:

- `IO.select` waits for readable and writable sockets;
- each connection owns its own read and write buffers;
- parsers are incremental because TCP is a byte stream, not a message queue;
- `run_cron` performs bounded background work between socket events.

Why the self-pipe exists:

- `IO.select` blocks;
- `stop` must wake the event loop from another thread or signal handler;
- writing one byte into the pipe makes the loop wake up and exit cleanly.

Why `handle_readable` rescues `StandardError`:

- in a reactor, one unexpected exception would otherwise kill the whole server;
- the boundary is now per connection: log, drop that client, keep serving.

One intentional limitation:

- write buffer has a cap;
- read buffer has a cap too, so an endless partial frame is dropped instead of
  growing memory forever;
- one hot client can still monopolize the loop by draining a very large pipeline
  before the server yields back to `IO.select`.

That is now the better future exercise because it is a real fairness problem, not
a memory-leak cleanup.

## 12. The tests: how to read them

Read tests as the external contract.

Suggested order:

1. `test/unit/command_executor_test.rb`
2. `test/unit/aof_command_executor_test.rb`
3. `test/unit/resp2_protocol_test.rb`
4. `test/integration/tcp_server_test.rb`
5. `test/integration/crash_recovery_test.rb`

What each level teaches:

- unit command tests teach semantics;
- AOF tests teach replay and write ordering;
- protocol tests teach parser boundaries;
- TCP integration tests teach the real socket behavior;
- crash recovery test teaches what "durable enough for process death" really means.

## 13. Ruby syntax cheat sheet for this repo

These are the constructs most likely to slow down a reader who is new to Ruby.

- `foo: bar`
  Symbol-key Hash entry or keyword argument.
- `def initialize(store:)`
  Required keyword argument.
- `entry&.value`
  Safe navigation. Return `nil` if `entry` is `nil`.
- `value.nil? ? x : y`
  Ternary operator.
- `array[2..]`
  Slice from index `2` to the end.
- `(3..)`
  Endless range.
- `arity === parts.length`
  Case-equality. Integer means equality; Range means membership.
- `then { |number| ... }`
  Transform the previous expression inline.
- `rescue ArgumentError`
  Catch parsing failure from `Integer(...)` or `Float(...)`.
- `+""
  Create a mutable String literal.
- `Struct.new(... ) do ... end`
  Small anonymous data holder with methods.

## 14. Three good exercises after reading

1. Add a fairness budget in `process_buffer` so one heavily pipelined connection
   cannot monopolize the loop for too long.
2. Add a third value type and watch where the current `Array` checks stop scaling.
3. Add an `INFO` request counter without letting the application layer learn about
   sockets.
