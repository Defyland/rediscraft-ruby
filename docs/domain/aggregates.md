# Aggregates

The aggregate is the store. It owns entries and protects mutations with a mutex.
Individual entries are values, not independent aggregates.
