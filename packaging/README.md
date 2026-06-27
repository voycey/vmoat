# Releasing vmoat (Homebrew tap)

vmoat is distributed via a personal tap, so users install with one command:

```sh
brew install voycey/vmoat/vmoat
```

That resolves to the tap repo **`voycey/homebrew-vmoat`** (a repo named
`homebrew-<tap>` is required by Homebrew), which holds `Formula/vmoat.rb`.
The canonical formula lives here at [`packaging/vmoat.rb`](./vmoat.rb).

## Cut a release

```sh
# 1. tag + push the version
git tag -a v0.1.0 -m "vmoat v0.1.0"
git push origin v0.1.0

# 2. compute the tarball checksum
sha=$(curl -fsSL https://github.com/voycey/vmoat/archive/refs/tags/v0.1.0.tar.gz | shasum -a 256 | awk '{print $1}')
echo "$sha"

# 3. update packaging/vmoat.rb: set `url` to the new tag and `sha256` to $sha,
#    and bump WTVM_VERSION in bin/vmoat to match.

# 4. publish to the tap (first time: create the repo)
gh repo create voycey/homebrew-vmoat --public -d "Homebrew tap for vmoat" || true
tap=$(mktemp -d)
gh repo clone voycey/homebrew-vmoat "$tap"
mkdir -p "$tap/Formula"
cp packaging/vmoat.rb "$tap/Formula/vmoat.rb"
git -C "$tap" add Formula/vmoat.rb
git -C "$tap" commit -m "vmoat v0.1.0"
git -C "$tap" push
```

Then `brew install voycey/vmoat/vmoat` works (or `brew install --HEAD voycey/vmoat/vmoat`
before a tag exists). Future versions: repeat steps 1–4, or wire a GitHub Action
(`dawidd6/action-homebrew-bump-formula`) to auto-bump the tap on each tag.
