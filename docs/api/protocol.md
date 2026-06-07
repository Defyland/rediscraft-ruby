# Text Protocol

Rediscraft starts with a line-oriented text protocol instead of RESP.

## Request

Each command is one line:

```text
PING
SET name Ada
GET name
DEL name
EXISTS name
EXPIRE name 10
TTL name
PERSIST name
QUIT
```

For `SET`, the third token is treated as the rest of the line, so values may
contain spaces. The protocol is not binary-safe.

## Response

```text
+OK
+PONG
:1
$3 Ada
$-1
-ERR unknown command
```

This format is intentionally Redis-inspired but not RESP-compatible.
