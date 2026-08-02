#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="${REALPET_VENV:-$SCRIPT_DIR/.venv}"
WEIGHTS_DIR="${REALPET_WEIGHTS_DIR:-$SCRIPT_DIR/weights}"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; exit 1; }

echo "=== RealPet Installer ==="
echo ""
echo "--- Checking dependencies ---"

# The requirements lock is compiled and tested against the macOS-supported
# Python versions only. A newer interpreter must not silently select a wheel
# outside the tested lock environment.
PYTHON=""
for candidate in python3.12 python3.11 python3.10 python3; do
    if command -v "$candidate" >/dev/null 2>&1; then
        version=$("$candidate" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        major=${version%%.*}
        minor=${version##*.}
        if [ "$major" -eq 3 ] && [ "$minor" -ge 10 ] && [ "$minor" -le 12 ]; then
            PYTHON="$candidate"
            ok "Python $version ($candidate)"
            break
        fi
    fi
done
if [ -z "$PYTHON" ]; then
    actual=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null || true)
    fail "Python 3.10-3.12 required, found ${actual:-none}. Install with: brew install python@3.12"
fi

if command -v ffmpeg >/dev/null 2>&1; then
    ok "ffmpeg $(ffmpeg -version 2>&1 | head -1 | awk '{print $3}')"
else
    fail "ffmpeg not found. Install with: brew install ffmpeg"
fi

echo ""
echo "--- Setting up Python environment ---"
if [ -d "$VENV_DIR" ]; then
    warn "Venv already exists at $VENV_DIR, reusing it"
else
    "$PYTHON" -m venv "$VENV_DIR"
    ok "Venv created"
fi

echo ""
echo "--- Installing Python dependencies ---"
"$VENV_DIR/bin/pip" install --require-hashes -r "$SCRIPT_DIR/requirements.txt" -q
ok "Hash-locked Python dependencies installed"

echo ""
echo "--- Preparing verified model weights ---"
REALPET_WEIGHTS_DIR="$WEIGHTS_DIR" \
    "$VENV_DIR/bin/python" "$SCRIPT_DIR/scripts/bundle_weights.py" --out "$WEIGHTS_DIR"
REALPET_WEIGHTS_DIR="$WEIGHTS_DIR" \
    "$VENV_DIR/bin/python" "$SCRIPT_DIR/scripts/verify_release_assets.py" --weights-dir "$WEIGHTS_DIR"
ok "Verified model weights prepared"

echo ""
echo "--- Verification ---"
MISSING=$("$VENV_DIR/bin/python" -c "
import sys; sys.path.insert(0, '$SCRIPT_DIR')
from scripts.track_then_matte import check_dependencies
print('\\n'.join(check_dependencies()))
" 2>/dev/null)
if [ -n "$MISSING" ]; then
    fail "Missing dependencies:\n$MISSING"
fi
ok "All dependencies satisfied"

echo ""
echo -e "${GREEN}=== Installation complete! ===${NC}"
echo ""
echo "To run the app:"
echo "  cd RealPet && swift build -c release && swift run"
echo ""
echo "To build a release bundle, provide the product keys and a separately verified ffmpeg binary:"
echo "  REALPET_SUPABASE_PUBLISHABLE_KEY=<publishable-key> REALPET_AGNES_API_KEY=<agnes-key> REALPET_FFMPEG_PATH=/path/to/verified/ffmpeg REALPET_FFMPEG_SHA256=<sha256> ./build_app.sh"
