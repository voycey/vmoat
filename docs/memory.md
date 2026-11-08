# Memory on macOS

A running `vz` VM holds host RAM until it is stopped. Guest RAM is allocated lazily, but the host pays for the most RAM the guest has ever touched, and Linux fills spare RAM with page cache. Apple's `vz` never gives that back. In testing, three running 16-24 GB VMs held 59 of their 64 GB while their guests used 6-14 GB.

So **RAM, not a fixed count, decides how many VMs you can run.** Plan on each costing its `VM_MEMORY`.

## Managing RAM

- **`vmoat ls`** shows each VM and the host RAM it holds now.
- **`vmoat up`** compares the `VM_MEMORY` of everything running against host RAM minus `HOST_RESERVE` and warns if you'd overcommit. It doesn't refuse: macOS compresses and swaps cold pages, so overcommit is slow, not fatal.
- **`vmoat down`** suspends a VM. It frees all the VM's host RAM and keeps disk, images and volumes. `vmoat up` reboots it in under a minute and re-runs `CMD_UP`. Containers restart, not resume. `vmoat down <vm>` works from any directory.
- **`vmoat reap`** stops VMs nobody is using. A VM is stopped only if all four hold:
  - no vmoat command has touched it for `REAP_IDLE_MIN` minutes
  - no `ssh`/`test`/`up` is attached
  - no tunnel has an open connection
  - its guest 5-min load is under `REAP_LOAD`

  `--dry-run` shows each verdict. To run it every 10 minutes:

  ```sh
  vmoat reap --install-agent
  launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.vmoat.reap.plist
  ```

  Idleness is measured from the last vmoat command, so enable the agent only once every vmoat copy in use (the plugin included) is 0.2.0 or newer.

## Sizing

On a 128 GB Mac with the default 16 GB reserve, expect about 4 VMs at 24 GB, 7 at 16 GB, or 9 at 12 GB. Keep a lean default in `vmoat.conf` and raise it for the heavy worktree in `vmoat.local.conf`.

The Claude Code skill runs `vmoat down` when verification finishes. vmoat never enables nested virtualization.

## Experimental: memory reclaim (krunkit)

With reclaim, freed memory goes back to macOS within about 30 seconds while the VM keeps running.

Turn it on with `vmoat up --reclaim`, or set `MEMORY_RECLAIM=1` in `vmoat.conf` / `vmoat.local.conf`. It applies when a VM is created. To convert one, run `vmoat destroy && vmoat up --reclaim`. The default stays standard Colima on `vz` + `virtiofs`. Reclaim VMs use Colima's `krunkit` backend with `virtiofs`.

A guest timer also drops Linux page cache every `RECLAIM_INTERVAL` minutes (default 5), so cached memory is freed and returned too. `vmoat ls` reports a reclaim VM's actual host RAM.

Measured through vmoat on an M5 Max (128 GB):

- A guest wrote 5 GB then deleted it. Host memory went from 6.3 GB to 1.3 GB within 30 s. The standard backend stays at 6.3 GB until the VM stops.
- After a 7.6 GB page-cache fill, the timer brought it back to 1.4 GB within 90 s.
- A reclaim VM is created or restarted in about 14 s. virtiofs mounts and Docker work.

### One-time setup

`scripts/build-krunkit.sh` compiles the reclaiming VM runtime (a patched libkrun + krunkit) from source. It needs `cargo` and takes about 25 s once Rust is installed. It installs to `~/.local/share/vmoat/krunkit` (override with `KRUNKIT_HOME`).

### Caveats

- Apple Silicon and macOS 14+ only. Elsewhere `MEMORY_RECLAIM=1` is ignored with a warning.
- Experimental.
- No Rosetta: amd64 images run under QEMU emulation.
- Dropping page cache means files get re-read. Raise `RECLAIM_INTERVAL` (15-30) for database-heavy stacks.
