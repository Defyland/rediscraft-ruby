# Module Boundaries

## Domain

`lib/rediscraft/domain` owns key state and TTL behavior. It does not know that
commands arrive over TCP or that mutations may later be written to AOF.

## Application

`lib/rediscraft/application` maps parsed command parts to store operations. It
validates command arity and simple value conversions such as TTL seconds.

## Infrastructure

`lib/rediscraft/infrastructure` owns external durability mechanisms. In the
first slices this is planned for AOF.

## Interface

`lib/rediscraft/interface` owns TCP sockets and text protocol formatting. It
should not decide key semantics.
