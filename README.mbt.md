# tiye/redstart

Lightweight process manager for local development, written in [MoonBit](https://moonbitlang.com).

Redstart manages named processes defined in a `redstart.json5` file, keeps logs in `.redstart-monitor/`, and exposes a simple CLI suitable for both humans and agents.

## Installation

```bash
moon install tiye/redstart --path ./cmd/redstart
```

After installation, `redstart` is available as `~/.moon/bin/redstart`.

## Quick Start

```bash
# Initialize config in your project root
redstart init

# Add process definitions
redstart add server "yarn dev"
redstart add worker "yarn worker" --cwd ./packages/worker
redstart add api "python -m uvicorn main:app" --env "PORT=8000,DEBUG=1"

# Start everything
redstart start

# Watch status
redstart list

# Stream recent logs
redstart logs server
redstart logs server --stderr -n 100

# Stop everything
redstart stop
```

## CLI Reference

| Command                                                 | Description                                               |
| ------------------------------------------------------- | --------------------------------------------------------- |
| `redstart init`                                         | Initialize `redstart.json5` in current directory          |
| `redstart add <alias> <command>`                        | Add a process definition (`--cwd`, `--env KEY=VAL,...`)   |
| `redstart remove <alias\|id>`                           | Remove a stopped process                                  |
| `redstart start [alias\|id]`                            | Start one or all stopped processes                        |
| `redstart stop [alias\|id]`                             | Stop one or all running processes                         |
| `redstart restart <alias\|id>`                          | Restart a process                                         |
| `redstart list [--json]`                                | List all processes and their status                       |
| `redstart status [alias\|id] [--json]`                  | Show status (all or specific)                             |
| `redstart logs <alias\|id> [-n N] [--stdout\|--stderr]` | Show recent log output                                    |
| `redstart inspect <alias\|id>`                          | Dump full process state as JSON                           |
| `redstart wait <alias\|id> [-t seconds]`                | Block until process is running (useful in scripts/agents) |
| `redstart doc [topic]`                                  | Show documentation overview or per-command reference      |

## Config Format

`redstart.json5` uses JSON5 syntax and is human-editable:

```json5
{
  version: "1",
  processes: [
    {
      id: "abc123",
      proc_name: "server",
      command: "yarn dev",
      cwd: "./packages/server",
      env: { PORT: "3000" },
      status: "stopped",
    },
  ],
}
```

## Logs and PIDs

Redstart stores runtime data in `.redstart-monitor/<alias>/`:

- `stdout.log` — captured stdout
- `stderr.log` — captured stderr
- `pid` — PID file while process is alive

Add `.redstart-monitor/` to your `.gitignore`.

## Machine-Readable Output

For use in scripts and AI agents:

```bash
# JSON list of all processes
redstart list --json

# Full state of one process as JSON
redstart inspect server

# Wait up to 60 seconds for a process to start, then proceed
redstart wait server -t 60 && curl http://localhost:3000/health
```

## Library API

The core library is importable as `tiye/redstart`:

```moonbit nocheck
import "tiye/redstart"

let config = @redstart.load_config()!
let entry = @redstart.find_process(config, "server")
```

Key types and functions:

- `ProcessEntry` — process definition with `id`, `proc_name`, `command`, `status`, `pid`, etc.
- `Config` — collection of `ProcessEntry` values
- `load_config() -> Config raise RedstartError`
- `save_config(config) -> Unit raise RedstartError`
- `spawn_process(entry) -> Int raise RedstartError` — returns PID
- `start_with_retry(entry, retries~, delay_ms~) -> Int raise RedstartError`
- `stop_gracefully(pid) -> Unit raise RedstartError`
- `is_process_alive(pid) -> Bool`
- `wait <alias\|id> [-t seconds]` — block until running

## Requirements

- MoonBit `native` target (uses C FFI via `posix_spawn`)
- macOS or Linux

## License

Apache-2.0
