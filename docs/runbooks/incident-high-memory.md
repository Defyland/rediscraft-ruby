# Runbook - High Memory

1. Check `INFO` for `keys` and `keys_with_expiry`.
2. Identify large values or missing expirations.
3. If expired keys should already be gone, trigger normal traffic or an active
   expire cycle before treating the growth as a leak.
4. Restart only if this is a study run and data loss is acceptable.
5. Plan snapshot/compaction only after measuring growth.
