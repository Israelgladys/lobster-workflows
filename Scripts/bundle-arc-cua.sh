#!/bin/bash
# Builds the arc-cua runtime Third Hand ships: a relocatable CPython with arc-cua installed at the pinned
# version, trimmed, precompiled and signed. Prints the directory to copy into Contents/Resources/arc-cua.
# Usage: bash Scripts/bundle-arc-cua.sh <signing identity>
set -euo pipefail
cd "$(dirname "$0")/.."
IDENTITY="${1:?Usage: $0 <signing identity>}"
PYTHON_VERSION="3.13"
# One source of truth for the pinned version: ArcDriver.defaultPackage.
PACKAGE="$(sed -n 's/.*static let defaultPackage = "\(.*\)".*/\1/p' Sources/ThirdHand/ArcDriver.swift)"
[[ -n "$PACKAGE" ]] || { echo "Couldn't read ArcDriver.defaultPackage." >&2; exit 1; }
command -v uv >/dev/null || { echo "uv is needed to build the arc-cua runtime: https://docs.astral.sh/uv/" >&2; exit 1; }

KEY="$(printf '%s\n%s\n%s\n' "$PACKAGE" "$PYTHON_VERSION" "$IDENTITY" | shasum -a 256 | cut -c1-16)"
CACHE="$PWD/.build/arc-cua/$KEY"
if [[ -f "$CACHE/.complete" ]]; then echo "$CACHE"; exit 0; fi

echo "Building the arc-cua runtime ($PACKAGE, Python $PYTHON_VERSION)…" >&2
STAGE="$CACHE.partial"
rm -rf "$STAGE"
mkdir -p "$STAGE"
uv python install "$PYTHON_VERSION" >&2
SOURCE_PYTHON="$(uv python find --managed-python "$PYTHON_VERSION")"
ditto "$(dirname "$(dirname "$SOURCE_PYTHON")")" "$STAGE/python"
PYTHON="$STAGE/python/bin/python3"
# This copy is Third Hand's own; the marker only guards the shared uv install.
find "$STAGE/python/lib" -maxdepth 2 -name EXTERNALLY-MANAGED -delete
uv pip install --python "$PYTHON" --no-cache "$PACKAGE" >&2

# What arc-cua doesn't use: tests, Tk, IDLE, headers, docs.
LIB="$STAGE/python/lib/python$PYTHON_VERSION"
rm -rf "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/ensurepip" "$LIB/lib-dynload/_tkinter"*.so \
       "$STAGE/python/lib/"tcl* "$STAGE/python/lib/"tk* "$STAGE/python/lib/itcl"* "$STAGE/python/lib/thread"* \
       "$STAGE/python/include" "$STAGE/python/share"
# The app is signed and read-only: compile everything now, and run with -B so nothing is written later.
"$PYTHON" -B -m compileall -q -j 0 "$STAGE/python/lib" >/dev/null || true

echo "Signing the arc-cua runtime…" >&2
while IFS= read -r -d '' file; do
    if file -b "$file" | grep -q 'Mach-O'; then
        output="$(codesign --force --options runtime --timestamp --sign "$IDENTITY" "$file" 2>&1)" \
            || { echo "$output" >&2; exit 1; }
    fi
done < <(find "$STAGE/python" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0)

# A smoke test of the signed runtime: arc-cua imports and answers an MCP initialize.
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}' \
    | "$PYTHON" -I -B -m arc_cua mcp | grep -q '"serverInfo"' \
    || { echo "The bundled arc-cua didn't start." >&2; exit 1; }

touch "$STAGE/.complete"
rm -rf "$CACHE"
mv "$STAGE" "$CACHE"
echo "$CACHE"
