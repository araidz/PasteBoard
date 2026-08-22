#!/usr/bin/env bash
#
# Test, build, tag, and publish a GitHub release.
#
#   ./release.sh 2.7 13
#
# ponytail: not resumable — if a step fails after tagging, finish by hand
# (`gh release create/upload`). Re-add idempotent resume only if partial
# failures actually become a recurring chore.
set -euo pipefail

usage() { echo "usage: ./release.sh VERSION BUILD (for example: ./release.sh 2.7 13)" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
version="$1"
build="$2"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || usage
[[ "$build" =~ ^[1-9][0-9]*$ ]] || usage
tag="v$version"
dmg="dist/PasteBoard.dmg"

cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[ "$(git symbolic-ref --quiet --short HEAD)" = main ] || { echo "current branch must be main" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree must be clean (including untracked files)" >&2; exit 1; }
gh auth status
git fetch origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  || { echo "HEAD must exactly match origin/main" >&2; exit 1; }

swift test
./build-release.sh "$version" "$build"

git tag -a "$tag" -m "PasteBoard $tag"
git push origin "$tag"
gh release create "$tag" "$dmg" --title "PasteBoard $tag" --generate-notes --verify-tag
echo "✓ released PasteBoard v$version"
