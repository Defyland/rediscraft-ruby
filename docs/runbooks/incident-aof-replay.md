# Runbook - AOF Replay Failure

1. Stop the server.
2. Inspect the last complete AOF frame header and payload.
3. Remove only a clearly partial trailing frame.
4. Restart with the same AOF path.
5. Run command checks manually with `nc`.
