#!/bin/bash
# Freeze wtalk into a SEALED, code-signed wtalk.app with Nuitka.
# Run as your NORMAL user (needs the project .venv + your login keychain for signing). No sudo.
# Produces  wtalk/wtalk.app  (and a copy in  wtalk/dist/wtalk.app ).
#
# Why Nuitka (vs the old "copy the interpreter into a .app" trick): Nuitka bundles its OWN
# interpreter + EVERY dependency .so and then DEEP-SIGNS the whole bundle with one identity,
# so the hardened runtime's *library validation* is satisfied (all Mach-Os share our Team ID).
# That is what lets us keep the hardened runtime ON — unlike the old build, which had to
# disable it because it carried unsigned conda/venv extensions. Plus --python-flag=isolated
# /no_site makes the binary IGNORE PYTHONPATH/PYTHONHOME/user-site/env: it can only ever run
# the code baked inside it. That is "the seal" — combined with the root:wheel install, the
# user can neither modify the bundle nor redirect it to load their own code.
set -euo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
cd "$HERE"
APP="wtalk.app"
BUNDLE_ID="com.wtalk.daemon"
TEAM="BULCQM9J2V"          # your Apple Developer team (informational; identity carries it)

# --- interpreter: must be the project .venv (3.10) where the wheels are installed ---
PY="$HERE/.venv/bin/python"
[ -x "$PY" ] || { echo "✗ no $HERE/.venv — run ./setup.sh first (creates the venv + deps)"; exit 1; }

# --- ensure Nuitka is available IN THE VENV (it drives the venv's interpreter) ---
if ! "$PY" -c "import nuitka" >/dev/null 2>&1; then
    echo "▸ installing Nuitka into .venv"
    if command -v uv >/dev/null 2>&1; then
        VIRTUAL_ENV="$HERE/.venv" uv pip install nuitka
    else
        "$PY" -m pip install nuitka
    fi
fi

# --- pick the signing identity via the shared ladder: Developer ID → stable self-signed →
#     ad-hoc. (Override with CODESIGN_IDENTITY.) See ../sign-identity.sh. ---
SIGN_SH="$HERE/../sign-identity.sh"
if [ -f "$SIGN_SH" ]; then ID="$(bash "$SIGN_SH")"; else ID="${CODESIGN_IDENTITY:--}"; fi
[ -z "${ID:-}" ] && ID="-"
# Nuitka spells ad-hoc as the literal "ad-hoc"; a real cert is passed by its common name.
if [ "$ID" = "-" ]; then NUITKA_ID="ad-hoc"; else NUITKA_ID="$ID"; fi
echo "▸ signing identity: $NUITKA_ID"

echo "▸ cleaning previous build"
rm -rf "$HERE/$APP" "$HERE/wtalk.build" "$HERE/wtalk.dist" "$HERE/wtalk.onefile-build"

echo "▸ Nuitka freeze (first compile is SLOW — several minutes; later builds are cached)"
# Entry is wtalk.py → the bundle executable is named "wtalk" → Contents/MacOS/wtalk, which the
# /usr/local/bin/wtalk wrapper and the LaunchAgent both reference.
"$PY" -m nuitka \
    --standalone \
    --macos-create-app-bundle \
    --macos-app-name=wtalk \
    --macos-signed-app-name="$BUNDLE_ID" \
    --macos-app-version=2.0 \
    --macos-app-mode=ui-element \
    --macos-app-protected-resource="NSMicrophoneUsageDescription:wtalk needs the microphone for dictation" \
    --macos-sign-identity="$NUITKA_ID" \
    --python-flag=isolated \
    --python-flag=no_site \
    --include-module=config \
    --include-module=ui \
    --include-module=daemon \
    --include-package=parakeet_mlx \
    --include-package=mlx \
    --include-package=numpy \
    --include-package=scipy \
    --include-package=sounddevice \
    --include-package=httpx \
    --include-package=groq \
    --include-package=objc \
    --include-package=AppKit \
    --include-package=Quartz \
    --include-package=Foundation \
    --include-package=ApplicationServices \
    --include-package-data=mlx \
    --include-package-data=parakeet_mlx \
    --include-data-files="$HERE/config.txt=config.txt" \
    --include-data-dir="$HERE/prompts=prompts" \
    --assume-yes-for-downloads \
    --output-dir="$HERE" \
    "$HERE/wtalk.py"
#
# NOTES / things to verify on YOUR Mac (cannot be tested where this was authored):
#  • mlx_lm is deliberately NOT included: wtalk transcribes with parakeet_mlx (+ mlx), it does
#    not use mlx_lm. Add `--include-package=mlx_lm` only if a future feature needs it.
#  • pyobjc + Nuitka can miss a lazily-bound framework submodule. If the daemon dies at an
#    AppKit/Quartz/Foundation/ApplicationServices import, add the missing one with another
#    `--include-module=<Framework.Submodule>` and rebuild.
#  • --macos-sign-notarization (commented, optional): add it to the flags above AND use a
#    Developer ID identity to produce a notarizable bundle, then `xcrun notarytool submit`
#    + `stapler staple` it. Only worth it to move the app between Macs without Gatekeeper nags.
#  • Keep the hardened runtime ON. Do NOT add --macos-disable-library-validation: Nuitka
#    re-signs every bundled .so under our identity, so validation already passes.

NUITKA_OUT="$HERE/wtalk.dist/wtalk.app"   # Nuitka writes the bundle under <output-dir>/wtalk.dist
[ -d "$NUITKA_OUT" ] || NUITKA_OUT="$HERE/wtalk.app"   # (older Nuitka emitted it at top level)
[ -d "$NUITKA_OUT" ] || { echo "✗ Nuitka did not produce wtalk.app"; exit 1; }
rm -rf "$HERE/$APP"
cp -R "$NUITKA_OUT" "$HERE/$APP"

# --- mlx .metallib sanity check ---------------------------------------------------------------
# mlx ships a compiled Metal shader library (mlx.metallib). It MUST sit next to mlx's compiled
# .so (e.g. .../Contents/MacOS/mlx/lib/ or .../mlx/backend/...), because mlx resolves it relative
# to its own loaded dylib at runtime. If Nuitka instead drops it loose in Contents/MacOS or
# Contents/Frameworks, two things break: (1) mlx can't find its kernels → Metal errors at the
# first transcription, and (2) a stray .metallib in a Mach-O location fails notarization.
# We don't auto-relocate (its correct home is mlx-version-specific) — we surface it so you can
# eyeball that it travelled and is adjacent to an mlx .so, not loose at the bundle root.
echo "▸ metallib check (verify it sits NEXT TO an mlx .so, not loose in MacOS/ or Frameworks/):"
find "$HERE/$APP" -name '*.metallib' -print | sed 's#^#    #' || true
if ! find "$HERE/$APP" -name '*.metallib' | grep -q .; then
    echo "    ⚠️  NO .metallib found in the bundle — mlx will fail at transcription."
    echo "       Re-run with `--include-package-data=mlx` present (it is, above) and check that"
    echo "       your installed mlx wheel actually contains mlx.metallib."
fi

# --- verify the signature held after our copy ---
echo "▸ codesign verify"
codesign --verify --strict --verbose=2 "$HERE/$APP" || {
    echo "  ⚠️  signature broke during copy — re-signing the bundle in place"
    codesign --force --deep --options runtime --sign "$ID" \
        $( [ "$ID" != "-" ] && echo --timestamp ) \
        --identifier "$BUNDLE_ID" "$HERE/$APP"
    codesign --verify --strict --verbose=2 "$HERE/$APP"
}

# --- keep a prebuilt copy in dist/ (so a Mac without the toolchain could deploy by copy) ---
mkdir -p "$HERE/dist"
rm -rf "$HERE/dist/$APP"
cp -R "$HERE/$APP" "$HERE/dist/$APP"

# tidy Nuitka intermediates
rm -rf "$HERE/wtalk.build" "$HERE/wtalk.dist" "$HERE/wtalk.onefile-build"

echo
echo "✓ built $HERE/$APP  (sealed: isolated/no_site; signed: $NUITKA_ID; copied to dist/)"
echo "  install ROOT-OWNED with:  sudo ./install.sh"
