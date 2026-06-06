"""wtalk daemon — one warm process: mic capture + Parakeet + clean-race + overlay.

Triggered by `wtalk toggle`/`cancel` (SIGUSR1/2), which Karabiner fires from F5.
wtalk does not capture keys itself.

Design goals (why this is a rewrite): it must NEVER wedge and NEVER silently
swallow an F5.
  - Mic stop snapshots the audio and closes the PortAudio stream on a DETACHED
    thread, so a slow CoreAudio close can't freeze the control thread.
  - Starting a new dictation never waits on a previous cleanup (no START lock).
  - Cleanup is a deadline-bounded race: Gemini first; if it's slow, run Groq in
    parallel and take whichever returns; if both are slow, paste the raw
    transcript. A cleanup stall is therefore invisible — you always get text.

Threads: main (AppKit run loop + UI tick + signal servicing), control (start/
stop the mic, enqueue jobs), worker (FIFO: transcribe -> clean-race -> paste).
"""
import collections
import fcntl
import os
import queue
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import wave
from concurrent.futures import ThreadPoolExecutor, TimeoutError as FuturesTimeout, wait, FIRST_COMPLETED
from datetime import datetime
from pathlib import Path
from time import monotonic, sleep

import numpy as np
import sounddevice as sd

import config
import ui

_KARABINER_CLI = "/Library/Application Support/org.pqrs/Karabiner-Elements/bin/karabiner_cli"
_LOG_CAP_BYTES = 4 * 1024 * 1024
_GEMINI_URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"


# ===================== small helpers =====================
def _log(msg):
    try:
        print(f"{datetime.now().isoformat(timespec='seconds')} {msg}", flush=True)
    except Exception:
        pass


def _notify(msg):
    """macOS banner. Callers pass controlled strings (no double quotes)."""
    try:
        subprocess.Popen(["osascript", "-e",
                          f'display notification "{msg}" with title "wtalk"'],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


# nowplaying-cli media control, with a quick system-volume fade wrapped around it.
_VOL_STEP = 20            # output-volume units per fade step
_VOL_DELAY = 0.01         # seconds per step  → "0.01 per 20 units"


def _np_is_playing(cli):
    """True iff media is actively playing (`nowplaying-cli get playbackRate` == 1)."""
    try:
        rate = subprocess.run([cli, "get", "playbackRate"],
                              capture_output=True, text=True, timeout=2).stdout.strip()
        return float(rate) == 1.0             # "1" / "1.000000" → playing at normal speed
    except Exception:
        return False


def _np_toggle(cli):
    """nowplaying-cli togglePlayPause, best-effort."""
    try:
        subprocess.run([cli, "togglePlayPause"],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=2)
    except Exception:
        pass


def _volume_fade_out():
    """Fade macOS output volume down to 0 (in _VOL_STEP-unit steps, _VOL_DELAY s each)
    in a SINGLE osascript spawn — as low-latency as a fade gets. Returns the pre-fade
    volume (0-100) so the caller can fade back in later, or None on failure."""
    script = (
        "set v to output volume of (get volume settings)\n"
        f"repeat with i from v to 0 by -{_VOL_STEP}\n"
        "  set volume output volume i\n"
        f"  delay {_VOL_DELAY}\n"
        "end repeat\n"
        "set volume output volume 0\n"
        "return v"
    )
    try:
        out = subprocess.run(["osascript", "-e", script],
                             capture_output=True, text=True, timeout=5).stdout.strip()
        return int(out)
    except Exception:
        return None


def _volume_fade_in(target):
    """Fade macOS output volume from 0 up to `target` (in _VOL_STEP-unit steps,
    _VOL_DELAY s each) in a SINGLE osascript spawn. No-op if target is None."""
    if target is None:
        return
    try:
        target = max(0, min(100, int(target)))
    except Exception:
        return
    script = (
        "on run argv\n"
        "  set t to (item 1 of argv) as integer\n"
        "  set volume output volume 0\n"
        f"  repeat with i from 0 to t by {_VOL_STEP}\n"
        "    set volume output volume i\n"
        f"    delay {_VOL_DELAY}\n"
        "  end repeat\n"
        "  set volume output volume t\n"
        "end run"
    )
    try:
        subprocess.run(["osascript", "-e", script, str(target)],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
    except Exception:
        pass


def _set_kb_listening(on):
    """Signal Karabiner we're listening, so its Esc rule cancels only while dictating."""
    try:
        subprocess.Popen([_KARABINER_CLI, "--set-variables",
                          '{"wtalk_listening": %d}' % (1 if on else 0)],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception:
        pass


def now_iso():
    return datetime.now(config.tzinfo()).isoformat(timespec="seconds")


# ===================== paste =====================
def ax_trusted():
    """Whether this process may synthesize keystrokes (Accessibility granted).
    Accurate inside the launchd daemon (no terminal parent to inherit trust from)."""
    try:
        from ApplicationServices import AXIsProcessTrusted
        return bool(AXIsProcessTrusted())
    except Exception:
        return True            # can't tell -> try anyway


def prompt_accessibility():
    """If Accessibility isn't granted, pop the standard macOS dialog ('wtalk would
    like to control this computer…' → Open System Settings) — the normal app
    prompt, instead of making the user hunt for a binary."""
    try:
        from ApplicationServices import AXIsProcessTrustedWithOptions
        try:
            from ApplicationServices import kAXTrustedCheckOptionPrompt as K
        except Exception:
            K = "AXTrustedCheckOptionPrompt"
        return bool(AXIsProcessTrustedWithOptions({K: True}))
    except Exception:
        return True


def prime_mic_permission():
    """Open + immediately close a tiny input stream to trigger the macOS Microphone
    TCC prompt (attributed to this signed 'wtalk' app). Best-effort; used by
    `wtalk install` so the Mic dialog appears up front instead of on first record."""
    try:
        s = sd.InputStream(channels=1, samplerate=16000)
        s.start(); sleep(0.15); s.stop(); s.close()
    except Exception:
        pass


def paste(text):
    """Put `text` on the clipboard, then synthesize Cmd+V. Returns False WITHOUT
    synthesizing when Accessibility isn't granted — the text is still on the
    clipboard so you can ⌘V manually, and the caller surfaces a 'grant
    Accessibility' notice instead of a misleading ✓."""
    from AppKit import NSPasteboard, NSStringPboardType
    pb = NSPasteboard.generalPasteboard()
    pb.clearContents()
    pb.setString_forType_(text, NSStringPboardType)
    if not ax_trusted():
        return False
    from Quartz import (CGEventCreateKeyboardEvent, CGEventPost, CGEventSetFlags,
                        kCGEventFlagMaskCommand, kCGHIDEventTap)
    time.sleep(0.02)  # let the pasteboard settle
    down = CGEventCreateKeyboardEvent(None, 9, True)   # 'v'
    CGEventSetFlags(down, kCGEventFlagMaskCommand)
    up = CGEventCreateKeyboardEvent(None, 9, False)
    CGEventSetFlags(up, kCGEventFlagMaskCommand)
    CGEventPost(kCGHIDEventTap, down)
    time.sleep(0.005)
    CGEventPost(kCGHIDEventTap, up)
    return True


# ===================== ASR: mic + Parakeet + pauses =====================
_model = None


def _write_wav(path, audio_f32, sr):
    pcm = (np.clip(audio_f32, -1, 1) * 32767).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes(pcm.tobytes())


def load_parakeet():
    """Load Parakeet and compile kernels. Call once at startup."""
    global _model
    from parakeet_mlx import from_pretrained
    _model = from_pretrained(config.PARAKEET_MODEL)
    tmp = Path(tempfile.gettempdir()) / "wtalk_warmup.wav"
    _write_wav(tmp, np.zeros(config.TARGET_SR // 2, dtype=np.float32), config.TARGET_SR)
    _model.transcribe(str(tmp))
    return _model


def reset_audio():
    """Tear down + re-init PortAudio to recover a wedged device."""
    for fn in (sd._terminate, sd._initialize):
        try:
            fn()
        except Exception:
            pass


def is_host_api_error(exc):
    """PortAudio errors that a terminate/re-init can clear (CoreAudio not ready
    yet — common right after login when launchd respawns us mid-login)."""
    s = str(exc).lower()
    return ("host api" in s or "-9999" in s or "-9986" in s
            or "unanticipated host error" in s)


_BUILTIN_PATTERNS = ("macbook", "built-in", "built in", "imac", "mac mini", "mac studio")


def _resolve_device():
    """(device_index_or_None, name, src_sr). Default 'builtin' = internal mic and
    AVOIDS Bluetooth: opening a BT mic forces a headset out of music mode (A2DP)
    into muffled hands-free (HFP). 'default' follows system input; a name
    substring pins a specific mic."""
    devs = sd.query_devices()
    pref = config.MIC.strip().lower()

    def by_index(i):
        return i, devs[i]["name"], int(devs[i]["default_samplerate"])

    def system_default():
        d = sd.query_devices(kind="input")
        return None, d["name"], int(d["default_samplerate"])

    if pref in ("builtin", "built-in", "internal", ""):
        for i, d in enumerate(devs):
            if d["max_input_channels"] > 0 and any(p in d["name"].lower() for p in _BUILTIN_PATTERNS):
                return by_index(i)
        return system_default()
    if pref == "default":
        return system_default()
    for i, d in enumerate(devs):
        if d["max_input_channels"] > 0 and pref in d["name"].lower():
            return by_index(i)
    return system_default()


def _vad_pauses(audio, sr, threshold_sec):
    """Internal silences longer than threshold_sec, as [(start_s, length_s)]."""
    if len(audio) < sr // 2:
        return []
    fl, hop = int(0.02 * sr), int(0.01 * sr)
    rms = np.array([np.sqrt(np.mean(audio[i:i + fl] ** 2))
                    for i in range(0, len(audio) - fl, hop)])
    lo, hi = np.percentile(rms, [20, 90])
    thr = max(lo + 0.15 * (hi - lo), 1e-3)
    silent = rms < thr
    total = len(audio) / sr
    pauses, i = [], 0
    while i < len(silent):
        if silent[i]:
            j = i
            while j < len(silent) and silent[j]:
                j += 1
            start, dur = i * hop / sr, (j - i) * hop / sr
            if dur > threshold_sec and start > 0.1 and (j * hop / sr) < total - 0.1:
                pauses.append((start, dur))
            i = j
        else:
            i += 1
    return pauses


def _build_markers(result, audio, sr, threshold):
    """(plain_text, marked_text, pauses[]). [pause-Xs] placed before the first
    word-initial token starting after each detected pause."""
    if result is None:
        return "", "", []
    toks = [t for s in result.sentences for t in s.tokens]
    pauses = _vad_pauses(audio, sr, threshold)
    marks, rec = {}, []
    for start, dur in pauses:
        idx = next((i for i, t in enumerate(toks)
                    if t.text.startswith(" ") and t.start >= start), None)
        if idx is None:
            continue
        marks.setdefault(idx, dur)
        rec.append({"at": round(start, 2), "len": round(dur, 1)})
    out = []
    for i, t in enumerate(toks):
        if i in marks:
            out.append(f" [pause-{marks[i]:.1f}s]")
        out.append(t.text)
    return result.text.strip(), "".join(out).strip(), rec


class Session:
    """One mic capture. Open on the control thread; transcribe later on the
    worker. snapshot() closes the stream on a detached thread so the control
    thread never blocks on PortAudio."""

    def __init__(self):
        self.device, self.mic_name, self.src_sr = _resolve_device()
        self.frames = []
        self.samples = 0
        self.result = None
        self._capturing = True
        self._stream = sd.InputStream(
            samplerate=self.src_sr, channels=1, dtype="float32",
            device=self.device, callback=self._cb)

    def _cb(self, indata, frames, time_info, status):
        if self._capturing:
            self.frames.append(indata[:, 0].copy())
            self.samples += frames

    def _to16k(self, audio):
        if self.src_sr == config.TARGET_SR:
            return audio
        from scipy.signal import resample_poly
        return resample_poly(audio, config.TARGET_SR, self.src_sr).astype(np.float32)

    @property
    def duration(self):
        return self.samples / self.src_sr if self.src_sr else 0.0

    def start(self):
        self._stream.start()

    def _close_detached(self):
        threading.Thread(target=self._close, daemon=True).start()

    def _close(self):
        try:
            self._stream.stop(); self._stream.close()
        except Exception:
            pass

    def snapshot(self):
        """Stop capturing, grab the audio, close the mic in the background. Fast."""
        self._capturing = False
        self._audio = np.concatenate(self.frames) if self.frames else np.zeros(0, np.float32)
        self._close_detached()
        return self

    def cancel(self):
        self._capturing = False
        self._close_detached()

    def transcribe(self):
        """Run Parakeet on the captured audio. Heavy (MLX/Metal) — worker only."""
        audio = getattr(self, "_audio", None)
        if audio is None:
            audio = np.concatenate(self.frames) if self.frames else np.zeros(0, np.float32)
        if not len(audio):
            return {"text": "", "marked": "", "duration": 0.0, "pauses": [], "confidence": 0.0}
        tmp = Path(tempfile.gettempdir()) / "wtalk_capture.wav"
        _write_wav(tmp, self._to16k(audio), config.TARGET_SR)
        kw = ({"chunk_duration": 300.0, "overlap_duration": 15.0}
              if self.duration > config.CHUNK_OVER_SEC else {})
        self.result = _model.transcribe(str(tmp), **kw)
        plain, marked, pauses = _build_markers(self.result, audio, self.src_sr,
                                               config.PAUSE_THRESHOLD_SEC)
        toks = [t for s in self.result.sentences for t in s.tokens] if self.result else []
        conf = min((t.confidence for t in toks), default=0.0)
        return {"text": plain, "marked": marked, "duration": self.duration,
                "pauses": pauses, "confidence": conf}


# ===================== cleanup: Gemini + Groq + race =====================
class _Gemini:
    """Gemini REST via a persistent (keep-alive) httpx client."""

    def __init__(self):
        import httpx
        self.key = os.environ.get("GEMINI_API_KEY")
        self.client = httpx.Client(
            timeout=httpx.Timeout(connect=5.0, read=30.0, write=10.0, pool=5.0),
            limits=httpx.Limits(keepalive_expiry=60.0),   # keep the TLS conn warm between dictations
            headers={"x-goog-api-key": self.key or "", "Content-Type": "application/json"})

    def warm(self):
        """Light TLS/keepalive prime only — NO system prompt, 1 token. Cheap against
        quota (the system prompt isn't cached anyway, so priming it just burns quota)."""
        if not self.key:
            return
        body = {"contents": [{"parts": [{"text": "."}]}],
                "generationConfig": {"maxOutputTokens": 1}}
        self.client.post(_GEMINI_URL.format(model=config.GEMINI_MODEL),
                         json=body, timeout=8.0).raise_for_status()

    def generate(self, transcript, max_tokens, timeout, hints=""):
        if not self.key:
            raise RuntimeError("GEMINI_API_KEY not set")
        body = {
            "system_instruction": {"parts": [{"text": config.system_prompt()}]},
            "contents": [{"parts": [{"text": config.user_prompt(transcript, hints)}]}],
            "generationConfig": {"temperature": 0, "maxOutputTokens": max_tokens},
        }
        r = self.client.post(_GEMINI_URL.format(model=config.GEMINI_MODEL),
                             json=body, timeout=timeout)
        r.raise_for_status()
        d = r.json()
        cand = (d.get("candidates") or [{}])[0]
        parts = (cand.get("content") or {}).get("parts") or []
        text = "".join(p.get("text", "") for p in parts).strip()
        if not text:
            raise ValueError(f"empty gemini response ({cand.get('finishReason')})")
        return text


class RateLimited(Exception):
    pass


class _Groq:
    """Groq gpt-oss fallback, with a rolling 60s tokens-per-minute counter per key
    so we never fire a request we know will be rate-limited."""

    def __init__(self):
        from groq import Groq
        keys = [k for k in (os.environ.get("GROQ_API_KEY"),
                            os.environ.get("GROQ_API_KEY_2")) if k]
        self.clients = [Groq(api_key=k) for k in keys]
        self.usage = [collections.deque() for _ in keys]
        self.lock = threading.Lock()

    def _used(self, i):
        cut = time.time() - 60
        dq = self.usage[i]
        while dq and dq[0][0] < cut:
            dq.popleft()
        return sum(t for _, t in dq)

    def estimate(self, transcript, hints=""):
        """Full request cost vs Groq's TPM limit: the whole prompt counts (caching
        is free to BILL but still counts against the rate limit), plus the reserved
        max output."""
        sys_t = len(config.system_prompt()) // 4
        return sys_t + (len(transcript) + len(hints)) // 4 + config.MAX_OUTPUT_TOKENS

    def pick_key(self, est):
        with self.lock:
            for i in range(len(self.clients)):
                if config.GROQ_TPM_LIMIT - self._used(i) >= est:
                    return i
            return None

    def has_budget(self, transcript, hints=""):
        return self.pick_key(self.estimate(transcript, hints)) is not None

    def generate(self, transcript, timeout, hints=""):
        i = self.pick_key(self.estimate(transcript, hints))
        if i is None:
            raise RateLimited()
        kw = dict(model=config.GROQ_MODEL,
                  messages=[{"role": "system", "content": config.system_prompt()},
                            {"role": "user", "content": config.user_prompt(transcript, hints)}],
                  temperature=0, max_completion_tokens=config.MAX_OUTPUT_TOKENS, timeout=timeout)
        if config.GROQ_REASONING:
            kw["reasoning_effort"] = config.GROQ_REASONING
        resp = self.clients[i].chat.completions.create(**kw)
        text = (resp.choices[0].message.content or "").strip()
        u = resp.usage
        cost = (getattr(u, "prompt_tokens", 0) or 0) + (getattr(u, "completion_tokens", 0) or 0)
        with self.lock:
            self.usage[i].append((time.time(), cost))
        if not text:
            raise ValueError("empty groq response")
        return text


class Cleaner:
    def __init__(self, notify=_notify):
        self.notify = notify
        self.gemini = _Gemini()
        self.groq = _Groq()
        self.pool = ThreadPoolExecutor(max_workers=4, thread_name_prefix="clean")
        self._last_warm = 0.0
        # circuit breaker: after repeated Gemini failures, skip it for a while so
        # we go straight to Groq instead of 429-ing + notifying every dictation.
        self._gemini_fails = 0
        self._gemini_skip_until = 0.0

    def warm(self):
        try:
            self.gemini.warm()
        except Exception as e:
            _log(f"warm: {e}")

    def warm_async(self):
        if monotonic() < self._gemini_skip_until:    # Gemini known-down: don't bother
            return
        if monotonic() - self._last_warm < 8:
            return
        self._last_warm = monotonic()
        self.pool.submit(self.warm)

    def _deadline(self, transcript):
        est_out = max(1, len(transcript) // 4)
        return max(config.DEADLINE_FLOOR_SEC,
                   config.DEADLINE_MULT * est_out / config.TOK_PER_SEC)

    def clean_race(self, transcript, hints=""):
        """Return (who, text): who in {'gemini','groq','raw'}.

        Gemini first. If it doesn't answer within `deadline`, run Groq in parallel
        (unless Groq would blow its rate limit -> raw) and take whichever returns
        within a second `deadline`; if both stall, raw."""
        deadline = self._deadline(transcript)
        hard = deadline + 5.0
        # Circuit breaker: skip Gemini entirely while it's known-down (e.g. out of
        # credits) so we go straight to Groq with no per-dictation 429 + notify spam.
        gemini_up = monotonic() >= self._gemini_skip_until
        if gemini_up and self._gemini_skip_until:    # cooldown elapsed -> give Gemini fresh strikes
            self._gemini_skip_until = 0.0
            self._gemini_fails = 0
        gf = None
        if gemini_up:
            gf = self.pool.submit(self.gemini.generate, transcript, config.MAX_OUTPUT_TOKENS, hard, hints)
            try:
                r = gf.result(timeout=deadline)
                self._gemini_fails = 0             # success -> reset
                return ("gemini", r)
            except FuturesTimeout:
                pass                               # genuinely slow — keep it, try Groq too
            except Exception as e:
                _log(f"gemini error: {e}")
                gf = None
                self._gemini_fails += 1
                if self._gemini_fails >= 3:        # 3 strikes -> open the circuit for 2 min
                    self._gemini_skip_until = monotonic() + 120
                    _log("gemini circuit OPEN (skipping 120s)")
                    self.notify("Gemini unavailable (out of credits?) — using Groq.")

        if not self.groq.has_budget(transcript, hints):
            self.notify("No cleanup available (Groq rate-limited) — pasting raw transcript.")
            return ("raw", transcript)
        if gemini_up and gf is not None:           # Gemini was slow (not down) -> say so
            self.notify("First model slow, trying second.")
        qf = self.pool.submit(self.groq.generate, transcript, hard, hints)

        watch = {qf: "groq"}
        if gf is not None:
            watch[gf] = "gemini"
        end = monotonic() + deadline
        while watch:
            remaining = end - monotonic()
            if remaining <= 0:
                break
            done, _ = wait(list(watch), timeout=remaining, return_when=FIRST_COMPLETED)
            if not done:
                break
            for f in done:
                who = watch.pop(f)
                try:
                    return (who, f.result())
                except Exception as e:
                    _log(f"{who} error: {e}")        # this model failed; keep watching the other
        self.notify("Cleanup slow — pasting raw transcript.")
        return ("raw", transcript)


# ===================== daemon =====================
class Daemon:
    def __init__(self):
        self.listening = False
        self.session = None
        self.jobs = queue.Queue()
        self.control = queue.Queue()
        self.started_at = now_iso()
        self.ready_at = None
        self.current_mic = None
        self.worker_busy = False
        self.stage = None                  # 'transcribing' | 'cleaning' while worker_busy
        self.last_error = None
        self.cleaner = None                # built after env load, in run()
        self.done_until = 0.0              # monotonic deadline for the ✅ badge
        self.done_kind = None              # 'clean' | 'raw' | 'error'
        self._rendered = None
        self._np_paused = False            # did WE pause media at dictation start? (resume on stop)
        self._np_volume = None             # output volume before our fade-out, to fade back in
        self._ctrl_busy_since = 0.0
        self._last_state_write = 0.0
        self._threads = {}

    def write_state(self, status=None):
        config.state_write({
            "pid": os.getpid(),
            "status": status or ("ready" if self.ready_at else "loading"),
            "started_at": self.started_at, "ready_at": self.ready_at,
            "listening": self.listening, "queue_depth": self.jobs.qsize(),
            "worker_busy": self.worker_busy, "mic": self.current_mic,
            "last_error": self.last_error, "heartbeat": now_iso(),
        })

    def _mark_done(self, kind):
        self.done_kind = kind
        self.done_until = monotonic() + 1.2

    # ---- media pause/resume around dictation (via nowplaying-cli) ----
    def _music_pause(self):
        """At dictation start: if media is playing, fade the system volume out, then
        pause it — remembering the original volume to fade back in on stop."""
        cli = shutil.which("nowplaying-cli")
        if not cli or not _np_is_playing(cli):
            return
        self._np_volume = _volume_fade_out()   # original output volume (0-100) or None
        _np_toggle(cli)                         # pause (after the fade-out)
        self._np_paused = True

    def _music_resume(self):
        """Resume only the media WE paused: play, then fade the volume back in.
        Idempotent (safe to call twice)."""
        if not self._np_paused:
            return
        self._np_paused = False
        cli = shutil.which("nowplaying-cli")
        if cli:
            _np_toggle(cli)                     # play (before the fade-in)
        _volume_fade_in(self._np_volume)        # fade in to original (no-op if None)
        self._np_volume = None

    # ---- control thread: start/stop the mic; never blocks on cleanup ----
    def _control_loop(self):
        while True:
            action = self.control.get()
            self._ctrl_busy_since = monotonic()
            try:
                if action == "toggle":
                    if self.listening:
                        self._music_resume()
                        self._stop_listening()
                    else:                                  # START: always allowed
                        self._music_pause()
                        if not self._start_listening():
                            self._music_resume()
                elif action == "cancel" and self.listening:
                    self._music_resume()
                    self._cancel_listening()
            except Exception as e:
                self.last_error = f"control: {e}"
                _log(f"control error: {e}")
                self.listening = False; self.session = None
                _set_kb_listening(False); self.write_state()
            finally:
                self._ctrl_busy_since = 0.0

    def _start_listening(self):
        delays = [0.3, 0.6, 1.0, 1.5]
        attempt = 0
        while True:
            try:
                self.session = Session()
                self.session.start()
                self.current_mic = self.session.mic_name
                self.listening = True
                _set_kb_listening(True)
                self.cleaner.warm_async()          # prime Gemini TLS + system prompt
                self.write_state()
                return True
            except Exception as e:
                self.last_error = f"mic: {e}"
                _log(f"mic open failed: {e}")
                if self.session is not None:
                    try:
                        self.session.cancel()
                    except Exception:
                        pass
                self.session = None
                reset_audio()
                max_attempts = len(delays) if is_host_api_error(e) else 1
                if attempt >= max_attempts:
                    break
                sleep(delays[min(attempt, len(delays) - 1)])
                attempt += 1
        self.listening = False
        _set_kb_listening(False)
        _notify("MIC")
        self.write_state()
        return False

    def _stop_listening(self):
        _set_kb_listening(False)
        sess, self.session = self.session, None
        hints = ui.hint_text() if config.HINTS_ENABLED else ""
        self.worker_busy = True       # so the overlay goes listening -> working, no flicker
        self.listening = False
        sess.snapshot()               # fast: closes the mic on a detached thread
        self.jobs.put((sess, hints))
        self.write_state()

    def _cancel_listening(self):
        _set_kb_listening(False)
        sess, self.session = self.session, None
        self.listening = False
        dur = sess.duration
        sess.cancel()
        config.db_insert(dur, "", None, None, "cancelled")
        self.write_state()

    # ---- worker thread: transcribe -> route -> clean-race -> paste ----
    def _worker(self):
        while True:
            sess, hints = self.jobs.get()
            self.worker_busy = True
            self.stage = "transcribing"
            self.write_state()
            try:
                self._process(sess, hints)
            except Exception as e:
                self.last_error = f"worker: {e}"
                _log(f"worker error: {e}")
                self._mark_done("error")
                try:
                    config.db_insert(getattr(sess, "duration", None), "", None, None, "error")
                except Exception:
                    pass
            finally:
                self.worker_busy = False
                self.stage = None
                self.jobs.task_done()
                self.write_state()

    def _deliver(self, text, kind):
        """Paste `text`; show the ✓ badge of `kind` on success, or an error dot +
        a 'grant Accessibility' notice on failure (text stays on the clipboard)."""
        ok = paste(text)
        if not ok:
            _notify("Grant Accessibility to wtalk — text is on the clipboard, press ⌘V")
            self.last_error = "accessibility not granted (paste blocked)"
        self._mark_done(kind if ok else "error")
        return ok

    def _process(self, sess, hints=""):
        cap = sess.transcribe()
        plain, marked, dur = cap["text"], cap["marked"], cap["duration"]
        pauses, conf = cap["pauses"], cap["confidence"]
        words = plain.split()

        if not plain:
            config.db_insert(dur, "", None, None, "empty")
            return
        # passthrough: short + no pauses + confident -> paste raw, no model
        if (len(words) <= config.PASSTHROUGH_MAX_WORDS and not pauses
                and conf >= config.PASSTHROUGH_CONFIDENCE):
            ok = self._deliver(plain, "clean")
            config.db_insert(dur, marked, plain, "passthrough", "passthrough" if ok else "no_paste")
            return

        self.stage = "cleaning"            # real cleanup starts -> green dot lights up
        who, out = self.cleaner.clean_race(marked, hints)
        if who == "raw":
            ok = self._deliver(plain, "raw")
            config.db_insert(dur, marked, plain, "raw", "raw" if ok else "no_paste")
        elif out and out != "NO TRANSCRIPTION":
            ok = self._deliver(out, "clean")
            config.db_insert(dur, marked, out, who, "done" if ok else "no_paste")
        else:                                  # model judged it noise -> paste nothing
            self._mark_done("clean")
            config.db_insert(dur, marked, None, who, "no_transcription")

    # ---- UI sync (main thread, NSTimer) ----
    def _phase(self):
        if self.listening:
            return "listening"
        if self.done_until and monotonic() < self.done_until:
            return {"raw": "done_raw", "error": "error"}.get(self.done_kind, "done")
        if self.worker_busy:
            return "cleaning" if self.stage == "cleaning" else "transcribing"
        return "idle"

    def _tick(self, timer):
        phase = self._phase()
        if phase != self._rendered:
            try:
                ui.render(phase)
                self._rendered = phase
            except Exception as e:
                self.last_error = f"ui: {e}"
            try:
                ui.menu_update(self.listening, self.worker_busy, self.jobs.qsize())
            except Exception:
                pass
        now = monotonic()
        if now - self._last_state_write > 2.0:       # heartbeat for `wtalk status`
            self._last_state_write = now
            self.write_state()

    # ---- lifecycle ----
    def quit(self):
        config.state_clear()
        os._exit(0)

    def _shutdown(self, *_):
        config.state_clear()
        os._exit(0)

    def _acquire_single_instance(self):
        config.STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        self._lock = open(config.STATE_PATH.parent / "wtalk.lock", "w")
        try:
            fcntl.flock(self._lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            print("wtalk already running — exiting", flush=True)
            raise SystemExit(0)

    def _trim_log(self):
        try:
            path = config.STATE_PATH.parent / "daemon.log"
            if path.exists() and path.stat().st_size > _LOG_CAP_BYTES:
                data = path.read_bytes()[-(_LOG_CAP_BYTES // 2):]
                nl = data.find(b"\n")
                if nl != -1:
                    data = data[nl + 1:]
                with open(path, "r+b") as f:
                    f.seek(0); f.truncate(); f.write(data)
        except Exception:
            pass

    def _install_excepthooks(self):
        def thread_hook(args):
            _log(f"THREAD CRASH [{args.thread.name}] {args.exc_type.__name__}: {args.exc_value}")
        threading.excepthook = thread_hook
        sys.excepthook = lambda et, ev, tb: _log(f"UNCAUGHT {et.__name__}: {ev}")

    def _spawn(self, name, target):
        th = threading.Thread(target=target, name=name, daemon=True)
        self._threads[name] = th
        th.start()

    def run(self):
        self._acquire_single_instance()
        self._trim_log()
        self._install_excepthooks()
        _log("wtalk starting")
        _set_kb_listening(False)
        self.write_state(status="loading")
        try:
            load_parakeet()                          # warm ASR (must succeed)
        except Exception as e:
            _log(f"startup failed: {e}")
            self.last_error = f"startup: {e}"
            self.write_state(status="loading")
            raise SystemExit(1)                      # launchd respawns until it works
        self.cleaner = Cleaner(notify=_notify)
        try:
            self.cleaner.warm()                      # best-effort (network may be down)
        except Exception:
            pass
        try:
            self.current_mic = _resolve_device()[1]  # show the mic in `wtalk status`
        except Exception:
            pass
        if not prompt_accessibility():       # pops the standard 'grant Accessibility' dialog
            _log("WARNING: Accessibility NOT granted to wtalk — auto-paste blocked "
                 "(text still lands on the clipboard). A grant dialog was shown.")
        self.ready_at = now_iso()

        self._spawn("control", self._control_loop)
        self._spawn("worker", self._worker)
        signal.signal(signal.SIGTERM, self._shutdown)
        signal.signal(signal.SIGINT, self._shutdown)
        signal.signal(signal.SIGUSR1, lambda *_: self.control.put("toggle"))
        signal.signal(signal.SIGUSR2, lambda *_: self.control.put("cancel"))

        ui.set_submit_handler(lambda: self.control.put("toggle"))  # Enter in pill = stop+send
        app = ui.ensure_app()
        try:
            ui.build_menu(self)
        except Exception as e:
            self.last_error = f"menubar: {e}"
            _log(f"menubar error: {e}")
        from Foundation import NSTimer
        # 0.02s tick also services pending SIGUSR1/2 on the main thread (~<=20ms).
        NSTimer.scheduledTimerWithTimeInterval_repeats_block_(0.02, True, self._tick)
        self.write_state(status="ready")
        _log("wtalk ready")
        app.run()


if __name__ == "__main__":
    if "--prime-perms" in sys.argv:
        # Fire both TCC prompts up front (used by `wtalk install`), then exit —
        # does NOT load Parakeet.
        prompt_accessibility()      # Accessibility dialog (paste at cursor)
        prime_mic_permission()      # Microphone dialog (record)
        sys.exit(0)
    Daemon().run()
