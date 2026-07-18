#!/usr/bin/env bash
#
# make-dev-cert.sh — create a STABLE self-signed code-signing identity
# ("TypoFree Dev") in the login keychain (DESIGN.md §7). Ad-hoc signing (`-`)
# gives every build a different cdhash, which resets the app's TCC / Accessibility
# grants on every rebuild. Signing each dev build with one stable identity keeps
# those grants across the build→install→test loop. Run this ONCE.
#
# Import strategy: PEM key + cert imported separately. We deliberately do NOT
# go through PKCS12 — Homebrew OpenSSL 3.x exports p12 with AES/PBKDF2-SHA256
# defaults that `security import` cannot verify ("MAC verification failed
# during PKCS 12 import. Wrong password?"). PEM avoids the whole class.
# openssl is pinned to the system LibreSSL for the same reason.
#
# Usage:  scripts/make-dev-cert.sh
set -euo pipefail

IDENTITY="TypoFree Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OPENSSL=/usr/bin/openssl

if security find-identity -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
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

echo "==> Generating self-signed code-signing certificate (system LibreSSL)"
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
	-keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cert.conf" >/dev/null 2>&1

echo "==> Importing key + cert into the login keychain (PEM, no PKCS12)"
security import "$TMP/key.pem" -k "$KEYCHAIN" -T /usr/bin/codesign
security import "$TMP/cert.pem" -k "$KEYCHAIN"

echo "==> Trusting the certificate for code signing (may pop a password dialog — allow it)"
if security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" 2>/dev/null; then
	echo "    trusted for codeSign."
else
	cat <<'NOTE'
    Could not set trust automatically. One-time manual step:
    Keychain Access ▸ login ▸ My Certificates ▸ "TypoFree Dev" ▸ Trust ▸
    Code Signing = Always Trust. Then re-run scripts/dev.sh.
NOTE
fi

echo
echo "Imported code-signing identity: \"$IDENTITY\". Re-run scripts/dev.sh to sign with it."
