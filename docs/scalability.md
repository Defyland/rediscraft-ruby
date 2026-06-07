# Scalability

The hot path is command execution under a single store mutex. The first expected
bottleneck is write contention. The second is one thread per TCP client.

The next scale investigation should use benchmarks before changing the design.
