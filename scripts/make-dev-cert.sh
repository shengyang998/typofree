#!/usr/bin/env bash
#
# make-dev-cert.sh — create a STABLE self-signed code-signing identity
# ("TypoFree Dev") in the login keychain (DESIGN.md §7). Ad-hoc signing (`-`)
# gives every build a different cdhash, which resets the app's TCC / Accessibility
# grants on every rebuild. Signing each dev build with one stable identity keeps
# those grants across the build→install→test loop. Run this ONCE.
#
# Usage:  scripts/make-dev-cert.sh
set -euo pipefail

IDENTITY="TypoFree Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
	echo "make-dev-cert.sh: code-signing identity '$IDENTITY' already exists — nothing to do."
	exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<'EOF'
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = TypoFree Dev
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
	-out "$TMP/id.p12" -passout pass:typofree -name "$IDENTITY" >/dev/null 2>&1

echo "==> Importing into the login keychain (allow codesign to use it)"
security import "$TMP/id.p12" -k "$KEYCHAIN" -P typofree -T /usr/bin/codesign

cat <<EOF

Imported code-signing identity: "$IDENTITY".
If codesign later reports it can't use the key, open Keychain Access, find
"$IDENTITY" under login ▸ My Certificates, and set its trust to
"Always Trust" for Code Signing. Then re-run scripts/dev.sh.
EOF
