#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
NAME="Third Hand"
BUILD="$ROOT/.build/release"
IDENTITY_FILE="$ROOT/.thirdhand-signing-identity"
INSTALL=false
if [[ "${1:-}" == "--install" ]]; then INSTALL=true
elif [[ $# -gt 0 ]]; then echo "Usage: $0 [--install]" >&2; exit 1; fi

# Pin the first certificate locally. Never silently fall back to ad-hoc signing,
# or switch teams/certificate types when the original certificate is unavailable.
if [[ -f "$IDENTITY_FILE" ]]; then
    IDENTITY="$(cat "$IDENTITY_FILE")"
else
    IDENTITIES="$(security find-identity -v -p codesigning)"
    IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk '/"Developer ID Application:/ {print $2; exit}')"
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="$(printf '%s\n' "$IDENTITIES" | awk '/"Apple Development:/ {print $2; exit}')"
    fi
    if [[ -z "$IDENTITY" ]]; then
        echo "No Apple signing identity found. Install a development or Developer ID certificate; ad-hoc builds reset app permissions." >&2
        exit 1
    fi
    printf '%s\n' "$IDENTITY" > "$IDENTITY_FILE"
fi
if ! security find-identity -v -p codesigning | grep -Fq "$IDENTITY"; then
    echo "Pinned signing identity is unavailable. Restore that certificate before updating Third Hand." >&2
    exit 1
fi

echo "Building…"
swift build -c release
APP="$BUILD/$NAME.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/ThirdHand" "$APP/Contents/MacOS/ThirdHand"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# arc-cua drives apps in the background; ship its runtime so users don't need Python or uv.
ARC_RUNTIME="$(bash Scripts/bundle-arc-cua.sh "$IDENTITY")"
rm -rf "$APP/Contents/Resources/arc-cua"
ditto "$ARC_RUNTIME" "$APP/Contents/Resources/arc-cua"
rm -f "$APP/Contents/Resources/arc-cua/.complete"
echo "Signing with the pinned Apple identity…"
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict "$APP"

# Certificate-signed updates must continue to satisfy the installed identity.
INSTALLED="$ROOT/$NAME.app"
if [[ -d "$INSTALLED" ]]; then
    OLD_REQUIREMENT="$(codesign -d -r- "$INSTALLED" 2>&1 | sed -n 's/^designated => //p')"
    if [[ "$OLD_REQUIREMENT" != cdhash* && -n "$OLD_REQUIREMENT" ]]; then
        codesign --verify --strict -R "=$OLD_REQUIREMENT" "$APP"
    fi
fi

if $INSTALL; then
    STAGE="$(mktemp -d "$ROOT/.build/install.XXXXXX")"
    ditto "$APP" "$STAGE/$NAME.app"
    # Finish copying and validation before stopping the running app.
    codesign --verify --strict "$STAGE/$NAME.app"
    pkill -x ThirdHand || true
    for ((attempt=0; attempt<50; attempt++)); do
        if ! pgrep -x ThirdHand >/dev/null; then break; fi
        sleep 0.1
    done
    if pgrep -x ThirdHand >/dev/null; then
        echo "Third Hand did not quit; installation stopped without replacing it." >&2
        exit 1
    fi
    if [[ -d "$INSTALLED" ]]; then mv "$INSTALLED" "$STAGE/Previous Third Hand.app"; fi
    if ! mv "$STAGE/$NAME.app" "$INSTALLED"; then
        if [[ -d "$STAGE/Previous Third Hand.app" ]]; then mv "$STAGE/Previous Third Hand.app" "$INSTALLED"; fi
        exit 1
    fi
    echo "Updated: $INSTALLED"
    echo "Previous copy retained in: $STAGE"
else
    echo "Built: $APP"
    echo "Install updates at the fixed app path with: bash Scripts/build.sh --install"
fi
