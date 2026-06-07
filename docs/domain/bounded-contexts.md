# Bounded Contexts

Rediscraft has one small bounded context: cache state. TCP protocol and AOF are
adapters around that context, not separate domains.
