# Configuration

vmoat needs no config for a standard project. It detects the start command and finds ports to tunnel from the running containers:

- a compose file runs `docker compose up -d`
- a Makefile `up:` target runs `make up`
- a `package.json` `dev` script runs `npm run dev`

To customize, add a `vmoat.conf` to the repo (or run `vmoat init`). It is shell-sourced (`KEY="value"`), so treat it as trusted project code. See [`vmoat.example.conf`](../vmoat.example.conf) for a commented template.

## Keys

| Key | Meaning |
|---|---|
| `CMD_UP` | Command that starts the stack inside the VM (auto-detected for standard layouts) |
| `CMD_TEST` | Command for `vmoat test` (extra args are appended) |
| `VM_CPU` / `VM_MEMORY` / `VM_DISK` | VM size (defaults 4 / 8 GiB / 60 GiB). RAM limits how many VMs you can run |
| `VM_MOUNT` | Host path mounted writable into the VM. Must contain the worktree (default `$HOME`) |
| `PROVISION_APT` | Extra apt packages |
| `PROVISION_SCRIPT` | Shell to install anything apt can't |
| `PROVISION_SEED` | Gitignored files copied from the main checkout into a fresh worktree |
| `HEALTH_URL` / `HEALTH_TIMEOUT` | If set, `up` waits until this URL returns 2xx inside the VM |
| `EXPOSE_PORTS` | Guest ports `tunnel` forwards (bash array or space-separated string) |
| `VM_TYPE` / `MOUNT_TYPE` | Force a Colima backend |
| `HOST_RESERVE` | GiB of host RAM kept free of VMs in the `up` budget check (default: 1/8 of host RAM, at least 8) |
| `REAP_IDLE_MIN` / `REAP_LOAD` | `reap` stops a VM idle this many minutes (default 60) with guest 5-min load under this (default 1.0) |
| `MEMORY_RECLAIM` | `1` creates new VMs on the experimental reclaiming backend (same as `up --reclaim`). `auto` does so only where available (same as `up --reclaim=auto`). See [Memory](memory.md#experimental-memory-reclaim-krunkit) |
| `RECLAIM_INTERVAL` | Minutes between guest page-cache drops on reclaim VMs (default 5) |
| `BASE_IMAGE` | Base image new VMs clone from (default: the main checkout's directory name) |
| `AUTO_BASE` | `1` (default) saves a repo's first from-scratch VM as its base image. `0` skips it |
| `BASE_KEEP_VOLUMES` | `1` keeps Docker volumes (e.g. a seeded database) when saving a base image |
| `KRUNKIT_HOME` | Where the reclaiming runtime is installed (default `~/.local/share/vmoat/krunkit`) |

## Per-worktree overrides

`vmoat.conf` is committed and shared. When one worktree needs different settings (an extra debug port, more RAM), put them in a gitignored `vmoat.local.conf` in that worktree. It is sourced after `vmoat.conf`, so it wins. Add it to your `.gitignore`.

```sh
# vmoat.local.conf
EXPOSE_PORTS=(30001 38003 9229)
VM_MEMORY=24
```

## Backends

The backend is auto-detected:

| Host | Backend |
|---|---|
| macOS 13+ | `vz` + `virtiofs` |
| older macOS | `qemu` + `sshfs` |
| Linux / WSL2 | Colima's `qemu` + KVM |

Override with `VM_TYPE` / `MOUNT_TYPE`. A VM keeps the backend it was created with, and vmoat warns if it isn't the preferred one.
