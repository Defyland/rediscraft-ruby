# Error Format

Text protocol errors are returned as one line with a leading `-`.

```text
-ERR unknown command
-ERR wrong number of arguments for SET
```

RESP2 errors use RESP error frames:

```text
-ERR unknown command\r\n
-ERR protocol error\r\n
```

Malformed RESP2 frames receive `-ERR protocol error\r\n` before the server closes
that client connection.
