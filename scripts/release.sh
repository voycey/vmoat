#!/usr/bin/env bash
# Cut a vmoat release: bump the embedded version, then tag + push.
# CI (.github/workflows/release.yml) does the rest on the tag push — computes the
# tarball sha256, updates the Homebrew tap (voycey/homebrew-vmoat), and cuts a
# GitHub Release.
#
#   usage: scripts/release.sh X.Y.Z
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

v="${1:?usage: scripts/release.sh X.Y.Z}"; v="${v#v}"
case "$v" in ''|*[!0-9.]*) echo "bad version: '$v' (expected X.Y.Z)" >&2; exit 1 ;; esac
[ -z "$(git status --porcelain)" ] || { echo "working tree is dirty — commit or stash first" >&2; exit 1; }

# Bump the embedded version + the formula's tarball URL (the sha256 is filled in
# by CI once the tag's tarball exists).
sed -i.bak -E "s/^WTVM_VERSION=\".*\"/WTVM_VERSION=\"$v\"/" bin/vmoat && rm -f bin/vmoat.bak
sed -i.bak -E "s#archive/refs/tags/v[0-9][0-9.]*\.tar\.gz#archive/refs/tags/v$v.tar.gz#" packaging/vmoat.rb && rm -f packaging/vmoat.rb.bak

git add bin/vmoat packaging/vmoat.rb
git commit -m "release: v$v"
git tag -a "v$v" -m "vmoat v$v"
git push origin HEAD "v$v"
echo "Pushed v$v — follow the release with:  gh run watch"
