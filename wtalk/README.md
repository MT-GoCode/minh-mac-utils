# wtalk

Local push-to-talk dictation for macOS (Apple Silicon). Press **F5**, speak, press
**F5** again — a cleaned-up version of what you said is pasted at your cursor.
On-device **Parakeet** (MLX) transcribes; **Gemini 3.1 Flash Lite** cleans it up
(filler/restart removal, your voice preserved), with a Groq fallback and a raw
fallback so a dictation is **never** lost and the app **never** hangs.

```
F5 ─▶ mic (built-in) ──F5 again──▶ Parakeet ASR ─▶ route:
        ≤10 words & confident ─────────────────▶ paste raw  ✅
        else ─▶ clean-race:
                 Gemini ──fast──▶ paste cleaned ✅
                   └─slow─▶ Groq (parallel) ──▶ paste cleaned ✅
                              └─slow / rate-limited─▶ paste raw ✅
```

The red dot tells the truth: 🔴 listening · ◌ spinner = transcribing/cleaning ·
✅ green check = cleaned & pasted · ✅ amber check = raw pasted (model was slow).

---

## Requirements

- **Apple Silicon Mac** (Parakeet runs on MLX/Metal).
- **Homebrew** + `ffmpeg` (Parakeet decodes audio through it).
- **[Karabiner-Elements](https://karabiner-elements.pqrs.org/)** — binds F5 to wtalk
  (wtalk never captures keys itself).
- **Gemini API key** (required) — [aistudio.google.com](https://aistudio.google.com/apikey).
- **Groq API key(s)** (optional fallback) — [console.groq.com](https://console.groq.com/keys).
- Python 3.10 + [`uv`](https://docs.astral.sh/uv/).

---

## Clean install

Copy the source to `~/code/wtalk` (a directory copy, or `git clone`), then run the
setup script — it does everything except the two manual steps (your API key and the
Karabiner binding):

```bash
cd ~/code/wtalk
./setup.sh
```

`setup.sh` checks for Apple Silicon + `uv` + `ffmpeg` (installs ffmpeg via brew),
creates the `.venv` (pinned to Python 3.10 so the wheels resolve), installs
`requirements.txt`, writes a `.env` template, symlinks `wtalk` into `~/.local/bin`
and adds that to your `PATH` (via `~/.zshrc`) if needed, and —
once your Gemini key is in `.env` — runs `wtalk install` (builds + signs `wtalk.app`,
loads the launchd agent). It's idempotent; re-run it any time.

**The two manual bits it can't do for you:**

```bash
# 1. Add your Gemini key (required) — https://aistudio.google.com/apikey
#    and optionally Groq keys (fallback) — https://console.groq.com/keys
$EDITOR .env          # then re-run ./setup.sh  (or: wtalk install)

# 2. Bind F5 in Karabiner-Elements (see below)
```

> **Source-only copy:** everything needed is git-tracked source — `.venv/`,
> `wtalk.app/`, and `.env` are gitignored and rebuilt locally by `setup.sh`. Copy the
> repo, run `setup.sh`, done.

### 6. Karabiner key binding

Karabiner owns the keys; wtalk just reacts to signals. Add a complex modification
(Karabiner-Elements → Complex Modifications → Add your own) that runs, on **F5**:

```
/Users/<you>/.local/bin/wtalk toggle
```

Optionally bind another key to `wtalk cancel`. If F5 already does something on your
Mac, turn off its default in **Settings → Keyboard → Keyboard Shortcuts**.

---

## Permissions (one-time)

`wtalk install` builds a real **`wtalk.app`** bundle (code-signed, identity
`com.wtalk.daemon`) and runs it under launchd. So macOS treats it like any normal
app: permissions show up as **“wtalk”** (not a hidden Python path), and it **prompts**
you. Grant these in **System Settings → Privacy & Security**:

| Permission | Why | How it's requested |
|---|---|---|
| **Microphone** | record your voice | auto-prompts on first dictation → Allow |
| **Accessibility** | synthesize ⌘V to paste | a dialog pops on launch → **Open System Settings** → toggle **wtalk** on |
| ~~Input Monitoring~~ | not needed | Karabiner owns the keys |

The daemon logs `WARNING: Accessibility NOT granted` at startup until you approve it,
so check `~/.wtalk/daemon.log` if auto-paste ever stops working. (Until granted, your
cleaned text still lands on the clipboard — just press ⌘V.)

## Code signing

Apple Silicon requires a signature to run at all. The installer auto-picks the best identity
(shared `../sign-identity.sh`) and prints which it used:

1. **Developer ID Application** — if one is in your login keychain. Best: Apple-rooted, the TCC
   grant persists across rebuilds, survives cert expiry (secure timestamp). *Get one (optional):*
   a paid Apple Developer account, then Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ ＋ ▸
   Developer ID Application.
2. **Stable self-signed** (`Mac Utils Local Signing`) — created automatically (openssl → login
   keychain) when you have no Developer ID. TCC grant still persists across rebuilds; no Apple
   account needed.
3. **Ad-hoc** — last resort. Works, but the TCC grant resets on every rebuild.

Override with `CODESIGN_IDENTITY="…"`.

wtalk-specific: the `.app`'s executable is a per-machine copy of your Python interpreter (gitignored),
so it's re-signed on each `wtalk install`. To carry a Developer ID to another Mac, export it from
Keychain Access as a `.p12` and import it there. If you change the signature, an old Accessibility
grant can go stale — remove the `wtalk` entry and re-add it.

---

## Uninstall / reinstall

**Uninstall completely:**
```bash
wtalk uninstall                                  # stop + remove the launchd agent
pkill -f daemon.py
tccutil reset Microphone com.wtalk.daemon        # revoke permissions (optional)
tccutil reset Accessibility com.wtalk.daemon
rm -rf ~/code/wtalk/wtalk.app                     # the built app
rm -rf ~/.wtalk                                   # state, logs, AND history.db (omit to keep history)
rm -f ~/.local/bin/wtalk                          # the PATH symlink
# (the Karabiner F5 rule is yours — remove it in Karabiner if you want)
```

**Reinstall completely:**
```bash
cd ~/code/wtalk
uv venv && uv pip install -r requirements.txt     # only if .venv is gone
ln -sf ~/code/wtalk/wtalk ~/.local/bin/wtalk
wtalk install                                     # rebuilds wtalk.app, signs, starts
# then approve Microphone (prompts on first dictation) + Accessibility (dialog on launch)
```

---

## Use

```bash
wtalk             # status (ready / loading / not running)
wtalk start       # run the daemon now (foreground-spawned; `install` is the at-login version)
wtalk stop        # stop it
wtalk install     # run at login + keep alive (launchd)
wtalk uninstall   # stop running at login
wtalk status      # detailed: mic, queue, last error
wtalk toggle      # what F5 does (start, or stop+clean+paste)
wtalk cancel      # what Esc/cancel does
wtalk cli         # TEST MODE: record -> print cleaned result (no paste/hotkeys)
wtalk history     # last 20 dictations
wtalk help
```

Then anywhere: **F5** = start/stop dictation. While listening, a small **hints** pill
sits under the dot — click it to type spelling/term hints (variable names, jargon)
the cleanup should apply; ⌘C/⌘V/⌘X/⌘A work inside it. Press **Enter** in the pill to
stop + send. The menu-bar **🎙** has Start/Stop, Cancel, live status, config editors,
and Quit.

---

## Config — `config.txt`

Edit, then `wtalk stop && wtalk start` (or restart the agent). Highlights:

- **Cleanup:** `gemini_model`, `groq_model`, `max_output_tokens`, and the escalation
  deadline (`deadline_floor_sec`, `deadline_multiplier`, `tok_per_sec`).
- **Passthrough:** `passthrough_max_words` / `passthrough_confidence` — short, confident
  clips skip the models and paste raw.
- **Mic:** `mic = builtin` (default — never flips a Bluetooth headset into muffled
  hands-free mode), `default` (follow system input), or a device-name substring.
- **Hints pill:** `hints_enabled`, `hints_max_chars`.
- **Prompts:** standing corrections in `prompts/user.txt`; cleanup spec in
  `prompts/cleanup_system.txt`.

---

## Troubleshooting

- **Records but won't paste** → grant **Accessibility** to `wtalkd` (and after a
  re-sign, toggle it off/on to refresh the grant).
- **Mic error / nothing records** → grant **Microphone** to `wtalkd`; `wtalk status`
  shows the mic and last error.
- **F5 does nothing** → check the Karabiner rule runs `wtalk toggle`; disable any Mac
  default on F5.
- **Pastes into the wrong place** → focus the target field before F5.
- **Logs:** `~/.wtalk/daemon.log`. **Status:** `wtalk status`. **History:** `wtalk history`.
```
