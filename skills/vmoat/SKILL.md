---
name: vmoat
description: Build, deploy, and test a git worktree in its own isolated Colima VM, so multiple worktrees can be worked on in parallel without their Docker stacks colliding. Use when the user wants to run/test/verify a worktree's stack in isolation, deploy a worktree to its own VM, test changes in parallel with other worktrees, or when running the project's stack on the shared host Docker daemon would clobber another worktree. Requires a vmoat.conf at the repo root and `colima` installed.
---

# vmoat: per-worktree isolated VM build & test

Each git worktree gets its **own Colima VM** (own Linux kernel + own Docker daemon).
Inside it you run the project's **stock** commands (e.g. `./deploy.sh local`,
`./deploy.sh test`) with all defaults — the VM is the isolation boundary, so there is
no port-juggling and every test passes unmodified. A `docker prune`/OOM/crash in one
worktree's VM cannot touch another worktree or the host.

The CLI is `vmoat` (on PATH, or `bin/vmoat` in this plugin). It always
operates on the **current** git worktree.

## Preconditions (check first)

1. `command -v colima` — if missing, tell the user to install it (macOS/Linux:
   `brew install colima docker`; Windows: inside WSL2 with nested virtualization
   enabled). A one-time setup; do not install it silently — it's a heavy dependency.
2. `vmoat.conf` is **optional** (auto-detected for standard projects). When it's
   missing, **Step 0 below** has you author one from the project — do that before
   `up` unless it's a plain `docker compose` project that needs no provisioning. A
   per-worktree `vmoat.local.conf` (gitignored) overrides any key for one worktree.
3. Resources: the first `up` spins a multi-GB VM and **builds the project's images
   inside it (10–20 min)**. Confirm with the user before provisioning if other heavy
   work (ingest, builds, other VMs) may be running — it competes for RAM/CPU.

## Workflow

### 0. Ensure a good config (author `vmoat.conf` if missing)

If the worktree has **no `vmoat.conf`**, prefer to **author one yourself** rather than
relying on the shell auto-detect — you can read the project and infer a far better
config than the heuristic can. Inspect the repo and determine:

- **`CMD_UP`** — how this project *actually* starts locally. Look at the README /
  CONTRIBUTING, a `deploy.sh` / `run.sh` / `bin/`, `Makefile` targets, `docker-compose*.yml`,
  `package.json` scripts, `Procfile`/`Taskfile`, and especially `.github/workflows/*`
  (the CI "start the app" step). Capture the **exact** command, including required env
  (e.g. `INSTANCE_NAME=local VERSION=local ./deploy.sh local`).
- **`CMD_TEST`** — the project's canonical test entry (the CI test step, `make test`,
  `npm test`, `pytest`, `./deploy.sh test`).
- **Provisioning a fresh worktree** — a fresh `git worktree` lacks gitignored files. If
  the build needs any (secrets/keys like `.env.keys`, a gitignored `config.local.yaml`,
  a decrypt key), add them to **`PROVISION_SEED`** (copied from the main checkout); put
  host-install tooling (e.g. dotenvx) in **`PROVISION_SCRIPT`** and system packages in
  **`PROVISION_APT`**.
- **`HEALTH_URL`** (only if there's a real readiness endpoint) and **`VM_MEMORY`/`VM_CPU`**
  (bump for heavy stacks — DBs, ML, big builds). Leave `EXPOSE_PORTS` unset unless you
  must pin ports — `tunnel` auto-discovers published ports.

Write it to **`vmoat.conf`** at the repo root (shared, committable). For a setting that
should apply to **only this worktree** (e.g. a debug port this branch adds), put it in a
gitignored **`vmoat.local.conf`** instead. **Show the user the config you wrote and let
them confirm/adjust before `up`.** (`vmoat init` scaffolds a minimal template if you'd
rather start from one.) A plain `docker compose` project with no provisioning needs can
skip this and rely on auto-detect.

### 1. Identify the VM
```
vmoat name        # e.g. wt-<worktree-dir>
vmoat status      # is it already up?
```

### 2. Bring the stack up (LONG-RUNNING — always pair a heartbeat)
`vmoat up` provisions the VM, installs the toolchain, runs `CMD_UP`, and waits
for `HEALTH_URL`. The first run can take 10–20 min. **Never run it as a silent
foreground wait.** Run it in the background and emit a status heartbeat every ~60s
until it goes healthy or fails:

- Start `vmoat up` as a background task.
- Alongside it, poll `vmoat status` (or the background task's output) on a
  ~60-second cadence and report one progress line each tick (build stage / container
  count / health), breaking when the task exits or `status` shows the health URL OK.

This catches a stuck build or a dead VM instead of leaving the user staring at a
blank wait. Do not declare success until the health gate passes.

### 3. Run tests INSIDE the VM
```
vmoat test --quick
vmoat test --category <name>
```
Tests run inside the VM where `localhost:<port>` *is* the stack, so **no env
overrides and no test-file changes are needed** — even tests that hardcode localhost
ports pass. Report failures with the real output.

### 4. UI verification with Chrome DevTools MCP (browser stays on the host)
```
vmoat tunnel        # forwards every EXPOSE_PORTS; prints each http://localhost:<port> on stdout
```
Use the URL for the UI port and drive Chrome DevTools MCP against it (navigate, snapshot,
click, check the console/network), exactly as you would for a local stack. When done:
```
vmoat untunnel
```
Tunnel a specific port if needed: `vmoat tunnel <port>` (e.g. an API port for a host-side check).

### 5. Leave it running; report
Do **not** tear down by default. Report to the user:
- the tunnel URL(s) and how to reach the stack,
- `vmoat test …` to re-run tests,
- `vmoat down` (stop, keep disk) / `vmoat destroy` (remove) for teardown.

## Isolation guarantee (state it when relevant)
Anything destructive inside one VM — `docker system prune`, `down --volumes`, an OOM
— is contained to that VM. Other worktrees' VMs and the host Docker are untouched.

## Troubleshooting
- `up` times out at health → `vmoat ssh -- docker ps` and inspect logs inside
  the VM; the build may still be running or a container may be unhealthy.
- A seed file warning (e.g. `.env.keys`) → the build needs a gitignored file that is
  absent from both the worktree and the main checkout; the user must provide it.
- Tunnel won't open → ensure the VM is running (`vmoat status`).
- **First `up` on a fresh VM aborts on a DB `depends_on` (e.g. "postgres is
  unhealthy")** → many DB images run a one-time `initdb` on a fresh volume that
  briefly restarts the server; a `depends_on: service_healthy` gate can catch it
  mid-restart and abort the very first `up`. The volume is now initialized, so just
  **re-run `vmoat up`** — it succeeds. (Permanent fix belongs in the project:
  raise the DB healthcheck `start_period`.)
