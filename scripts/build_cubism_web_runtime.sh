#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "usage: $0 /path/to/CubismSdkForWeb" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$(cd "$1" && pwd)"
WEB="$ROOT/web/cubism-runtime"
OUT="$WEB/dist"

CORE=$(find "$SDK" -type f -name 'live2dcubismcore.min.js' -print -quit)
FRAMEWORK_SRC=$(find "$SDK" -type f -path '*/Framework/src/live2dcubismframework.ts' -print -quit)
SHADER=$(find "$SDK" -type f -path '*/Framework/Shaders/WebGL/*' -print -quit)
LICENSE=$(find "$SDK" -type f \( -name 'LICENSE.md' -o -name 'LICENSE.txt' \) -print -quit)
FRAMEWORK_LICENSE=$(find "$SDK" -type f -path '*/Framework/LICENSE.md' -print -quit)

[ -n "$CORE" ] || { echo "Cubism Core was not found" >&2; exit 1; }
[ -n "$FRAMEWORK_SRC" ] || { echo "Cubism Web Framework was not found" >&2; exit 1; }
[ -n "$SHADER" ] || { echo "Cubism WebGL shaders were not found" >&2; exit 1; }
[ -n "$LICENSE" ] || { echo "Cubism SDK license file was not found" >&2; exit 1; }
[ -n "$FRAMEWORK_LICENSE" ] || { echo "Cubism Framework license was not found" >&2; exit 1; }

FRAMEWORK_DIR="$(dirname "$(dirname "$FRAMEWORK_SRC")")"
SHADER_DIR="$(dirname "$SHADER")"

cd "$WEB"
npm install --no-audit --no-fund
npm run typecheck
CUBISM_FRAMEWORK_DIR="$FRAMEWORK_DIR" npm run build

mkdir -p "$OUT/shaders"
cp "$CORE" "$OUT/live2dcubismcore.min.js"
cp -R "$SHADER_DIR/." "$OUT/shaders/"
cp "$LICENSE" "$OUT/CUBISM_SDK_LICENSE.md"
cp "$FRAMEWORK_LICENSE" "$OUT/LIVE2D_OPEN_SOFTWARE_LICENSE.md"

echo "Cubism Web runtime: $OUT"
