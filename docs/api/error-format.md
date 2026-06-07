# Error Format

Errors are returned as one line with a leading `-`.

```text
-ERR unknown command
-ERR wrong number of arguments for SET
```

The format is intentionally Redis-inspired but not RESP-compatible.
