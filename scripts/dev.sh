#!/usr/bin/env bash
#
# dev.sh — build → ad-hoc/stable codesign → quit old instance → install into the
# per-user Input Methods dir → TIS register + enable → verify registration.
# DESIGN.md §7. Mirrors squirrel's TIS install mechanism (standard TIS* API only,
# no GPL code). It DOES NOT select (activate) the source — you are typing on this
# machine, so hijacking the active input source would be hostile. First install
# still needs a logout/login for imklaunchagent to rescan (recorded below).
#
# Usage:  scripts/dev.sh            # build + install + register + enable + verify
#         TYPOFREE_SIGN_IDENTITY="My Identity" scripts/dev.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT/TypoFree.xcodeproj"
SCHEME="TypoFree"
CONFIG="Debug"
APP_NAME="TypoFree.app"
INSTALL_DIR="$HOME/Library/Input Methods"
SIGN_IDENTITY="${TYPOFREE_SIGN_IDENTITY:-TypoFree Dev}"   # from make-dev-cert.sh; else ad-hoc

echo "==> [1/6] Building $SCHEME ($CONFIG)"
# -skipPackagePluginValidation: mlx-swift ships a build-tool plugin ("CudaBuild")
# that otherwise triggers an interactive trust prompt on a CLI build.
xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
	-destination 'platform=macOS' -skipPackagePluginValidation \
	CODE_SIGNING_ALLOWED=NO build

PRODUCTS_DIR="$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
	-showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR =/{print $2; exit}')"
BUILT_APP="$PRODUCTS_DIR/$APP_NAME"
[ -d "$BUILT_APP" ] || { echo "dev.sh: built app not found at $BUILT_APP" >&2; exit 1; }

echo "==> [2/6] Codesigning"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
	ID="$SIGN_IDENTITY"
	echo "    using stable identity: $ID"
else
	ID="-"
	echo "    stable identity '$SIGN_IDENTITY' not found — using ad-hoc (-)."
	echo "    (run scripts/make-dev-cert.sh once so re-signs don't reset TCC/AX grants.)"
fi
codesign --force --deep --sign "$ID" \
	--entitlements "$ROOT/TypoFree/TypoFree.entitlements" "$BUILT_APP"

echo "==> [3/6] Quitting any running TypoFree instance"
killall TypoFree 2>/dev/null || true

echo "==> [4/6] Installing into $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
rm -rf "$INSTALL_DIR/$APP_NAME"
cp -R "$BUILT_APP" "$INSTALL_DIR/$APP_NAME"
INSTALLED_BIN="$INSTALL_DIR/$APP_NAME/Contents/MacOS/TypoFree"

echo "==> [5/6] Registering + enabling the input source (NOT selecting)"
"$INSTALLED_BIN" --register-input-source || true
"$INSTALLED_BIN" --enable-input-source || true

echo "==> [6/6] Verifying registration"
if "$INSTALLED_BIN" --verify; then
	echo "    OK — registered + enabled."
else
	echo "    Not yet enabled. FIRST INSTALL: log out and back in once so the input"
	echo "    method server rescans ~/Library/Input Methods, then re-run: $INSTALLED_BIN --verify"
fi

cat <<EOF

Done. Manual step to start using it (NOT done automatically — you are typing here):
  System Settings ▸ Keyboard ▸ Input Sources ▸ + ▸ 简体中文 ▸ "TypoFree (小鹤双拼)" ▸ Add
Then pick it from the input menu and type in TextEdit.
EOF
