---
name: worktree-vm
description: Build, deploy, and test a git worktree in its own isolated Colima VM, so multiple worktrees can be worked on in parallel without their Docker stacks colliding. Use when the user wants to run/test/verify a worktree's stack in isolation, deploy a worktree to its own VM, test changes in parallel with other worktrees, or when running the project's stack on the shared host Docker daemon would clobber another worktree. Requires a worktree-vm.conf at the repo root and `colima` installed.
---

# worktree-vm: per-worktree isolated VM build & test

Each git worktree gets its **own Colima VM** (own Linux kernel + own Docker daemon).
Inside it you run the project's **stock** commands (e.g. `./deploy.sh local`,
`./deploy.sh test`) with all defaults — the VM is the isolation boundary, so there is
no port-juggling and every test passes unmodified. A `docker prune`/OOM/crash in one
worktree's VM cannot touch another worktree or the host.

The CLI is `worktree-vm` (on PATH, or `bin/worktree-vm` in this plugin). It always
operates on the **current** git worktree.

## Preconditions (check first)

1. `command -v colima` — if missing, tell the user to install it (macOS/Linux:
   `brew install colima docker`; Windows: inside WSL2 with nested virtualization
   enabled). A one-time setup; do not install it silently — it's a heavy dependency.
2. A `worktree-vm.conf` exists at the repo root (`git rev-parse --show-toplevel`).
   If not, copy `worktree-vm.example.conf` and fill in `CMD_UP`/`CMD_TEST`/`HEALTH_URL`.
3. Resources: the first `up` spins a multi-GB VM and **builds the project's images
   inside it (10–20 min)**. Confirm with the user before provisioning if other heavy
   work (ingest, builds, other VMs) may be running — it competes for RAM/CPU.

## Workflow

### 1. Identify the VM
```
worktree-vm name        # e.g. wt-<worktree-dir>
worktree-vm status      # is it already up?
```

### 2. Bring the stack up (LONG-RUNNING — always pair a heartbeat)
`worktree-vm up` provisions the VM, installs the toolchain, runs `CMD_UP`, and waits
for `HEALTH_URL`. The first run can take 10–20 min. **Never run it as a silent
foreground wait.** Run it in the background and emit a status heartbeat every ~60s
until it goes healthy or fails:

- Start `worktree-vm up` as a background task.
- Alongside it, poll `worktree-vm status` (or the background task's output) on a
  ~60-second cadence and report one progress line each tick (build stage / container
  count / health), breaking when the task exits or `status` shows the health URL OK.

This catches a stuck build or a dead VM instead of leaving the user staring at a
blank wait. Do not declare success until the health gate passes.

### 3. Run tests INSIDE the VM
```
worktree-vm test --quick
worktree-vm test --category <name>
```
Tests run inside the VM where `localhost:<port>` *is* the stack, so **no env
overrides and no test-file changes are needed** — even tests that hardcode localhost
ports pass. Report failures with the real output.

### 4. UI verification with Chrome DevTools MCP (browser stays on the host)
```
worktree-vm tunnel ui     # prints http://localhost:<freePort> on stdout
```
Then drive Chrome DevTools MCP against that URL (navigate, snapshot, click, check the
console/network), exactly as you would for a local stack. When done:
```
worktree-vm untunnel
```
Tunnel other ports if a host-side check needs them: `worktree-vm tunnel api`.

### 5. Leave it running; report
Do **not** tear down by default. Report to the user:
- the tunnel URL(s) and how to reach the stack,
- `worktree-vm test …` to re-run tests,
- `worktree-vm down` (stop, keep disk) / `worktree-vm destroy` (remove) for teardown.

## Isolation guarantee (state it when relevant)
Anything destructive inside one VM — `docker system prune`, `down --volumes`, an OOM
— is contained to that VM. Other worktrees' VMs and the host Docker are untouched.

## Troubleshooting
- `up` times out at health → `worktree-vm ssh -- docker ps` and inspect logs inside
  the VM; the build may still be running or a container may be unhealthy.
- A seed file warning (e.g. `.env.keys`) → the build needs a gitignored file that is
  absent from both the worktree and the main checkout; the user must provide it.
- Tunnel won't open → ensure the VM is running (`worktree-vm status`).
- **First `up` on a fresh VM aborts on a DB `depends_on` (e.g. "postgres is
  unhealthy")** → many DB images run a one-time `initdb` on a fresh volume that
  briefly restarts the server; a `depends_on: service_healthy` gate can catch it
  mid-restart and abort the very first `up`. The volume is now initialized, so just
  **re-run `worktree-vm up`** — it succeeds. (Permanent fix belongs in the project:
  raise the DB healthcheck `start_period`.)
