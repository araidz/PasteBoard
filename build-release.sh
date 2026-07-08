#!/usr/bin/env bash
#
# Build a distributable PasteBoard.app + PasteBoard.dmg in one shot.
#
#   ./build-release.sh [version] [build]
#
# Defaults to 1.1 (build 2). The result is a release build, stripped of debug
# symbols, ad-hoc signed (this is a free app with no paid Apple cert), and packaged
# into a compressed read-only DMG named after the app. Output lands in dist/, which
# is gitignored — the .app and .dmg are distributed via GitHub Releases, not committed.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PasteBoard"
BUNDLE_ID="com.local.pasteboard"
VERSION="${1:-2.0}"
BUILD="${2:-6}"

DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

# SwiftPM needs a full Xcode toolchain; the bare Command Line Tools can't build this.
# Honor an explicit DEVELOPER_DIR, otherwise fall back to an installed Xcode when the
# active developer dir is only the Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" ]] && xcode-select -p 2>/dev/null | grep -q "CommandLineTools"; then
  XCODE_APP="$(ls -d /Applications/Xcode*.app 2>/dev/null | head -1 || true)"
  [[ -n "$XCODE_APP" ]] && export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
fi

echo "▸ Building release binary…"
xcrun swift build -c release
BIN="$(xcrun swift build -c release --show-bin-path)/$APP_NAME"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundleExecutable</key>
	<string>$APP_NAME</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$BUILD</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "▸ Stripping debug symbols…"
strip -rSTx "$APP/Contents/MacOS/$APP_NAME"

# Prefer a stable self-signed identity (see make-signing-cert.sh) so the
# Accessibility permission survives rebuilds; fall back to ad-hoc otherwise.
SIGN_IDENTITY="${SIGN_IDENTITY:-PasteBoard Self-Signed}"
xattr -cr "$APP"
if security find-identity -p codesigning | grep -qF "$SIGN_IDENTITY"; then
  echo "▸ Signing with \"$SIGN_IDENTITY\"…"
  codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
else
  echo "▸ Signing (ad-hoc — run ./make-signing-cert.sh once so Accessibility persists)…"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "▸ Building ${DMG}…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/$APP_NAME.app"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "✓ Done — v$VERSION (build $BUILD)"
echo "  app: $APP  ($(du -h "$APP/Contents/MacOS/$APP_NAME" | cut -f1) binary)"
echo "  dmg: $DMG  ($(du -h "$DMG" | cut -f1))"
