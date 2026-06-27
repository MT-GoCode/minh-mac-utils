#!/bin/bash
# Freeze wtalk into a SEALED, code-signed wtalk.app with PyInstaller.
# Run as your NORMAL user (needs the project .venv + your login keychain for signing). No sudo.
# Produces  wtalk/wtalk.app  (and a copy in  wtalk/dist/wtalk.app ).
#
# Why PyInstaller (we tried Nuitka — pyobjc's giant *_metadata.c files take ~10 min EACH to C-
# compile, making the build multi-hour/unreliable). PyInstaller bundles its OWN CPython + every
# dependency .dylib/.so and DEEP-SIGNS the whole bundle under one identity, so the hardened
# runtime's library validation is satisfied. "The seal" here = (1) the launched binary is the
# PyInstaller bootloader, NOT a `python` CLI: it takes no `-c`/`-m`/argv-script and runs only the
# embedded bytecode; PyInstaller ≥6 blocks host PYTHONPATH/PYTHONHOME from overriding bundled
# modules. (2) the install is root:wheel — you can't replace the embedded code without sudo, and
# any edit breaks the signature. Together that's what lets demonlock whitelist it with no hole.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
APP="wtalk.app"
BUNDLE_ID="com.wtalk.daemon"

PY="$HERE/.venv/bin/python"
[ -x "$PY" ] || { echo "✗ no $HERE/.venv — run ./setup.sh first (creates the venv + deps)"; exit 1; }

# --- ensure PyInstaller is in the venv ---
if ! "$PY" -c "import PyInstaller" >/dev/null 2>&1; then
    echo "▸ installing PyInstaller into .venv"
    if command -v uv >/dev/null 2>&1; then VIRTUAL_ENV="$HERE/.venv" uv pip install pyinstaller
    else "$PY" -m pip install pyinstaller; fi
fi

# --- signing identity via the shared ladder: Developer ID → stable self-signed → ad-hoc. ---
SIGN_SH="$HERE/../sign-identity.sh"
if [ -f "$SIGN_SH" ]; then ID="$(bash "$SIGN_SH")"; else ID="${CODESIGN_IDENTITY:--}"; fi
[ -z "${ID:-}" ] && ID="-"
echo "▸ signing identity: $ID"

echo "▸ cleaning previous build"
rm -rf "$HERE/$APP" "$HERE/_pyi_build" "$HERE/_pyi_dist"

echo "▸ PyInstaller freeze (a few minutes; later builds are faster)"
# --windowed → an .app bundle; --collect-all pulls each package's data + dylibs (mlx ships its
# Metal shader lib mlx.metallib + libmlx.dylib; parakeet_mlx its weights/configs; sounddevice the
# PortAudio dylib). numpy/scipy/httpx/groq/pyobjc are pulled by PyInstaller's bundled hooks.
"$PY" -m PyInstaller --noconfirm --clean --windowed \
    --name wtalk \
    --osx-bundle-identifier "$BUNDLE_ID" \
    --collect-all mlx \
    --collect-all parakeet_mlx \
    --collect-all sounddevice \
    --collect-all groq \
    --collect-submodules objc \
    --collect-submodules AppKit \
    --collect-submodules Quartz \
    --collect-submodules Foundation \
    --collect-submodules ApplicationServices \
    --add-data "$HERE/config.txt:." \
    --add-data "$HERE/prompts:prompts" \
    --distpath "$HERE/_pyi_dist" --workpath "$HERE/_pyi_build" --specpath "$HERE/_pyi_build" \
    "$HERE/wtalk.py"

PYI_OUT="$HERE/_pyi_dist/$APP"
[ -d "$PYI_OUT" ] || { echo "✗ PyInstaller did not produce $APP"; exit 1; }
rm -rf "$HERE/$APP"; cp -R "$PYI_OUT" "$HERE/$APP"

# --- Info.plist: PyInstaller doesn't set LSUIElement / the mic-usage string — add them, then sign. ---
PLIST="$HERE/$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :LSUIElement bool true" "$PLIST" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Set :LSUIElement true" "$PLIST"
/usr/libexec/PlistBuddy -c "Add :NSMicrophoneUsageDescription string 'wtalk needs the microphone for dictation'" "$PLIST" 2>/dev/null || true

# --- mlx .metallib sanity check (must travel + load relative to mlx's dylib at runtime) ---
echo "▸ metallib check:"
find "$HERE/$APP" -name '*.metallib' -print | sed 's#^#    #' || true
find "$HERE/$APP" -name '*.metallib' | grep -q . || echo "    ⚠️  NO .metallib in bundle — mlx will fail at transcription."

# --- deep-sign the WHOLE bundle last (after the plist edit), hardened runtime ON ---
echo "▸ codesign (deep, hardened runtime) with: $ID"
SIGN=(--force --deep --options runtime --sign "$ID" --identifier "$BUNDLE_ID")
[ "$ID" != "-" ] && SIGN+=(--timestamp)
codesign "${SIGN[@]}" "$HERE/$APP"
codesign --verify --deep --strict --verbose=2 "$HERE/$APP"

# --- keep a prebuilt copy in dist/ ---
mkdir -p "$HERE/dist"; rm -rf "$HERE/dist/$APP"; cp -R "$HERE/$APP" "$HERE/dist/$APP"
rm -rf "$HERE/_pyi_build" "$HERE/_pyi_dist"

echo
echo "✓ built $HERE/$APP  (signed: $ID; copied to dist/)"
echo "  exe: $(ls "$HERE/$APP/Contents/MacOS/" 2>/dev/null | tr '\n' ' ')"
echo "  install ROOT-OWNED with:  sudo ./install.sh"
#
# NOTES / verify on YOUR Mac:
#  • If the daemon dies at an AppKit/Quartz/Foundation import, add the missing one as another
#    --collect-submodules / --hidden-import and rebuild.
#  • Optional notarization (move between Macs without Gatekeeper nags): after a Developer-ID build,
#    ditto -c -k --keepParent wtalk.app wtalk.zip && xcrun notarytool submit … && stapler staple.
#  • Keep hardened runtime ON; do not add entitlements that disable library validation.
