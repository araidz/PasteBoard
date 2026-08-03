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
  gh api --paginate "repos/{owner}/{repo}/releases?per_page=100&cache_bust=$(uuidgen)" \
    --jq ".[] | select(.tag_name == \"$tag\") | .id"
}
cleanup() {
  if [ "${mounted:-false}" = true ]; then
    hdiutil detach "$mount_point" >/dev/null 2>&1 \
      || hdiutil detach -force "$mount_point" >/dev/null 2>&1 \
      || true
  fi
  [ -z "${temp_dir:-}" ] || rm -rf "$temp_dir"
}
validate_dmg() {
  local image="$1" app plist
  hdiutil verify "$image"
  [ -n "${temp_dir:-}" ] || temp_dir="$(mktemp -d)"
  mount_point="$temp_dir/mount"
  mkdir "$mount_point"
  mounted=true
  hdiutil attach -readonly -nobrowse -mountpoint "$mount_point" "$image" >/dev/null
  app="$mount_point/PasteBoard.app"
  plist="$app/Contents/Info.plist"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist")" = "$version" ] \
    || fail "packaged short version does not match $version"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$plist")" = "$build" ] \
    || fail "packaged build does not match $build"
  codesign --verify --deep --strict "$app"
  hdiutil detach "$mount_point" >/dev/null
  mounted=false
  rmdir "$mount_point"
}
verify_remote_asset() {
  local expected="${1:-}" asset_id remote_size remote_digest downloaded_digest remote_dmg
  asset_id="$(gh api "$release_api" --jq ".assets[] | select(.name == \"$asset_name\") | .id")"
  remote_size="$(gh api "$release_api" --jq ".assets[] | select(.name == \"$asset_name\") | .size")"
  remote_digest="$(gh api "$release_api" --jq ".assets[] | select(.name == \"$asset_name\") | .digest // empty")"
  [[ "$remote_digest" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "release asset has no valid SHA-256 digest"
  [ -n "${temp_dir:-}" ] || temp_dir="$(mktemp -d)"
  remote_dmg="$temp_dir/$asset_name"
  gh api -H 'Accept: application/octet-stream' "repos/{owner}/{repo}/releases/assets/$asset_id" > "$remote_dmg"
  [ "$(stat -f %z "$remote_dmg")" = "$remote_size" ] || fail "downloaded release asset size does not match GitHub metadata"
  downloaded_digest="sha256:$(shasum -a 256 "$remote_dmg" | cut -d ' ' -f 1)"
  [ "$downloaded_digest" = "$remote_digest" ] || fail "downloaded release asset digest does not match GitHub metadata"
  [ -z "$expected" ] || [ "$downloaded_digest" = "$expected" ] \
    || fail "downloaded release asset does not match local DMG"
  validate_dmg "$remote_dmg"
}

temp_dir=""
mounted=false
trap cleanup EXIT

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

swift test
git diff --check

existing_release_id="$(release_id)"
if [ -n "$existing_release_id" ]; then
  [[ "$existing_release_id" != *$'\n'* ]] || fail "multiple GitHub releases exist for $tag"
  [ "$(gh api "repos/{owner}/{repo}/releases/$existing_release_id" --jq .tag_name)" = "$tag" ] || fail "GitHub release has a mismatched tag"
  [ "$(gh api "repos/{owner}/{repo}/releases/$existing_release_id" --jq .name)" = "$release_title" ] || fail "GitHub release $tag has a mismatched title"
  [ -n "$remote_commit" ] || fail "GitHub release $tag has no matching remote tag"
  release_api="repos/{owner}/{repo}/releases/$existing_release_id"
  asset_name="$(basename "$dmg")"
  asset_count="$(gh api "$release_api" --jq '.assets | length')"
  [ "$asset_count" -le 1 ] || fail "release has multiple assets"
  if [ "$asset_count" -eq 1 ]; then
    [ "$(gh api "$release_api" --jq '.assets[0].name')" = "$asset_name" ] || fail "release has a mismatched asset"
    verify_remote_asset
    if [ "$(gh api "$release_api" --jq .draft)" = true ]; then
      gh release edit "$tag" --draft=false
    fi
    echo "✓ released PasteBoard v$version"
    exit
  fi
  [ "$(gh api "$release_api" --jq .draft)" = true ] || fail "published release is missing $asset_name"
fi

./build-release.sh "$version" "$build"
validate_dmg "$dmg"

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
  gh release create "$tag" --title "$release_title" --generate-notes --verify-tag --draft
  existing_release_id="$(release_id)"
  [ -n "$existing_release_id" ] || fail "draft release was not created"
fi
[[ "$existing_release_id" != *$'\n'* ]] || fail "multiple GitHub releases exist for $tag"

asset_name="$(basename "$dmg")"
release_api="repos/{owner}/{repo}/releases/$existing_release_id"
[ "$(gh api "$release_api" --jq .tag_name)" = "$tag" ] || fail "GitHub release has a mismatched tag"
[ "$(gh api "$release_api" --jq .name)" = "$release_title" ] || fail "GitHub release $tag has a mismatched title"
draft="$(gh api "$release_api" --jq .draft)"
asset_count="$(gh api "$release_api" --jq '.assets | length')"
[ "$asset_count" -le 1 ] || fail "release has multiple assets"
if [ "$asset_count" -eq 0 ]; then
  [ "$draft" = true ] || fail "published release is missing $asset_name"
  gh release upload "$tag" "$dmg"
fi

local_digest="sha256:$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)"
[ "$(gh api "$release_api" --jq '.assets | length')" -eq 1 ] || fail "release asset $asset_name is missing"
[ "$(gh api "$release_api" --jq '.assets[0].name')" = "$asset_name" ] || fail "release has a mismatched asset"
verify_remote_asset "$local_digest"

if [ "$(gh api "$release_api" --jq .draft)" = true ]; then
  gh release edit "$tag" --draft=false
fi
echo "✓ released PasteBoard v$version"
