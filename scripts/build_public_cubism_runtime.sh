#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/web/cubism-runtime"
TEMP_ROOT=""

if [ "$#" -gt 1 ]; then
    echo "usage: $0 [/path/to/CubismWebFramework]" >&2
    exit 2
fi

if [ "$#" -eq 1 ]; then
    FRAMEWORK="$(cd "$1" && pwd)"
else
    TEMP_ROOT="$(mktemp -d)"
    FRAMEWORK="$TEMP_ROOT/CubismWebFramework"
    git clone --quiet --depth 1 --branch 5-r.5 \
        https://github.com/Live2D/CubismWebFramework.git "$FRAMEWORK"
fi

cleanup() {
    if [ -n "$TEMP_ROOT" ]; then
        rm -rf "$TEMP_ROOT"
    fi
}
trap cleanup EXIT

[ -f "$FRAMEWORK/src/live2dcubismframework.ts" ] \
    || { echo "Cubism Web Framework source was not found" >&2; exit 1; }
[ -f "$FRAMEWORK/LICENSE.md" ] \
    || { echo "Cubism Web Framework license was not found" >&2; exit 1; }

cd "$WEB"
npm ci --no-audit --no-fund
npm run typecheck
CUBISM_FRAMEWORK_DIR="$FRAMEWORK" npm run build
cp "$FRAMEWORK/LICENSE.md" "$WEB/dist/LIVE2D_OPEN_SOFTWARE_LICENSE.md"

echo "Public Cubism Web runtime: $WEB/dist"
