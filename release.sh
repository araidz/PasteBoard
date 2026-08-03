#!/usr/bin/env bash
#
# Test, build, tag, and publish a GitHub release.
#
#   ./release.sh 2.7 13
#
set -euo pipefail

usage() { echo "usage: ./release.sh VERSION BUILD (for example: ./release.sh 2.7 13)" >&2; exit 2; }
[ "$#" -eq 2 ] || usage
version="$1"
build="$2"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || usage
[[ "$build" =~ ^[1-9][0-9]*$ ]] || usage
tag="v$version"
release_title="PasteBoard $tag"
dmg="dist/PasteBoard.dmg"

fail() { echo "$*" >&2; exit 1; }
local_tag_commit() { git rev-parse "$tag^{}"; }
remote_tag_commit() {
  local refs fallback=""
  refs="$(git ls-remote --tags origin "refs/tags/$tag" "refs/tags/$tag^{}")"
  while read -r commit ref; do
    case "$ref" in *'^{}') echo "$commit"; return ;; esac
    fallback="$commit"
  done <<< "$refs"
  [ -z "${fallback:-}" ] || echo "$fallback"
}
release_id() {
  gh api --paginate 'repos/{owner}/{repo}/releases?per_page=100' \
    --jq ".[] | select(.tag_name == \"$tag\") | .id"
}

cd -- "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
branch="$(git symbolic-ref --quiet --short HEAD)" || { echo "not on a branch" >&2; exit 1; }
[ "$branch" = main ] || { echo "current branch must be main (found $branch)" >&2; exit 1; }
[ -z "$(git status --porcelain)" ] || { echo "working tree must be clean (including untracked files)" >&2; exit 1; }
gh auth status
git remote get-url origin >/dev/null
git fetch origin main
[ "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)" ] \
  || { echo "HEAD must exactly match origin/main" >&2; exit 1; }

head_commit="$(git rev-parse HEAD)"
if [ -n "$(git tag --list "$tag")" ]; then
  [ "$(local_tag_commit)" = "$head_commit" ] || fail "local tag $tag does not point to HEAD"
fi
remote_commit="$(remote_tag_commit)"
[ -z "$remote_commit" ] || [ "$remote_commit" = "$head_commit" ] || fail "remote tag $tag does not point to HEAD"
existing_release_id="$(release_id)"
if [ -n "$existing_release_id" ]; then
  [ "$(gh api "repos/{owner}/{repo}/releases/$existing_release_id" --jq .name)" = "$release_title" ] || fail "GitHub release $tag has a mismatched title"
  [ -n "$remote_commit" ] || fail "GitHub release $tag has no matching remote tag"
fi

swift test
git diff --check
./build-release.sh "$version" "$build"

plist="dist/PasteBoard.app/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version" ] \
  || { echo "generated short version does not match $version" >&2; exit 1; }
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$build" ] \
  || { echo "generated build does not match $build" >&2; exit 1; }
codesign --verify --deep --strict dist/PasteBoard.app
hdiutil verify dist/PasteBoard.dmg

if [ -z "$(git tag --list "$tag")" ]; then
  if [ -n "$remote_commit" ]; then
    git fetch origin "refs/tags/$tag:refs/tags/$tag"
  else
    git tag -a "$tag" -m "$release_title" "$head_commit"
  fi
fi
if [ -z "$remote_commit" ]; then
  git push origin "$tag"
fi

existing_release_id="$(release_id)"
if [ -z "$existing_release_id" ]; then
  gh release create "$tag" "$dmg" --title "$release_title" --generate-notes --verify-tag --draft
  existing_release_id="$(release_id)"
  [ -n "$existing_release_id" ] || fail "draft release was not created"
fi

asset_name="$(basename "$dmg")"
release_api="repos/{owner}/{repo}/releases/$existing_release_id"
draft="$(gh api "$release_api" --jq .draft)"
asset_count="$(gh api "$release_api" --jq "[.assets[] | select(.name == \"$asset_name\")] | length")"
[ "$asset_count" -le 1 ] || fail "release has duplicate $(basename "$dmg") assets"
if [ "$asset_count" -eq 0 ]; then
  [ "$draft" = true ] || fail "published release is missing $(basename "$dmg")"
  gh release upload "$tag" "$dmg"
fi

asset_count="$(gh api "$release_api" --jq "[.assets[] | select(.name == \"$asset_name\")] | length")"
[ "$asset_count" -eq 1 ] || fail "release asset $(basename "$dmg") is missing"
remote_size="$(gh api "$release_api" --jq ".assets[] | select(.name == \"$asset_name\") | .size")"
[ "$remote_size" = "$(stat -f %z "$dmg")" ] || fail "release asset size does not match local DMG"
remote_digest="$(gh api "$release_api" --jq ".assets[] | select(.name == \"$asset_name\") | .digest // empty")"
local_digest="sha256:$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)"
if [ -n "$remote_digest" ]; then
  [ "$remote_digest" = "$local_digest" ] || fail "release asset digest does not match local DMG"
else
  temp_dir="$(mktemp -d)"
  trap 'rm -rf "$temp_dir"' EXIT
  gh release download "$tag" --pattern "$asset_name" --dir "$temp_dir"
  downloaded_digest="sha256:$(shasum -a 256 "$temp_dir/$asset_name" | cut -d ' ' -f 1)"
  [ "$downloaded_digest" = "$local_digest" ] || fail "downloaded release asset does not match local DMG"
fi

if [ "$(gh api "$release_api" --jq .draft)" = true ]; then
  gh release edit "$tag" --draft=false
fi
echo "✓ released PasteBoard v$version"
