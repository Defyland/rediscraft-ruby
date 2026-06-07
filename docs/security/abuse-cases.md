# Abuse Cases

- Client opens many connections and exhausts threads.
- Client sends huge lines and consumes memory.
- Client floods writes and grows the AOF.
- Client stores sensitive values in a plain-text AOF.
