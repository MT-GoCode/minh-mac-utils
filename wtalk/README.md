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
- **`nowplaying-cli`** (optional) — `brew install nowplaying-cli`. If present, wtalk fades the
  system volume out and pauses any actively-playing media when you start a dictation, then resumes
  it with a fade-in when you stop (so music doesn't bleed into the mic). No-op if it isn't installed.
- Python 3.10 + [`uv`](https://docs.astral.sh/uv/).

---

## Clean install

wtalk is frozen with **PyInstaller** into a **sealed, code-signed, root-owned**
`/Applications/wtalk.app` — the same model as the sibling tool `demonlock`.
"Sealed + root-owned" matters: the launched binary is the **PyInstaller
bootloader**, not a `python` CLI — it takes no `-c`/`-m`/argv-script and runs only the
embedded bytecode, and PyInstaller ≥6 blocks a host `PYTHONPATH`/`PYTHONHOME` from
overriding the bundled modules. Combined with the `root:wheel` install (you can't replace
the embedded code without `sudo`, and any edit breaks the code signature) it can only ever
run the code baked inside it. That immutability is what lets **demonlock safely whitelist
wtalk** from its lockout with no hole.

(Why PyInstaller and not Nuitka? Nuitka stalled compiling pyobjc's giant `*_metadata.c`
files — ~10 minutes *each*, turning the build into a multi-hour ordeal. PyInstaller freezes
the same bundle in minutes.)

Two steps — prep, then install:

```bash
cd ~/code/wtalk
./setup.sh          # prereqs: Apple Silicon + uv + ffmpeg check, .venv (3.10) + deps
sudo ./install.sh   # PyInstaller-freeze + sign, deploy root-owned, seed ~/.wtalk, load launchd
```

`setup.sh` only prepares the **build prerequisites** (the `.venv` and wheels). It no
longer builds the app or touches `~/.local/bin` — install is a root operation now.

`sudo ./install.sh` (build runs as *you* for the keychain; deploy runs as root):

1. **Freezes + signs** `wtalk.app` with PyInstaller (a few minutes).
2. **Deploys it root-owned** to `/Applications/wtalk.app` (`chown root:wheel`, `chmod -R go-w`).
3. Installs the CLI wrapper `/usr/local/bin/wtalk` → the bundle's binary.
4. **Seeds `~/.wtalk`** (user-owned DATA) with `.env`, `config.txt`, and `prompts/` — only
   if absent, so it never clobbers your edits/keys.
5. Installs the **LaunchAgent** (`com.wtalk.agent`, root-owned plist in
   `/Library/LaunchAgents`) and bootstraps it into your `gui/<uid>` session (run at login,
   kept alive).

> **Reinstall without re-signing:** `sudo ./install.sh --prebuilt` deploys the
> already-signed `dist/wtalk.app` **without rebuilding** — use it to reinstall (re-deploy
> root-owned, reseed, reload the agent) without re-entering the Developer-ID signing PIN.
> Plain `sudo ./install.sh` builds a fresh bundle and prompts the signing PIN once.

> **Why `~/.wtalk` for your data?** Code is sealed and root-owned; **data is yours**. Your
> keys (`.env`), settings (`config.txt`), prompts, logs, state, and history all live in
> `~/.wtalk`. Editing them changes only what the binary *reads* — it can never redirect
> which code the sealed binary *runs* (nothing there is on an import path). The frozen
> bundle does **not** depend on the repo dir at runtime.

> **Source-only copy:** everything is git-tracked source — `.venv/`, the PyInstaller build
> outputs (`wtalk.app/`, `dist/`, `build/`), and secrets are gitignored and
> regenerated locally. Copy the repo, run the two commands above, done.

**The two manual bits the installer can't do for you:**

```bash
# 1. Add your Gemini key (required) — https://aistudio.google.com/apikey
#    and optionally Groq keys (fallback) — https://console.groq.com/keys
$EDITOR ~/.wtalk/.env          # then:  wtalk restart

# 2. Bind F5 in Karabiner-Elements (see below)
```

### 6. Karabiner key binding

Karabiner owns the keys; wtalk just reacts to signals. Add a complex modification
(Karabiner-Elements → Complex Modifications → Add your own) that runs, on **F5**:

```
/usr/local/bin/wtalk toggle
```

Optionally bind another key to `wtalk cancel`. If F5 already does something on your
Mac, turn off its default in **Settings → Keyboard → Keyboard Shortcuts**.

**Verbatim.** While dictating, click the **“Verbatim”** pill next to the red dot to
stop and paste the **raw** transcript with no AI cleanup. It runs the **exact same**
pipeline as a normal stop (transcribe, empty/passthrough checks) and only diverges
right before the cleanup model — no HTTP request is made; the raw transcript is pasted
as-is. If you'd rather drive it from the keyboard, `wtalk verbatim` is bindable to a
key of your choice in Karabiner (pick a non-letter key — a plain letter would get
swallowed while dictating).

---

## Permissions (one-time)

The installer freezes a real **`wtalk.app`** bundle (code-signed, bundle id
`com.wtalk.daemon`) and runs it under launchd. So macOS treats it like any normal
app: permissions show up as **“wtalk”** (not a hidden Python path), and it **prompts**
you. Grant these in **System Settings → Privacy & Security**:

| Permission | Why | How it's requested |
|---|---|---|
| **Microphone** | record your voice | `sudo ./install.sh` tries to prompt up front, but macOS **often defers it to your first dictation** (first real mic use) — approve it then |
| **Accessibility** | synthesize ⌘V to paste | the installer pops the dialog → **Open System Settings** → toggle **wtalk** on |
| ~~Input Monitoring~~ | not needed | Karabiner owns the keys |

The daemon logs `WARNING: Accessibility NOT granted` at startup until you approve it,
so check `~/.wtalk/daemon.log` if auto-paste ever stops working. (Until granted, your
cleaned text still lands on the clipboard — just press ⌘V.)

## Code signing

Apple Silicon requires a signature to run at all. `install/build.sh` auto-picks the best
identity (shared `../sign-identity.sh`) and deep-signs the whole bundle with it:

1. **Developer ID Application** (team `BULCQM9J2V`) — if one is in your login keychain. Best:
   Apple-rooted, the TCC grant persists across rebuilds, survives cert expiry (secure timestamp).
   Required if you want to **notarize** (optional). *Get one:* a paid Apple Developer account,
   then Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ ＋ ▸ Developer ID Application.
2. **Stable self-signed** (`Mac Utils Local Signing`) — created automatically (openssl → login
   keychain) when you have no Developer ID. TCC grant still persists across rebuilds; no Apple
   account needed.
3. **Ad-hoc** — last resort. Works, but the TCC grant resets on every rebuild.

Override with `CODESIGN_IDENTITY="…"`.

**Hardened runtime stays ON.** PyInstaller **deep-signs every bundled `.dylib`/`.so`
(mlx, numpy, sounddevice, pyobjc) under one Developer-ID identity**, so the hardened runtime's
*library validation* is satisfied — all Mach-Os share our Team ID. (The old "copy the system
interpreter into a `.app`" trick had to *disable* the hardened runtime because it carried unsigned
conda/venv extensions; that whole class of problem is gone.) Do **not** disable library validation.

The bundle is rebuilt + re-signed on each `sudo ./install.sh`. To carry a Developer ID to another
Mac, export it from Keychain Access as a `.p12` and import it there. If you change the signature,
an old TCC grant can go stale — remove the `wtalk` entry in Privacy & Security and re-add it.

**Notarization (optional).** With a Developer ID identity, `xcrun notarytool submit` the signed
bundle, then `xcrun stapler staple` it. Only
worth it to move the app between Macs without Gatekeeper prompts; for a local install it's unneeded.

---

## Uninstall / reinstall

**Uninstall** (keeps `~/.wtalk` — your keys, config, history):
```bash
cd ~/code/wtalk
sudo ./uninstall.sh            # boots out the agent, removes the app + plist + CLI wrapper
# add --purge to also delete ~/.wtalk:
sudo ./uninstall.sh --purge
# optional — revoke the TCC grants:
tccutil reset Microphone com.wtalk.daemon
tccutil reset Accessibility com.wtalk.daemon
# (the Karabiner F5 rule is yours — remove it in Karabiner if you want)
```

**Reinstall** (rebuilds the bundle, re-signs, redeploys, reloads):
```bash
cd ~/code/wtalk
./setup.sh                    # only if .venv is gone (recreates venv + deps)
sudo ./install.sh             # PyInstaller-freeze, sign, deploy root-owned, reload the agent
# or, to skip the rebuild + signing PIN and redeploy the already-signed bundle:
sudo ./install.sh --prebuilt  # deploy dist/wtalk.app as-is, re-sign nothing
```

---

## Use

```bash
sudo ./install.sh   # freeze + sign + deploy root-owned, seed ~/.wtalk, load the agent
sudo ./uninstall.sh # stop + remove the app, plist, and CLI wrapper (--purge also wipes ~/.wtalk)

wtalk               # status: ready / loading / not running
wtalk status        # same as bare `wtalk`
wtalk restart       # bounce the daemon (after editing ~/.wtalk/config.txt or ~/.wtalk/.env)
wtalk toggle        # what F5 does (start, or stop+clean+paste)
wtalk cancel        # what Esc/cancel does
wtalk verbatim      # stop + paste the RAW transcript (no cleanup)
wtalk history       # last 20 dictations
wtalk help
```

Install/uninstall are **root operations** (the bundle is deployed root-owned), so they're
shell scripts, not `wtalk` subcommands. Everything else is dispatched by the frozen binary
itself. One mechanism: a launchd LaunchAgent (`com.wtalk.agent`, runs at login, kept alive) —
`wtalk restart` and the installers all act on that same agent, so "is it running?" is never
ambiguous.

Then anywhere: **F5** = start/stop dictation. While listening, a small **hints** pill
sits under the dot — click it to type spelling/term hints (variable names, jargon)
the cleanup should apply; ⌘C/⌘V/⌘X/⌘A work inside it. Press **Enter** in the pill to
stop + send. The menu-bar **🎙** has Start/Stop, Cancel, live status, config editors,
and Quit.

---

## Config — `~/.wtalk/config.txt`

Your settings live in `~/.wtalk/config.txt` (seeded from the bundled default on first
install; the sealed bundle is never edited). Edit, then `wtalk restart`. Highlights:

- **Cleanup:** `gemini_model`, `groq_model`, `max_output_tokens`, and the escalation
  deadline (`deadline_floor_sec`, `deadline_multiplier`, `tok_per_sec`).
- **Passthrough:** `passthrough_max_words` / `passthrough_confidence` — short, confident
  clips skip the models and paste raw.
- **Mic:** `mic = builtin` (default — never flips a Bluetooth headset into muffled
  hands-free mode), `default` (follow system input), or a device-name substring.
- **Hints pill:** `hints_enabled`, `hints_max_chars`.
- **Prompts:** standing corrections in `~/.wtalk/prompts/user.txt`; cleanup spec in
  `~/.wtalk/prompts/cleanup_system.txt` (both seeded from the bundle, editable in place).

---

## Troubleshooting

- **Records but won't paste** → grant **Accessibility** to `wtalk` (and after a
  re-sign, toggle it off/on to refresh the grant).
- **Mic error / nothing records** → grant **Microphone** to `wtalk`; `wtalk status`
  shows the mic and last error.
- **F5 does nothing** → check the Karabiner rule runs `wtalk toggle`; disable any Mac
  default on F5.
- **Pastes into the wrong place** → focus the target field before F5.
- **Logs:** `~/.wtalk/daemon.log`. **Status:** `wtalk status`. **History:** `wtalk history`.
```
