#!/usr/bin/env bash
set -euo pipefail

# --stub-weights: skip the ~1.1 GB weight download and bundle empty
# placeholder weights/{sam2,birefnet-fp16,torch} dirs instead. For CI structural
# verification of the .app bundle only — never ship a stubbed build.
STUB_WEIGHTS=0
REUSE_SWIFT_BUILD=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --stub-weights) STUB_WEIGHTS=1 ;;
        --reuse-swift-build) REUSE_SWIFT_BUILD=1 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_NAME="RealPet"
BUILD_DIR="$SCRIPT_DIR/RealPet/.build/release"
# CI/package verification must never replace a developer's existing release
# bundle. Release builds use dist/ by default; callers can opt into an isolated
# output directory with REALPET_DIST_DIR.
DIST_DIR="${REALPET_DIST_DIR:-$SCRIPT_DIR/dist}"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
SUPABASE_PUBLISHABLE_KEY="${REALPET_SUPABASE_PUBLISHABLE_KEY:-}"

GREEN='\033[0;32m'
NC='\033[0m'

ok() { echo -e "${GREEN}✓${NC} $1"; }

echo "=== Building $APP_NAME.app ==="
echo ""

# 1. Swift release build
echo "--- Building Swift ---"
if [ "$REUSE_SWIFT_BUILD" = "0" ]; then
    cd "$SCRIPT_DIR/RealPet"
    swift build -c release 2>&1 | tail -3
    ok "Swift build complete"
else
    echo "Reusing an existing release binary (requested)"
fi

# 2. Find the binary
BINARY=$(find "$BUILD_DIR" -name "$APP_NAME" -type f -perm +111 | head -1)
if [ -z "$BINARY" ]; then
    # Fallback: look anywhere under .build/release for the executable
    BINARY=$(find "$SCRIPT_DIR/RealPet/.build" -name "$APP_NAME" -type f -perm +111 | head -1)
fi
if [ -z "$BINARY" ]; then
    echo "Error: could not find built binary in $BUILD_DIR"
    exit 1
fi
if [ "$REUSE_SWIFT_BUILD" = "1" ] \
   && [ -n "$(find "$SCRIPT_DIR/RealPet" \
        -path "$SCRIPT_DIR/RealPet/Tests" -prune -o -type f \
        \( -name '*.swift' -o -name 'Package.swift' \) \
        -newer "$BINARY" -print -quit)" ]; then
    echo "Error: Swift sources are newer than the reusable release binary" >&2
    exit 1
fi
ok "Binary: $BINARY"

# 3. Create .app bundle
echo ""
echo "--- Assembling .app bundle ---"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
# Swift release artifacts retain local symbols that are not needed at runtime.
# Strip only local symbols (-x), preserving all executable behavior and unwind
# information while cutting the launcher binary by roughly half.
strip -x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
ok "Stripped local Swift symbols"

# Create Info.plist
cat > "$APP_BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>RealPet</string>
    <key>CFBundleIdentifier</key>
    <string>com.realpet.app</string>
    <key>CFBundleName</key>
    <string>RealPet</string>
    <key>CFBundleDisplayName</key>
    <string>RealPet</string>
    <key>CFBundleVersion</key>
    <string>0.3.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.3.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.entertainment</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.realpet.app.auth</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>realpet-auth</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
if [ -n "$SUPABASE_PUBLISHABLE_KEY" ]; then
    plutil -replace RealPetSupabasePublishableKey -string "$SUPABASE_PUBLISHABLE_KEY" \
        "$APP_BUNDLE/Contents/Info.plist"
else
    echo "Error: REALPET_SUPABASE_PUBLISHABLE_KEY is required to bundle Supabase Storage" >&2
    exit 1
fi
# --- App icon ---
cp "$SCRIPT_DIR/assets/icon/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
ok "Bundled app icon"

# --- Bundle Python pipeline source (required at runtime) ---
# PythonBridge.projectRoot locates the pipeline by finding a `pipeline/`
# directory under Resources; SetupWizard reads `requirements.txt` from the
# bundle. Without these the installed .app cannot run the pipeline and the
# first-launch wizard aborts.
RES_DIR="$APP_BUNDLE/Contents/Resources"
rsync -a --exclude '__pycache__' --exclude '*.pyc' \
    "$SCRIPT_DIR/pipeline/" "$RES_DIR/pipeline/"
rsync -a --exclude '__pycache__' --exclude '*.pyc' \
    "$SCRIPT_DIR/scripts/" "$RES_DIR/scripts/"
cp "$SCRIPT_DIR/requirements.txt" "$RES_DIR/requirements.txt"
cp "$SCRIPT_DIR/requirements.lock" "$RES_DIR/requirements.lock"
ok "Bundled Python source and hash-locked requirements"

# --- Bundle all model weights (NEW v0.2.0) ---
WEIGHTS_DIR="${REALPET_WEIGHTS_DIR:-$SCRIPT_DIR/weights}"
if [ "$STUB_WEIGHTS" = "1" ]; then
    # Placeholder tree in a temp dir so the repo's real weights/ is untouched
    echo "--- Stubbing model weights (--stub-weights) ---"
    WEIGHTS_DIR="$(mktemp -d)/weights"
    for d in sam2 torch; do
        mkdir -p "$WEIGHTS_DIR/$d"
        touch "$WEIGHTS_DIR/$d/.stub-weights-ci-only"
    done
    mkdir -p "$WEIGHTS_DIR/birefnet-fp16"
    for f in config.json model.safetensors birefnet.py; do
        touch "$WEIGHTS_DIR/birefnet-fp16/$f"
    done
    ok "Stub weights created (structural check only, app will NOT run)"
elif [ ! -d "$WEIGHTS_DIR/sam2" ] || [ ! -d "$WEIGHTS_DIR/birefnet-fp16" ] \
   || [ ! -d "$WEIGHTS_DIR/torch" ]; then
    echo "Error: verified model weights are required at $WEIGHTS_DIR; run the locked release-preparation workflow before packaging" >&2
    exit 1
else
    ok "Weights already present, skipping"
fi

if [ "$STUB_WEIGHTS" != "1" ]; then
    echo "--- Verifying release model weights ---"
    MODEL_PYTHON=""
    for candidate in "${REALPET_BUILD_PYTHON:-}" \
                     "$SCRIPT_DIR/.venv/bin/python" \
                     "$HOME/Library/Application Support/RealPet/venv/bin/python" \
                     python3.12 python3.11 python3.10 python3; do
        [ -n "$candidate" ] || continue
        if command -v "$candidate" >/dev/null 2>&1 \
           && "$candidate" -c 'import numpy, safetensors' >/dev/null 2>&1; then
            MODEL_PYTHON="$candidate"
            break
        fi
    done
    if [ -z "$MODEL_PYTHON" ]; then
        echo "Error: REALPET_BUILD_PYTHON must point to the hash-locked release environment" >&2
        exit 1
    fi
    "$MODEL_PYTHON" "$SCRIPT_DIR/scripts/verify_release_assets.py" \
        --weights-dir "$WEIGHTS_DIR"
    ok "Release model weights verified"
fi

rsync -a --exclude '.DS_Store' --exclude '__pycache__' --exclude '*.pyc' \
    --exclude '.locks' --exclude '*.lock' --exclude 'hf' \
    "$WEIGHTS_DIR/" "$APP_BUNDLE/Contents/Resources/weights/"
ok "Bundled release weights ($(du -sh "$APP_BUNDLE/Contents/Resources/weights" | cut -f1))"

# --- Bundle static ffmpeg (NEW v0.2.0) ---
FFMPEG_DIR="$APP_BUNDLE/Contents/Resources/bin"
mkdir -p "$FFMPEG_DIR"
FFMPEG_SOURCE="${REALPET_FFMPEG_PATH:-$SCRIPT_DIR/assets/bin/ffmpeg}"
FFPROBE_SOURCE="${REALPET_FFPROBE_PATH:-$(dirname "$FFMPEG_SOURCE")/ffprobe}"
FFMPEG_SHA256="${REALPET_FFMPEG_SHA256:-}"
FFPROBE_SHA256="${REALPET_FFPROBE_SHA256:-}"
if [ ! -x "$FFMPEG_SOURCE" ] || [ ! -x "$FFPROBE_SOURCE" ] \
   || [ -z "$FFMPEG_SHA256" ] || [ -z "$FFPROBE_SHA256" ]; then
    echo "Error: set REALPET_FFMPEG_PATH, REALPET_FFPROBE_PATH, and their SHA-256 values for verified release tools" >&2
    exit 1
fi
ACTUAL_FFMPEG_SHA256="$(shasum -a 256 "$FFMPEG_SOURCE" | awk '{print $1}')"
if [ "$ACTUAL_FFMPEG_SHA256" != "$FFMPEG_SHA256" ]; then
    echo "Error: ffmpeg SHA-256 does not match REALPET_FFMPEG_SHA256" >&2
    exit 1
fi
ACTUAL_FFPROBE_SHA256="$(shasum -a 256 "$FFPROBE_SOURCE" | awk '{print $1}')"
if [ "$ACTUAL_FFPROBE_SHA256" != "$FFPROBE_SHA256" ]; then
    echo "Error: ffprobe SHA-256 does not match REALPET_FFPROBE_SHA256" >&2
    exit 1
fi
cp "$FFMPEG_SOURCE" "$FFMPEG_DIR/ffmpeg"
chmod +x "$FFMPEG_DIR/ffmpeg"
cp "$FFPROBE_SOURCE" "$FFMPEG_DIR/ffprobe"
chmod +x "$FFMPEG_DIR/ffprobe"
"$FFMPEG_DIR/ffmpeg" -version | head -1
"$FFMPEG_DIR/ffprobe" -version | head -1
ok "Bundled static ffmpeg and ffprobe"

ok "App bundle assembled"

# 4. Ad-hoc code sign
echo ""
echo "--- Code signing ---"
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null
ok "Ad-hoc signed"

echo ""
echo -e "${GREEN}=== Done! ===${NC}"
echo "Output: $APP_BUNDLE"
echo ""
echo "To run: open $APP_BUNDLE"
echo ""
echo "First media-processing operation sets up Python (~2 min, one-time)."
echo "All model weights and ffmpeg are bundled. No downloads."
echo ""
echo "Ad-hoc-signed .app: right-click → Open the first time (Gatekeeper)."
