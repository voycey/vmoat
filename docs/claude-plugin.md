# Claude Code plugin

vmoat ships as a Claude Code plugin: a skill plus a `/vmoat` command. An agent can bring up, test and inspect a worktree on its own.

## Install

```text
/plugin marketplace add voycey/vmoat
/plugin install vmoat@vmoat
```

To try it without installing: `claude --plugin-dir ~/.vmoat`.

Once enabled, `bin/` is on `$PATH`, the skill triggers when you ask Claude to build or test a worktree in isolation, and `/vmoat <cmd>` works.

## Usage

Ask Claude to verify a branch, for example "verify this worktree end-to-end" or "check the UI in the browser". The skill:

1. brings the worktree up in its own VM,
2. runs the tests there,
3. tunnels the app to your host,
4. drives Chrome DevTools (MCP) against it,
5. runs `vmoat down` when done, unless you asked to keep the VM up.

It writes a `vmoat.conf` if one is needed.

## Distributing your own plugin

This repo is also a Claude Code marketplace (`.claude-plugin/marketplace.json`). To publish a plugin, validate with `claude plugin validate .`, push to GitHub, and have users run `/plugin marketplace add <owner>/<repo>`.

For how vmoat itself is released, see [`packaging/README.md`](../packaging/README.md).
