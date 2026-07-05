#!/usr/bin/env bash
#
# Create a stable, self-signed code-signing identity for PasteBoard — run once.
#
# Why: macOS keys the Accessibility (TCC) permission to the app's code-signing
# identity. Ad-hoc signing (`codesign -s -`) produces a new identity every build,
# so the Accessibility grant resets on each update. A self-signed certificate is a
# *stable* identity: you grant Accessibility once and keep it across rebuilds.
#
# After running this, build-release.sh picks up the identity automatically. The
# certificate is untrusted by Gatekeeper (this is a free, un-notarized app opened
# via the quarantine bypass anyway) — that does not affect TCC persistence, which
# depends only on the identity being stable.
set -euo pipefail

IDENTITY="${SIGN_IDENTITY:-PasteBoard Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# `-v` filters to trusted identities; we want ALL of them, so omit it.
if security find-identity -p codesigning | grep -qF "$IDENTITY"; then
  echo "✓ Signing identity \"$IDENTITY\" already exists — nothing to do."
  exit 0
fi

echo "▸ Creating self-signed code-signing certificate \"$IDENTITY\"…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# System LibreSSL produces a PKCS#12 the macOS keychain imports cleanly; a
# Homebrew OpenSSL 3 in PATH would need -legacy, so call the system one explicitly.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning"

/usr/bin/openssl pkcs12 -export -out "$TMP/identity.p12" \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:

# Import into the login keychain, granting codesign access to the private key.
security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "" \
  -T /usr/bin/codesign -T /usr/bin/security

# Let codesign use the key without a GUI prompt on every build. Needs the login
# keychain password (usually your macOS login password).
read -r -s -p "login keychain password (to authorize codesign): " KCPW
echo
security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KEYCHAIN" >/dev/null

echo "✓ Created \"$IDENTITY\". Now run ./build-release.sh — it will sign with it."
echo "  (First launch of the new build, re-grant Accessibility once; it sticks after.)"
