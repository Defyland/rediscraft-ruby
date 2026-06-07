# State Machines

```text
missing -> SET -> present
present -> DEL -> missing
present -> EXPIRE -> expiring
expiring -> PERSIST -> present
expiring -> time passes -> missing
```
