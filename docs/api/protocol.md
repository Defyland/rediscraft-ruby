# Protocols

Rediscraft starts with a line-oriented text protocol and later adds RESP2 as an
alternate protocol adapter. Both protocols call the same application executor.

## Text Request

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

## Text Response

```text
+OK
+PONG
:1
$3 Ada
$-1
-ERR unknown command
```

This format is intentionally Redis-inspired but not RESP-compatible.

## RESP2 Request

RESP2 uses arrays for commands:

```text
*3\r\n$3\r\nSET\r\n$4\r\nname\r\n$3\r\nAda\r\n
*2\r\n$3\r\nGET\r\n$4\r\nname\r\n
```

Supported RESP2 input types:

- simple strings
- errors
- integers
- bulk strings
- arrays

The TCP command path expects an array command for normal Redis-like use.
Null bulk strings inside command arrays are rejected by the adapter because
`nil` is reserved in the application response model to mean missing value.

## RESP2 Response

```text
+OK\r\n
+PONG\r\n
:1\r\n
$3\r\nAda\r\n
$-1\r\n
-ERR unknown command\r\n
```
