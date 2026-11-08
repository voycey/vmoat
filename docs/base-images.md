# Base images: new VMs in seconds (macOS)

The first `up` in a worktree normally builds every image from scratch, which takes 10-20 minutes for a heavy stack. vmoat does that once per repo. After the first from-scratch `up`, it saves the VM as the repo's base image automatically (about a minute, one VM restart). Set `AUTO_BASE=0` to turn this off. `vmoat base save` refreshes it by hand.

From then on, `vmoat up` in a new worktree clones the base instead of building. The clone takes under a second and the VM is ready in about 15 s, with the toolchain, images and build cache in place. `CMD_UP` then only rebuilds what the branch changed.

Clones are APFS copy-on-write. They share disk blocks with the base until they diverge, so each VM doesn't hold its own 60-120 GB copy of the images.

## Details

- The base keeps images and build cache but drops the source worktree's containers and volumes. Set `BASE_KEEP_VOLUMES=1` to keep, say, a seeded database.
- Re-run `vmoat base save` whenever the images drift. VMs already cloned are unaffected.
- `vmoat up --fresh` skips the base.
- Standard and reclaim VMs keep separate bases (`<repo>` and `<repo>-reclaim`).
- Clones keep the base's disk size and mount. A worktree that needs a different `VM_MOUNT` or a bigger disk should use `--fresh`.

## Commands

```sh
vmoat base save [name]   # snapshot this worktree's VM
vmoat base ls            # list base images
vmoat base rm <name>     # delete one (existing clones are unaffected)
```
