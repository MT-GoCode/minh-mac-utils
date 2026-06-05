"""wtalk settings + prompts + state file + tiny history DB.

Deliberately light: stdlib only, no heavy imports — the `wtalk` CLI imports this
for `status` without dragging in sounddevice / AppKit / MLX.
"""
import json
import os
import sqlite3
import threading
from datetime import datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def _load_env():
    env = ROOT / ".env"
    if not env.exists():
        return
    for line in env.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            os.environ.setdefault(k.strip(), v.strip())


def _load_cfg():
    cfg = {}
    for line in (ROOT / "config.txt").read_text().splitlines():
        line = line.split("#", 1)[0].strip()
        if line and "=" in line:
            k, v = line.split("=", 1)
            cfg[k.strip()] = v.strip()
    return cfg


_load_env()
_cfg = _load_cfg()


def _path(s):
    return Path(os.path.expanduser(s)).resolve()


# ---- ASR ----
PARAKEET_MODEL = _cfg.get("parakeet_model", "mlx-community/parakeet-tdt-0.6b-v2")
MIC = _cfg.get("mic", "builtin")
TARGET_SR = int(_cfg.get("target_sample_rate", 16000))
PAUSE_THRESHOLD_SEC = float(_cfg.get("pause_threshold_sec", 0.5))
CHUNK_OVER_SEC = float(_cfg.get("chunk_over_sec", 480))

# ---- routing / passthrough ----
PASSTHROUGH_MAX_WORDS = int(_cfg.get("passthrough_max_words", 10))
PASSTHROUGH_CONFIDENCE = float(_cfg.get("passthrough_confidence", 0.92))

# ---- cleanup models ----
GEMINI_MODEL = _cfg.get("gemini_model", "gemini-3.1-flash-lite")
GROQ_MODEL = _cfg.get("groq_model", "openai/gpt-oss-120b")
GROQ_REASONING = (_cfg.get("groq_reasoning", "low") or "").strip() or None
MAX_OUTPUT_TOKENS = int(_cfg.get("max_output_tokens", 1024))
TOK_PER_SEC = float(_cfg.get("tok_per_sec", 300))
DEADLINE_MULT = float(_cfg.get("deadline_multiplier", 2.0))
DEADLINE_FLOOR_SEC = float(_cfg.get("deadline_floor_sec", 2.0))
GROQ_TPM_LIMIT = int(_cfg.get("groq_tpm_limit", 8000))

# ---- hints pill ----
HINTS_ENABLED = _cfg.get("hints_enabled", "true").lower() in ("1", "true", "yes", "on")
HINTS_MAX_CHARS = int(_cfg.get("hints_max_chars", 150))

# ---- storage / display ----
DB_PATH = _path(_cfg.get("db_path", "~/.wtalk/history.db"))
STATE_PATH = _path(_cfg.get("state_path", "~/.wtalk/state.json"))
TIMEZONE = _cfg.get("timezone", "local")

SYSTEM_PROMPT_PATH = ROOT / "prompts" / "cleanup_system.txt"
USER_PROMPT_PATH = ROOT / "prompts" / "user.txt"


def system_prompt():
    return SYSTEM_PROMPT_PATH.read_text(encoding="utf-8").strip()


def user_prompt(transcript, hints=""):
    """Standing template (prompts/user.txt) with {transcript} filled in, plus an
    optional per-dictation spelling-hints block typed into the pill. Lines
    starting with # are file comments (never sent). .replace (not .format) so
    stray braces in the user-edited file are safe."""
    lines = [ln for ln in USER_PROMPT_PATH.read_text(encoding="utf-8").splitlines()
             if not ln.lstrip().startswith("#")]
    out = "\n".join(lines).replace("{transcript}", transcript).strip()
    hints = (hints or "").strip()
    if hints:
        out += ("\n\n## Spelling hints\n"
                "Correct spellings/casing for terms the speaker may have mis-dictated: "
                + hints + "\n"
                "Apply these where the transcript clearly refers to them; never "
                "force-insert a hint that isn't being said, and never echo this list.")
    return out


def tzinfo():
    if TIMEZONE.lower() == "local":
        return datetime.now().astimezone().tzinfo
    from zoneinfo import ZoneInfo
    return ZoneInfo(TIMEZONE)


# ---- state.json (daemon writes, CLI reads) ----
_state_lock = threading.Lock()


def state_write(d):
    with _state_lock:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = STATE_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(d, indent=2))
        tmp.replace(STATE_PATH)  # atomic


def state_read():
    try:
        return json.loads(STATE_PATH.read_text())
    except Exception:
        return None


def state_clear():
    try:
        STATE_PATH.unlink()
    except FileNotFoundError:
        pass


def alive(pid):
    if not pid:
        return False
    try:
        os.kill(int(pid), 0)
        return True
    except OSError:
        return False


# ---- tiny history DB (one row per dictation; no TUI) ----
_SCHEMA = """CREATE TABLE IF NOT EXISTS dictations(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  created_at TEXT, duration_sec REAL,
  transcript TEXT, output TEXT, model TEXT, status TEXT)"""


def db_insert(duration_sec, transcript, output, model, status):
    try:
        DB_PATH.parent.mkdir(parents=True, exist_ok=True)
        with sqlite3.connect(DB_PATH) as c:
            c.execute(_SCHEMA)
            c.execute(
                "INSERT INTO dictations(created_at,duration_sec,transcript,output,model,status)"
                " VALUES(?,?,?,?,?,?)",
                (datetime.now(tzinfo()).isoformat(timespec="seconds"),
                 duration_sec, transcript, output, model, status))
    except Exception:
        pass


def db_recent(n=20):
    try:
        with sqlite3.connect(DB_PATH) as c:
            c.row_factory = sqlite3.Row
            c.execute(_SCHEMA)
            return [dict(r) for r in c.execute(
                "SELECT * FROM dictations ORDER BY id DESC LIMIT ?", (n,))]
    except Exception:
        return []
