# Runbook - AOF Replay Failure

1. Stop the server.
2. Inspect the last lines of the AOF.
3. Remove only a clearly partial trailing line.
4. Restart with the same AOF path.
5. Run command checks manually with `nc`.
