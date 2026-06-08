# Request And Response Examples

```text
> PING
< +PONG

> SET name Ada
< +OK

> GET name
< $3 Ada

> GET missing
< $-1

> EXPIRE name 10
< :1

> TTL name
< :10
```

RESP2 malformed frame:

```text
> ?\r\n
< -ERR protocol error\r\n
```
