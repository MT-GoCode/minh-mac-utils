#!/usr/bin/env python3
"""wtalk — local push-to-talk dictation. One frozen binary, three jobs.

This single file is the Nuitka entry point for /Applications/wtalk.app. The SAME
compiled binary is used three ways, dispatched purely on argv:

  wtalk daemon          ← launchd LaunchAgent runs this: the always-on warm process
                          (mic + Parakeet + cleanup + menu-bar UI). Imports daemon.py.
  wtalk --prime-perms   ← fires the Microphone + Accessibility TCC prompts, then exits.
  wtalk <subcommand>    ← the lightweight CLI: status / toggle / cancel / verbatim /
                          history / restart / help. Signals the running daemon; does
                          NOT import the heavy ASR/UI stack.

Install/uninstall are NO LONGER subcommands here — they are root shell scripts
(install/install.sh) that deploy this bundle ROOT-OWNED to /Applications and wire up
the LaunchAgent. Keeping them out of the binary is the point: the binary is sealed.

Karabiner binds F5 → `/usr/local/bin/wtalk toggle`, which execs this binary inside the
bundle; that dispatches the `toggle` subcommand below, which SIGUSR1s the daemon.
"""
import os
import sys

# --- dev convenience only: re-exec under the repo .venv when run as a plain script ---
# In the FROZEN bundle there is no sibling .venv (and __compiled__ is defined by Nuitka),
# so this is a no-op there — the bundle already carries its own interpreter + packages,
# sealed by --python-flag=isolated/no_site. This branch matters solely when you run
# `./wtalk.py ...` straight out of a dev checkout.
if "__compiled__" not in globals():
    _ROOT = os.path.dirname(os.path.realpath(__file__))
    _VENV = os.path.join(_ROOT, ".venv")
    _VENV_PY = os.path.join(_VENV, "bin", "python")
    if os.path.exists(_VENV_PY) and os.path.realpath(sys.prefix) != os.path.realpath(_VENV):
        os.execv(_VENV_PY, [_VENV_PY, os.path.realpath(__file__), *sys.argv[1:]])

import signal       # noqa: E402
import subprocess   # noqa: E402
import time         # noqa: E402
from datetime import datetime  # noqa: E402

import config  # noqa: E402  (stdlib-only; safe + cheap to import for `status`)

_LABEL = "com.wtalk.agent"
_UID = os.getuid()
_DOMAIN = f"gui/{_UID}"

HELP = """wtalk — local dictation: F5 to speak, F5 again to paste a cleaned version at your cursor.

  wtalk             status: ready / loading / not running
  wtalk status      same as bare `wtalk`
  wtalk toggle      what F5 does: start dictation; run again to stop + clean + paste
  wtalk cancel      cancel the current dictation
  wtalk verbatim    stop + paste the RAW transcript, no AI cleanup (also the "Verbatim"
                    pill by the red dot; bindable to a key of your choice in Karabiner)
  wtalk restart     bounce the daemon (after editing ~/.wtalk/config.txt or ~/.wtalk/.env)
  wtalk history     last 20 dictations
  wtalk help        this message

  Install / uninstall are root operations now:  sudo ./install.sh  /  sudo ./uninstall.sh
  Trigger: F5 (bound in Karabiner → `wtalk toggle`) or the menu-bar mic icon.
  Perms:   Microphone (record) + Accessibility (paste at cursor), both shown as 'wtalk'.
  Config:  ~/.wtalk/config.txt   ·   keys: ~/.wtalk/.env   ·   logs: ~/.wtalk/daemon.log"""


# ============================ status ============================
def cmd_status():
    loaded = _agent_loaded()
    s = config.state_read()
    if not s or not config.alive(s.get("pid")):
        if loaded:
            print("◍ wtalk loading… (launchd agent up; Parakeet warming — check again in a moment)")
        else:
            print("○ wtalk not running — install it:  sudo ./install.sh")
        return
    if s.get("status") == "loading":
        print("◍ wtalk loading… (Parakeet warming up)")
        return
    line = f"● wtalk ready — mic: {s.get('mic')} · queue {s.get('queue_depth', 0)}"
    if s.get("listening"):
        line += " · LISTENING"
    elif s.get("worker_busy"):
        line += " · cleaning"
    print(line)
    hb = s.get("heartbeat")
    if hb:
        hb_age = (datetime.now(config.tzinfo()) - datetime.fromisoformat(hb)).total_seconds()
        if hb_age > 12:
            print(f"  ! heartbeat {hb_age:.0f}s stale — `wtalk restart`")
    if s.get("last_error"):
        print(f"  last error: {s['last_error']}")


# ====================== launchd (read/kick only — never creates the plist) ======================
def _agent_loaded():
    return subprocess.run(["launchctl", "print", f"{_DOMAIN}/{_LABEL}"],
                          capture_output=True).returncode == 0


def cmd_restart():
    """Bounce the daemon. The plist is owned by the root installer; here we only ask
    launchd to kickstart the already-installed agent. If it isn't loaded, the user
    hasn't installed yet (or needs to log out/in)."""
    if _agent_loaded():
        subprocess.run(["launchctl", "kickstart", "-k", f"{_DOMAIN}/{_LABEL}"], capture_output=True)
        print("restarting wtalk… (check `wtalk status`)")
    else:
        print("agent not loaded — (re)install with:  sudo ./install.sh")


# ====================== runtime signals ======================
def _signal_daemon(sig, label):
    s = config.state_read()
    if not s or not config.alive(s.get("pid")):
        print("wtalk not running — install it:  sudo ./install.sh"); return
    os.kill(int(s["pid"]), sig)
    time.sleep(0.3)
    s = config.state_read() or {}
    print(f"{label} — listening={s.get('listening')} queue={s.get('queue_depth', 0)}")


def cmd_toggle():
    _signal_daemon(signal.SIGUSR1, "→ toggled dictation")


def cmd_cancel():
    _signal_daemon(signal.SIGUSR2, "→ cancelled")


def cmd_verbatim():
    # Stop the current dictation but paste the RAW transcript (skip AI cleanup).
    _signal_daemon(signal.SIGWINCH, "→ verbatim (stop + paste raw)")


def cmd_history():
    rows = config.db_recent(20)
    if not rows:
        print("no history yet"); return
    for r in reversed(rows):
        when = (r.get("created_at") or "")[:19].replace("T", " ")
        out = (r.get("output") or r.get("transcript") or "").replace("\n", " ")
        print(f"  #{r.get('id'):<5} {when}  [{r.get('status')}]  {out[:80]}")


# ============================ dispatch ============================
def main():
    argv = sys.argv[1:]

    # --- daemon-side roles (only these import the heavy stack) ---
    if "--prime-perms" in argv:
        # Fire BOTH TCC prompts up front (used by the installer), then exit. Does NOT
        # load Parakeet. daemon.py owns the prompt helpers.
        import daemon  # noqa: E402
        try:
            daemon.prompt_accessibility()
        except Exception:
            pass
        try:
            daemon.prime_mic_permission()
        except Exception:
            pass
        return
    if argv and argv[0] == "daemon":
        # The launchd LaunchAgent entry. Run the warm daemon forever.
        import daemon  # noqa: E402
        daemon.Daemon().run()
        return

    # --- lightweight CLI ---
    cmd = argv[0] if argv else "status"
    fns = {"status": cmd_status, "restart": cmd_restart, "toggle": cmd_toggle,
           "cancel": cmd_cancel, "verbatim": cmd_verbatim, "history": cmd_history}
    if cmd in ("help", "-h", "--help"):
        print(HELP)
    elif cmd in fns:
        fns[cmd]()
    elif cmd in ("install", "uninstall"):
        print(f"`wtalk {cmd}` is now a root operation — run:  sudo ./{cmd}.sh\n")
        print(HELP)
    else:
        print(f"unknown command: {cmd}\n"); print(HELP)


if __name__ == "__main__":
    main()
