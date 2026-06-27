#!/usr/bin/env bash
# wtalk one-shot setup: copy the source to a Mac, then run `./setup.sh`.
# Idempotent — safe to re-run. See README.md for what each step does.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"

echo "── wtalk setup ──"

# 1. Platform + tool checks
[[ "$(uname)" == "Darwin" && "$(uname -m)" == "arm64" ]] || {
    echo "✗ needs Apple Silicon macOS"; exit 1; }
command -v uv >/dev/null || {
    echo "✗ uv not found — install it: https://docs.astral.sh/uv/  (curl -LsSf https://astral.sh/uv/install.sh | sh)"; exit 1; }
if ! command -v ffmpeg >/dev/null; then
    echo "• installing ffmpeg…"
    command -v brew >/dev/null && brew install ffmpeg || {
        echo "✗ install ffmpeg (Parakeet needs it): brew install ffmpeg"; exit 1; }
fi

# 2. Per-project venv (pinned to 3.10 so the mlx/pyobjc/numpy wheels resolve) + deps
echo "• creating .venv (Python 3.10) + installing deps…"
uv venv --python 3.10
uv pip install -r requirements.txt

# setup.sh now ONLY prepares the build prerequisites (venv + deps + ffmpeg). The app itself
# is frozen with Nuitka and installed ROOT-OWNED by the sudo installer — it is NOT built into
# a user dir, and `wtalk install` no longer exists (install is a root operation now).
echo
echo "✓ build prerequisites ready (.venv + deps)."
echo
echo "▸ Next — freeze + install the sealed, root-owned app (handles keys, perms, launchd):"
echo "      sudo ./install.sh"
echo
echo "  The installer will: Nuitka-freeze + sign wtalk.app, deploy it root:wheel to"
echo "  /Applications, install the /usr/local/bin/wtalk CLI, seed ~/.wtalk (.env, config.txt,"
echo "  prompts), and load the LaunchAgent. (First Nuitka compile is slow — several minutes.)"
echo
echo "  Then: add GEMINI_API_KEY to ~/.wtalk/.env (https://aistudio.google.com/apikey) and"
echo "  'wtalk restart'; grant Microphone + Accessibility (shown as 'wtalk'); and bind F5 in"
echo "  Karabiner-Elements to:  /usr/local/bin/wtalk toggle"
