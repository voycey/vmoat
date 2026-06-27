# worktree-vm

**One ephemeral [Colima](https://github.com/abiosoft/colima) VM per git worktree.**
Build and test multiple worktrees of the same project *in parallel*, each fully
isolated in its own Linux kernel + Docker daemon — so a `docker system prune`,
an OOM, or a crashed stack in one worktree can never touch another or your host.

Inside each VM you run your project's **stock** commands (e.g. `./deploy.sh local`,
`./deploy.sh test`) with all defaults — no port-juggling, no project renaming, no
test changes. The VM *is* the isolation boundary.

Ships as both a **POSIX-sh CLI** and a **Claude Code plugin** (skill + `/worktree-vm`
command) so an agent can drive it. It is project-agnostic: everything specific to a
repo lives in a small `worktree-vm.conf`.

## Why a VM per worktree (not namespaced stacks on one daemon)

Running N stacks on one Docker daemon with different project names/ports works until
any one worktree runs `docker system prune`, `down --volumes`, or blows up RAM/disk —
then every stack dies. Separate VMs = separate daemons = no shared blast radius. The
bonus: inside each VM the stack owns the default ports, so `localhost:38003` *is* the
stack and every existing test passes unmodified.

## Install

```sh
brew install colima docker          # the only hard dependency
git clone <this-repo> ~/.worktree-vm
ln -s ~/.worktree-vm/bin/worktree-vm /usr/local/bin/worktree-vm
```

As a Claude Code plugin: install this repo as a plugin; its skill + `/worktree-vm`
command then drive the same CLI.

## Use

From any worktree of a configured project:

```sh
worktree-vm up              # create VM, install toolchain, ./deploy.sh local, wait healthy
worktree-vm test --quick    # run ./deploy.sh test --quick INSIDE the VM
worktree-vm tunnel ui       # surface the in-VM UI to a free host port (prints the URL)
worktree-vm status          # VM status, containers, health, tunnels
worktree-vm down            # stop the VM (keeps disk)
worktree-vm destroy         # delete the VM
```

The VM/profile name is derived from the worktree directory (`worktree-vm name`).
Each worktree gets its own VM automatically.

## Configure

Copy [`worktree-vm.example.conf`](./worktree-vm.example.conf) to your repo root as
`worktree-vm.conf`. It is shell-sourced (`KEY="value"`). Key fields:

| Key | Meaning |
|---|---|
| `VM_CPU` / `VM_MEMORY` / `VM_DISK` | VM sizing (RAM is the real ceiling on parallelism) |
| `VM_MOUNT` | host path mounted **writable** into the VM (must contain the worktree); default `$HOME` |
| `PROVISION_APT` | apt packages the VM lacks |
| `PROVISION_SCRIPT` | shell to install anything apt can't (e.g. dotenvx) |
| `PROVISION_SEED` | gitignored files copied from the main checkout into a fresh worktree |
| `CMD_UP` / `CMD_TEST` | commands run **inside** the VM, cd'd to the worktree |
| `HEALTH_URL` | polled inside the VM after `up` (gate for "ready") |
| `EXPOSE_UI` / `EXPOSE_API` | guest ports `tunnel` can surface to the host |

## How it works

- **Worktree → VM:** name derived from the worktree dir; `colima -p <name>`.
- **Code into the VM:** Colima mounts `VM_MOUNT` writable at the same path, so the
  worktree is visible inside the VM unchanged — no copy/sync.
- **Deploy + test:** run inside the VM via `colima ssh`; `localhost` ports resolve
  to the stack, so stock commands and tests Just Work.
- **Browser on the host:** `tunnel` opens an SSH port-forward (`colima ssh-config`)
  from a free host port to the in-VM UI; point your browser / Chrome DevTools there.

## Caveats

- **First `up` per VM is slow** (10–20 min) — it builds the project's images with no
  cache shared between VMs. Subsequent runs reuse them.
- **Disk:** images are duplicated per VM. Budget `VM_DISK` accordingly.
- **RAM is the ceiling** on how many run at once (~2–3 heavy stacks on 64 GB).
- macOS / Apple Silicon focused (`vz` + `virtiofs`). Use `VM_TYPE=qemu` /
  `MOUNT_TYPE=sshfs` as a fallback.
