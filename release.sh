#!/usr/bin/env bash
#
# Test, build, tag, and publish a GitHub release, then update Homebrew.
# The build number increments automatically from .build-number.
#
#   ./release.sh <version>          e.g. ./release.sh 2.11
#
# ponytail: not resumable — if a step fails after tagging, finish by hand
# (`gh release create/upload`). Re-add idempotent resume only if partial
# failures actually become a recurring chore.
set -euo pipefail

usage() { echo "usage: ./release.sh VERSION (for example: ./release.sh 2.11)" >&2; exit 2; }
[ "$#" -eq 1 ] || usage
version="$1"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || usage
name="pasteboard"
tag="v$version"
dmg="dist/PasteBoard.dmg"
tap="../homebrew-tap"

cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

command -v gh >/dev/null || { echo "✗ gh not found" >&2; exit 1; }
gh auth status >/dev/null

[ "$(git symbolic-ref --quiet --short HEAD)" = main ] || { echo "current branch must be main" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=all)" ] || { echo "working tree must be clean (including untracked files)" >&2; exit 1; }

git fetch origin main --tags
git push origin main

build="$(($(cat .build-number) + 1))"
echo "$build" > .build-number
git add .build-number
git commit -q -m "PasteBoard build $build"
git push origin main

swift test
./build-release.sh "$version" "$build"

git rev-parse -q --verify "refs/tags/$tag" >/dev/null || git tag -a "$tag" -m "PasteBoard $tag"
git ls-remote --exit-code --tags origin "$tag" >/dev/null 2>&1 || git push origin "$tag"
gh release view "$tag" >/dev/null 2>&1 || gh release create "$tag" "$dmg" --title "PasteBoard $tag" --generate-notes --verify-tag

if [ -f "$tap/Formula/$name.rb" ] || [ -f "$tap/Casks/$name.rb" ]; then
  "$tap/bump.sh" "$name" "$version"
else
  echo "△ no Homebrew entry for $name — skipping tap bump"
fi
echo "✓ released PasteBoard $tag (build $build)"
