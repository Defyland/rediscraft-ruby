# Architecture Overview

Rediscraft is a small layered Ruby process.

```text
TCP socket -> TextProtocol -> CommandExecutor -> Store
                                      |
                                      v
                                   AofLog
```

The application layer is testable without TCP. The domain is testable without
AOF. The interface is tested with real sockets.
