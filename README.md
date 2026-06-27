# worktree-vm

> **One ephemeral [Colima](https://github.com/abiosoft/colima) VM per git worktree.** Build and test multiple worktrees of the same project **in parallel**, each fully isolated in its own Linux kernel + Docker daemon.

[![Claude Code plugin](https://img.shields.io/badge/Claude_Code-plugin-D97757)](https://code.claude.com/docs/en/plugins)
[![POSIX sh](https://img.shields.io/badge/POSIX-sh-4EAA25?logo=gnubash&logoColor=white)](./bin/worktree-vm)
[![platforms](https://img.shields.io/badge/platforms-macOS%20%7C%20Linux%20%7C%20WSL2-555?logo=linux&logoColor=white)](#requirements)
[![runtime: Colima](https://img.shields.io/badge/runtime-Colima-2496ED?logo=docker&logoColor=white)](https://github.com/abiosoft/colima)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](./LICENSE)
[![version](https://img.shields.io/badge/version-0.1.0-blue)](./.claude-plugin/plugin.json)

A `docker system prune`, an OOM, or a crashed stack in one worktree can **never** touch another worktree or your host. Inside each VM you run your project's **stock** commands (`./deploy.sh local`, `make up`, `docker compose up` …) with all defaults — the VM *is* the isolation boundary, so there's no port-juggling and **every existing test passes unmodified**, because inside the box `localhost` *is* the stack.

```
                    ┌──────────────────────── your Mac (host) ────────────────────────┐
                    │                                                                  │
   git worktree A ──┼──▶  Colima VM  wt-feature-a   ┌─ own kernel + Docker daemon ─┐   │
                    │       └ ./deploy.sh local ──▶ │ postgres · redis · api · ui  │   │
                    │       reachable via  worktree-vm tunnel ui → localhost:9002  │   │
                    │                                └──────────────────────────────┘  │
   git worktree B ──┼──▶  Colima VM  wt-feature-b   ┌─ separate kernel + daemon ───┐   │
                    │       └ ./deploy.sh local ──▶ │  …a full second stack…       │   │
                    │                                └──────────────────────────────┘  │
                    │   `prune`/OOM/crash in A  ✗──/──▶  B   ✗──/──▶  host             │
                    └──────────────────────────────────────────────────────────────────┘
```

Ships as **both a POSIX-sh CLI and a Claude Code plugin** (a skill + a `/worktree-vm` command), so a coding agent can spin up and test a worktree in isolation on its own. It is **project-agnostic**: everything specific to a repo lives in a small `worktree-vm.conf`.

---

## Why not just namespace stacks on one daemon?

Running N stacks on a single Docker daemon with different project names/ports works — until one worktree runs `docker system prune`, `down --volumes`, or blows up RAM/disk, and **every** stack dies. Separate VMs = separate daemons = **no shared blast radius**. The bonus: inside each VM the stack owns the default ports, so `localhost:38003` *is* the stack and tests need zero changes.

## Requirements

- **macOS** (Apple Silicon recommended — fast `vz` + `virtiofs` backend), **Linux**, or **Windows + WSL2** (Colima runs on `qemu` + KVM there).
- [`colima`](https://github.com/abiosoft/colima) and a `docker` CLI.
- Enough RAM for the stacks you run concurrently (a heavy stack ≈ several GB each).

The VM backend is **auto-detected** (macOS → `vz`+`virtiofs`; Linux/WSL2 → Colima's native `qemu`+KVM). Override per project via `VM_TYPE` / `MOUNT_TYPE`.

## Install

### Install Colima (one-time)

- **macOS / Linux:** `brew install colima docker`
- **Windows (WSL2):** install Colima **inside** your WSL2 distro (Homebrew-on-Linux or your distro's package), and enable nested virtualization in `%UserProfile%\.wslconfig`:
  ```ini
  [wsl2]
  nestedVirtualization=true
  ```
  Run `worktree-vm` inside the distro, with your worktrees on the Linux filesystem (`~/...`, **not** `/mnt/c` — far faster).

### As a CLI

```sh
git clone https://github.com/voycey/worktree-vm ~/.worktree-vm
ln -s ~/.worktree-vm/bin/worktree-vm /usr/local/bin/worktree-vm   # or ~/.local/bin
```

### As a Claude Code plugin

```text
/plugin marketplace add voycey/worktree-vm
/plugin install worktree-vm@worktree-vm
```

…or, for a quick test without installing: `claude --plugin-dir ~/.worktree-vm`. Once enabled, the plugin's `bin/` is on `$PATH` automatically, the skill is model-invoked when you ask Claude to build/test a worktree in isolation, and `/worktree-vm <cmd>` is available as a slash command.

## Quickstart

From any worktree of a project that has a `worktree-vm.conf`:

```sh
worktree-vm up            # create VM, install toolchain, run CMD_UP, wait until healthy
worktree-vm tunnel ui     # prints http://localhost:<port> → point your browser there
worktree-vm test --quick  # run CMD_TEST --quick INSIDE the VM (localhost = the stack)
worktree-vm status        # VM status, containers, health, open tunnels
worktree-vm down          # stop the VM (keeps disk)
worktree-vm destroy       # delete the VM entirely
```

Each worktree gets its **own** VM automatically (name derived from the worktree dir — see `worktree-vm name`). Run `up` in two worktrees and you have two fully isolated stacks at once.

## Configure

Copy [`worktree-vm.example.conf`](./worktree-vm.example.conf) to your repo root as `worktree-vm.conf`. It is shell-sourced (`KEY="value"`) and trusted project code.

| Key | Meaning |
|---|---|
| `VM_CPU` / `VM_MEMORY` / `VM_DISK` | VM sizing (RAM is the real ceiling on parallelism) |
| `VM_MOUNT` | host path mounted **writable** into the VM (must contain the worktree); default `$HOME` |
| `PROVISION_APT` | apt packages the VM lacks |
| `PROVISION_SCRIPT` | shell to install anything apt can't (e.g. dotenvx) |
| `PROVISION_SEED` | gitignored files copied from the main checkout into a fresh worktree |
| `CMD_UP` / `CMD_TEST` | commands run **inside** the VM, cd'd to the worktree |
| `HEALTH_URL` | polled inside the VM after `up` (the "ready" gate) |
| `EXPOSE_UI` / `EXPOSE_API` | guest ports `tunnel` can surface to the host |

<details>
<summary>Example: a RAG stack driven by <code>./deploy.sh</code></summary>

```sh
VM_CPU=6; VM_MEMORY=16; VM_DISK=80
VM_MOUNT="$HOME/github"
PROVISION_APT="git jq curl ca-certificates"
PROVISION_SCRIPT='command -v dotenvx >/dev/null 2>&1 || curl -sfS https://dotenvx.sh | sudo sh'
PROVISION_SEED=".env.keys"
CMD_UP="INSTANCE_NAME=local VERSION=local ./deploy.sh local"
CMD_TEST="INSTANCE_NAME=local VERSION=local ./deploy.sh test"
HEALTH_URL="http://127.0.0.1:38003/health"
EXPOSE_UI=30001
EXPOSE_API=38003
```
</details>

## Commands

| Command | Does |
|---|---|
| `provision` | Create/start the worktree's VM, install the toolchain, seed files |
| `up` | `provision` + run `CMD_UP` inside the VM + wait for `HEALTH_URL` |
| `test [args]` | Run `CMD_TEST [args]` inside the VM |
| `tunnel [ui\|api\|<port>]` | SSH-forward an in-VM port to a free host port (prints the URL) |
| `untunnel` | Close all tunnels for this worktree's VM |
| `status` | VM status, containers, health, open tunnels |
| `ssh [cmd]` | Shell into the VM (or run a command in the worktree dir) |
| `down` / `destroy [-f]` | Stop (keep disk) / delete the VM |
| `name` | Print the VM/profile name for this worktree |

## How it works

- **Worktree → VM:** name derived from the worktree dir; one `colima -p <name>` profile each.
- **Code into the VM:** Colima mounts `VM_MOUNT` writable at the same path, so the worktree is visible inside the VM unchanged — no copy/sync.
- **Deploy + test:** run inside the VM via `colima ssh`; `localhost` ports resolve to the stack, so stock commands and tests Just Work.
- **Browser on the host:** `tunnel` opens an SSH port-forward (from `colima ssh-config`) to the in-VM UI; point your browser / Chrome DevTools there.

## Caveats

- **First `up` per VM is slow** (~10–20 min) — it builds the project's images with no cache shared between VMs. Subsequent runs reuse them.
- **Disk:** images are duplicated per VM. Budget `VM_DISK` accordingly.
- **RAM is the ceiling** on how many run at once.
- **Backend differs by platform:** macOS gets `vz`+`virtiofs` (fast); Linux/WSL2 use `qemu`+KVM. On WSL2, nested virtualization must be enabled or `colima start` can't boot the VM.
- Some stacks abort the *very first* `up` on a fresh DB volume (a `depends_on: service_healthy` catching `initdb` mid-restart) — just re-run `up`.

## Publishing your own plugin

This repo is itself a Claude Code marketplace (`.claude-plugin/marketplace.json`). To distribute a plugin like it:

1. Validate: `claude plugin validate .`
2. Push to GitHub. Users add + install with:
   ```text
   /plugin marketplace add <owner>/<repo>
   /plugin install <plugin>@<marketplace-name>
   ```
3. For broad discovery, open a PR to the officially-endorsed community marketplace [`anthropics/claude-plugins-community`](https://github.com/anthropics/claude-plugins-community) (auto-validated); users then `/plugin install <plugin>@claude-community`.

Versioning: bump `version` in `plugin.json` and git-tag releases for pinned updates, or omit `version` to roll updates on every commit (git SHA).

## License

[MIT](./LICENSE) © Dan Voyce
