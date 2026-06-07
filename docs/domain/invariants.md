# Invariants

- Expired keys are not visible through `GET`, `EXISTS`, or `TTL`.
- `SET` replaces value and clears previous expiration.
- `TTL` returns `-2` for missing keys and `-1` for keys without expiration.
- AOF replay must ignore partial trailing records.
