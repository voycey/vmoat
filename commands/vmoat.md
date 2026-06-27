---
description: Build/test the current git worktree in its own isolated Colima VM (up, test, tunnel, status, down, destroy).
argument-hint: "[up|test [args]|tunnel [ui|api]|status|down|destroy]"
---

Drive `vmoat` for the **current git worktree** following the `vmoat`
skill. The requested action is: `$ARGUMENTS` (default to `up` if empty).

Rules:
- Resolve the CLI as `vmoat` on PATH, else this plugin's `bin/vmoat`.
- For `up` (or empty): follow the skill's LONG-RUNNING procedure — run it in the
  background and emit a ~60s heartbeat with `vmoat status` until the health
  gate passes or it fails. Never a silent foreground wait. Confirm with the user
  before a first-time provision if heavy work may be running.
- For `test`: run `vmoat test $ARGUMENTS-after-test` inside the VM and report
  results with real output.
- For `tunnel`: open the tunnel, then drive Chrome DevTools MCP against the printed
  `http://localhost:<port>` URL for any UI checks; `untunnel` when done.
- For `status`/`down`/`destroy`: run the corresponding CLI command and report.
- Default lifecycle is **leave running**; only `down`/`destroy` tear it down.
