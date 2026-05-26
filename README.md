# zig raft

Hopefully, one day a full [raft] implementation in [zig].

Why? Because.

> [!NOTE]
> This is just a research project for me to learn [zig] and have fun implementing [raft]

[zig]: https://ziglang.org/
[raft]: https://raft.github.io/

## Design

```mermaid
flowchart TD
    client[Client]
    server[Server]
    log[Log]
    sm[StateMachine]

    client --> server
    server -->|apppend| log
    log -->|apply| sm
    sm -->|result via future| server
```

### Log Structure

See [wal-format](./docs/wal-format.md)

### State Machine

```mermaid
flowchart TD
    A[apply_loop ticks] --> B{applied_index < commit_index?}
    B -->|no| A
    B -->|yes| C[cmd = log.get<br/>applied_index + 1]
    C --> D{cmd_tag}
    D -->|Set| E[map.put key, value]
    D -->|Delete| F[map.remove key]
    D -->|Cas| G{map.get key == expected?}
    G -->|yes| H[map.put key, new]
    G -->|no| I[result: CasMismatch]
    E --> J[applied_index += 1]
    F --> J
    H --> J
    I --> J
    J --> K[wake waiter for this index]
    K --> A
```
