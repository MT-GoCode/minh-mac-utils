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

# 3. .env (API keys) — created as a template if missing
if [[ ! -f .env ]]; then
    cat > .env <<'EOF'
# Required: Gemini cleanup (https://aistudio.google.com/apikey)
GEMINI_API_KEY=
# Optional fallback (https://console.groq.com/keys). A 2nd key doubles rate headroom.
GROQ_API_KEY=
GROQ_API_KEY_2=
EOF
    echo "• created .env — add your GEMINI_API_KEY to it."
fi

# 4. Put `wtalk` on PATH
mkdir -p "$HOME/.local/bin"
ln -sf "$ROOT/wtalk" "$HOME/.local/bin/wtalk"
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *)  LINE='export PATH="$HOME/.local/bin:$PATH"'
        grep -qsF "$LINE" "$HOME/.zshrc" 2>/dev/null || printf '\n%s\n' "$LINE" >> "$HOME/.zshrc"
        echo "• added ~/.local/bin to PATH in ~/.zshrc — run: source ~/.zshrc (or open a new terminal)" ;;
esac

# 5. Install the always-on daemon (builds + signs wtalk.app, loads launchd) — only
#    once a Gemini key is present, so the daemon actually works on first launch.
if grep -qE '^GEMINI_API_KEY=.+' .env; then
    "$ROOT/wtalk" install
else
    echo
    echo "▸ Next: add GEMINI_API_KEY to $ROOT/.env, then run:  wtalk install"
fi

echo
echo "▸ Last step (manual): bind F5 in Karabiner-Elements to run:"
echo "      $HOME/.local/bin/wtalk toggle"
echo "  (and optionally a key → 'wtalk cancel'). Then grant Microphone + Accessibility"
echo "  to 'wtalk' when prompted. Done — press F5 to dictate."
