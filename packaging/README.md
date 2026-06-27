# Releasing vmoat (Homebrew tap)

vmoat installs with one command via a personal tap:

```sh
brew install voycey/vmoat/vmoat
```

That resolves to the tap repo **`voycey/homebrew-vmoat`** (Homebrew requires a
`homebrew-<tap>` repo name), which holds `Formula/vmoat.rb`. The canonical formula
lives here at [`vmoat.rb`](./vmoat.rb).

## Cutting a release — one command

```sh
scripts/release.sh 0.2.0
```

That bumps the embedded version (`WTVM_VERSION` in `bin/vmoat` + the formula URL),
commits, tags `v0.2.0`, and pushes. The **`release` GitHub Action**
(`.github/workflows/release.yml`) then, on the tag push:

1. computes the release tarball's `sha256`,
2. writes the updated `url` + `sha256` into the formula and syncs it back to `main`,
3. pushes `Formula/vmoat.rb` to the tap repo,
4. creates the GitHub Release.

`brew upgrade vmoat` then picks it up. You can re-run the publish for an existing
tag from the Actions tab (workflow_dispatch → enter the tag).

## One-time CI setup (already done)

Cross-repo push to the tap uses a **scoped deploy key** (least privilege — no broad PAT):

- an `ed25519` **write deploy key** on `voycey/homebrew-vmoat`, and
- its private half stored as the **`TAP_DEPLOY_KEY`** Actions secret on `voycey/vmoat`.

To rotate: `ssh-keygen -t ed25519 -f key -N ""`, then
`gh repo deploy-key add key.pub --repo voycey/homebrew-vmoat --allow-write` and
`gh secret set TAP_DEPLOY_KEY --repo voycey/vmoat < key`.
