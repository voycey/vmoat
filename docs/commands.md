# Commands

Run these from any git worktree.

| Command | Does |
|---|---|
| `init` | Scaffold a `vmoat.conf` |
| `up [--reclaim[=auto]] [--fresh]` | `provision`, then run `CMD_UP` in the VM (and wait for `HEALTH_URL` if set). A new VM clones the base image if one exists. `--fresh` builds from scratch |
| `base save [name]` / `base ls` / `base rm <name>` | Snapshot this worktree's VM as a base image / list / delete them |
| `test [args]` | Run `CMD_TEST [args]` in the VM |
| `tunnel [port...]` | Forward in-VM ports to free host ports (default: `EXPOSE_PORTS`, else auto-discovered) |
| `untunnel` | Close this worktree's tunnels |
| `provision` | Create/start the VM, install the toolchain, seed files |
| `status` | VM status, containers, health, tunnels |
| `ls` | Every vmoat VM on the host, with the RAM each running one holds |
| `reap [--idle MIN] [--dry-run]` | Stop every VM nobody is using. `--install-agent` writes a launchd job (every 10 min) |
| `ssh [cmd]` | Shell into the VM, or run a command in the worktree dir |
| `down [vm]` | Stop the VM (keeps disk, frees RAM). `down <vm>` stops any VM by its `ls` name |
| `destroy [-f]` | Delete the VM and its Docker data disk |
| `name` | Print this worktree's VM name |

See [Configuration](configuration.md) for the settings these commands read.
