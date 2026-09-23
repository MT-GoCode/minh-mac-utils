#!/usr/bin/env bash
# bootstrap.sh — stand up gitas on a fresh machine (macOS or Linux), reproducibly.
#
#   ./bootstrap.sh <accounts.ini> [repo-dir]
#
# Copy your filled-in accounts.ini onto the machine by hand first (it holds PATs; it is never
# committed). Everything else this script does is idempotent -- re-run it any time.
#
# Order matters: the repo clone needs credentials, but gitas IS the credential helper, so the
# clone uses the token inline and the remote is immediately rewritten to a clean URL. The token
# never lands in .git/config.
set -euo pipefail

ACC="${1:-}"; REPO_DIR="${2:-$HOME/code/minh-mac-utils}"
REPO_URL="https://github.com/MT-GoCode/minh-mac-utils.git"
BINDIR="$HOME/.local/bin"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*" >&2; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

[ -n "$ACC" ] || bad "usage: ./bootstrap.sh <accounts.ini> [repo-dir]"
[ -f "$ACC" ] || bad "no such accounts file: $ACC"
[ "$(id -u)" -ne 0 ] || bad "do not run as root — gitas is per-user"
command -v git >/dev/null || bad "git not installed"

# git >= 2.36 is required: includeIf hasconfig: silently no-ops on older git, so email routing
# would appear to work while doing nothing.
gv=$(git --version | awk '{print $3}'); gmaj=${gv%%.*}; grest=${gv#*.}; gmin=${grest%%.*}
if [ "$gmaj" -lt 2 ] || { [ "$gmaj" -eq 2 ] && [ "$gmin" -lt 36 ]; }; then
  bad "git $gv is too old — includeIf hasconfig: needs >= 2.36"
fi
ok "git $gv"

USER_GH=$(awk -F'= *' '/^[[:space:]]*user[[:space:]]*=/{print $2; exit}' "$ACC" | tr -d '[:space:]')
TOKEN=$(awk -F'= *'  '/^[[:space:]]*token[[:space:]]*=/{print $2; exit}' "$ACC" | tr -d '[:space:]')
[ -n "$USER_GH" ] && [ -n "$TOKEN" ] || bad "$ACC is missing a user= or token= in its first account"

# ---------------------------------------------------------------- 1. repo
if [ -d "$REPO_DIR/.git" ]; then
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
  git -C "$REPO_DIR" -c credential.helper= \
      -c "credential.https://github.com.helper=!f(){ echo username=$USER_GH; echo password=$TOKEN; };f" \
      fetch -q origin && git -C "$REPO_DIR" merge -q --ff-only origin/main 2>/dev/null || true
  ok "updated $REPO_DIR"
else
  mkdir -p "$(dirname "$REPO_DIR")"
  git -c credential.helper= \
      -c "credential.https://github.com.helper=!f(){ echo username=$USER_GH; echo password=$TOKEN; };f" \
      clone -q "$REPO_URL" "$REPO_DIR"
  git -C "$REPO_DIR" remote set-url origin "$REPO_URL"   # ensure no token in .git/config
  ok "cloned $REPO_DIR"
fi
grep -q "$TOKEN" "$REPO_DIR/.git/config" 2>/dev/null && bad "token leaked into .git/config" || ok "no token in .git/config"

# ---------------------------------------------------------------- 2. gitas (purges, then installs)
bash "$REPO_DIR/gitas/install.sh" "$ACC"

# ---------------------------------------------------------------- 3. PATH
case ":$PATH:" in
  *":$BINDIR:"*) ok "$BINDIR already on PATH" ;;
  *)
    case "$(basename "${SHELL:-/bin/bash}")" in zsh) RC="$HOME/.zshrc" ;; *) RC="$HOME/.bashrc" ;; esac
    if ! grep -q 'local/bin' "$RC" 2>/dev/null; then
      printf '\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$RC"; ok "added $BINDIR to $RC"
    else ok "$RC already references local/bin"; fi
    warn "open a new shell (or: export PATH=\"\$HOME/.local/bin:\$PATH\") for gitas to be on PATH"
    ;;
esac

# ---------------------------------------------------------------- 4. SSH GitHub remotes -> HTTPS
n=0
while IFS= read -r g; do
  d=$(dirname "$g")
  for r in $(git -C "$d" remote 2>/dev/null); do
    u=$(git -C "$d" remote get-url "$r" 2>/dev/null) || continue
    case "$u" in
      git@github.com:*)        nu="https://github.com/${u#git@github.com:}" ;;
      ssh://git@github.com/*)  nu="https://github.com/${u#ssh://git@github.com/}" ;;
      *) continue ;;
    esac
    git -C "$d" remote set-url "$r" "$nu"; echo "     ${d#$HOME/}  $r -> $nu"; n=$((n+1))
  done
done < <(find "$HOME" -maxdepth 5 -name .git -type d -not -path "*/node_modules/*" -not -path "*/.cache/*" 2>/dev/null)
ok "converted $n ssh remote(s) to https"

# ---------------------------------------------------------------- 5. verify
echo; echo "▸ verify"
"$BINDIR/gitas" list
echo "  authenticated fetch: $(git -C "$REPO_DIR" ls-remote origin HEAD 2>&1 | head -1 | cut -c1-40)"
echo "  identity here      : $(git -C "$REPO_DIR" config user.email)"
ok "bootstrap complete"
