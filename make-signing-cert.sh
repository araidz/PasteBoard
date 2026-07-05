#!/usr/bin/env bash
#
# Create a stable, self-signed code-signing identity for PasteBoard — run once.
#
# Why: macOS keys the Accessibility (TCC) permission to the app's code-signing
# identity. Ad-hoc signing (`codesign -s -`) produces a new identity every build,
# so the Accessibility grant resets on each update. A self-signed certificate is a
# *stable* identity: grant Accessibility once and it sticks across rebuilds.
#
# Run WITHOUT sudo — it targets YOUR login keychain. After it finishes,
# build-release.sh signs with the identity automatically. The certificate is
# untrusted by Gatekeeper (this is a free, un-notarized app opened via the
# quarantine bypass anyway); that does not affect TCC persistence.
set -euo pipefail

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  echo "✗ Don't run this with sudo — it must target your login keychain, not root's." >&2
  exit 1
fi

IDENTITY="${SIGN_IDENTITY:-PasteBoard Self-Signed}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# `-v` lists trusted identities only; a self-signed cert is untrusted, so omit it.
if security find-identity -p codesigning | grep -qF "$IDENTITY"; then
  echo "✓ Signing identity \"$IDENTITY\" already exists — nothing to do."
  exit 0
fi

echo "▸ Creating self-signed code-signing certificate \"$IDENTITY\"…"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
P12PW="pasteboard-transit"   # transient PKCS#12 passphrase, never stored

# System LibreSSL. A NON-EMPTY passphrase and an explicit SHA1 MAC are both
# required, or `security import` fails with "MAC verification failed".
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "basicConstraints=critical,CA:false" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

/usr/bin/openssl pkcs12 -export -macalg sha1 \
  -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass:"$P12PW"

security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$P12PW" -T /usr/bin/codesign

# Let codesign use the key without a GUI prompt on every build. Needs the login
# keychain password (your macOS login password). Non-fatal: if skipped, codesign
# just asks once at build time — click "Always Allow".
KCPW="${KEYCHAIN_PWD:-}"
if [[ -z "$KCPW" ]]; then
  read -r -s -p "login keychain password (to pre-authorize codesign, blank to skip): " KCPW
  echo
fi
if [[ -n "$KCPW" ]]; then
  if security set-key-partition-list -S apple-tool:,apple: -s -k "$KCPW" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "✓ codesign pre-authorized — no prompt at build time."
  else
    echo "! Could not pre-authorize (wrong password?). codesign will ask once at build time — click \"Always Allow\"."
  fi
else
  echo "! Skipped pre-authorization. codesign will ask once at build time — click \"Always Allow\"."
fi

echo "✓ Created \"$IDENTITY\". Now run ./build-release.sh — it signs with it."
echo "  On the new build, re-grant Accessibility once; it sticks after that."
