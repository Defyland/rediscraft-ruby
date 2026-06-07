# Sequence Diagrams

## SET

```text
client -> TcpServer: SET name Ada
TcpServer -> TextProtocol: parse
TcpServer -> CommandExecutor: execute
CommandExecutor -> Store: set
CommandExecutor -> AofLog: append
TcpServer -> client: +OK
```

## GET

```text
client -> TcpServer: GET name
TcpServer -> CommandExecutor: execute
CommandExecutor -> Store: get
Store -> Store: remove if expired
TcpServer -> client: bulk or null
```
