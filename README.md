# minh-mac-utils

My macOS self-discipline + workflow tools. Each is a self-contained folder with its own README
(architecture, file layout, permissions, OS interactions). This page is the **index** and the
**fresh-machine setup order** — clone the folder, install in order, and you're up.

Built for a Mac **you control** (the discipline model: you remove your own admin day-to-day and
regain it only via `sudome`'s held password). Nothing secret is committed — installers scaffold
the credential files on the target machine and you fill them in.

## The tools

| Tool | What it does | Install | Root? |
|---|---|---|---|
| **sudome** | password-gated admin (sudo) grant/revoke — the keystone the lockers lean on | `sudo ./install.sh` | yes |
| **demonlock** | conditional locker: location / time / Wi‑Fi-BSSID policy → 10s countdown → logout | `sudo ./install.sh` | yes |
| **nextdns-lockdown** | force all DNS through the local NextDNS resolver, fail-closed, pf-enforced | `sudo ./install.sh` | yes |
| **nextdns-discipline** | block/allow domains on a NextDNS profile (`block`=no-sudo, `allow`=sudo) | `sudo ./install.sh` | yes |
| **settingslock** | kill System Settings the instant the FileVault recovery-key pane opens | `./install.sh` (self-sudos) | yes |
| **betterat** | no-sudo `at(1)`: schedule shell commands, persist + catch up on reboot | `./betterat install` | no |
| **wtalk** | push-to-talk dictation daemon (Parakeet transcribe + Gemini cleanup) | `./setup.sh` | no |
| **fade-play-pause-chrome** | daemon that fades out + pauses browser music tabs and fades them back; `fadepause`/`faderesume` triggers | `./install.sh` | no |

(They don't share one rigid interface — most lockers happen to have `install`/`uninstall`/`arm`/
`disarm`, but betterat, wtalk, and fade-play-pause-chrome don't fit that mold, and that's fine.)

**wtalk media auto-pause (optional):** if `nowplaying-cli` is on your `PATH`
(`brew install nowplaying-cli`), wtalk pauses whatever's playing when you start a dictation and
resumes it after (decoupled — it only toggles media it actually paused; no-op if nowplaying-cli
isn't installed). fade-play-pause-chrome is a separate standalone tool — wtalk no longer drives it.

## Fresh-machine setup (in order)

### 1. Base prerequisites (you have admin)
- **Xcode Command Line Tools:** `xcode-select --install` — needed to compile sudome + nextdns-discipline (C) and build demonlock + settingslock (Swift). *(demonlock can skip this: it ships a prebuilt signed `dist/`.)*
- **Homebrew**, then `brew install ffmpeg` — for wtalk.
- **uv:** `curl -LsSf https://astral.sh/uv/install.sh | sh` — for wtalk.
- **Karabiner-Elements** — to bind wtalk's push-to-talk key.
- **NextDNS resolver** (for nextdns-lockdown): `brew install nextdns/tap/nextdns && sudo nextdns install && sudo nextdns activate`; confirm `dig @127.0.0.1 apple.com` resolves. *(nextdns-lockdown refuses to arm without it.)*
- *(Optional)* **Pluckeye** — the lockers' real teeth is its admin delay; without it the only gate is sudome.

### 2. Install in dependency order
`git clone git@github.com:MT-GoCode/minh-mac-utils.git && cd minh-mac-utils`, then:

1. **sudome FIRST** — `cd sudome && sudo ./install.sh` → `sudo nano /usr/local/etc/sudome/Allpassword` (set the password) → test `sudome remove` then `sudome add` round-trips. **Do not drop your admin yet.**
2. **nextdns-discipline** — `cd ../nextdns-discipline && sudo ./install.sh`, enter your NextDNS Profile ID + API key.
3. **nextdns-lockdown** — only after the `nextdns` daemon is up. `cd ../nextdns-lockdown && sudo ./install.sh` → `sudo nextdns-lockdown arm` → `nextdns-lockdown selftest`.
4. **demonlock** — `cd ../demonlock && sudo ./install.sh` → `demonlock perm-ask` (grant **Location → Always**) → `demonlock scan` / `zones` / `sudo demonlock setpolicy '…'` → `sudo demonlock arm`.
5. **settingslock** — `cd ../settingslock && ./install.sh` (run as **you**) → grant **Accessibility** to `/usr/local/bin/settingslock` → `sudo settingslock arm`.
6. **wtalk** — `cd ../wtalk && ./setup.sh` → put your Gemini key in `.env` → bind a key in Karabiner to `~/.local/bin/wtalk toggle` → grant **Microphone + Accessibility**. **Keep this folder — wtalk runs from it.**
7. **betterat** — `cd ../betterat && ./betterat install` (no sudo).

### 3. Only then harden
Verify each tool's `status` / `selftest`. *Then* `sudome remove` to drop daily admin (re-login to
fully apply). Keep the sudome password — and a second admin recovery path — until you've confirmed
`sudome add` works after a logout.

## Credentials (never in this repo)
Installers scaffold these on the target Mac; you fill them in:
| File | Created by | You |
|---|---|---|
| `/usr/local/etc/sudome/Allpassword` | sudome install | `sudo nano` it |
| `/usr/local/etc/nextdns-discipline/credentials` | nextdns-discipline install | enter key+profile at the prompt |
| `wtalk/.env` | wtalk `setup.sh` (template) | paste Gemini/Groq/HF keys (gitignored) |

## TCC permissions — human-click only
**Location** → demonlock · **Accessibility** → settingslock + wtalk · **Microphone** → wtalk. macOS
won't let a script grant these; you click them once per machine.

## Code signing (demonlock, settingslock, wtalk)
Only the three tools that build macOS `.app`s sign anything (the C tools auto-ad-hoc-sign via the
compiler; the bash tools don't sign). All three call the **same** picker, `sign-identity.sh`, which
chooses best-first and prints the choice at install:

1. **Developer ID Application** — if one's in your login keychain. Apple-rooted; the TCC grant
   persists across rebuilds and survives cert expiry (secure timestamp). *Get one (optional):* a
   paid Apple Developer account, then Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ ＋ ▸
   Developer ID Application.
2. **Stable self-signed** (`Mac Utils Local Signing`) — created automatically when you have no
   Developer ID. Grant still persists across rebuilds; no Apple account.
3. **Ad-hoc** — last resort; works, but the grant resets each rebuild.

Override with `CODESIGN_IDENTITY="…"`.

## Preserving Developer-ID builds (GitHub releases)
The Developer ID gives the cleanest (Apple-rooted) trust, but lapses if you drop the Apple Developer
account. The signed bundles carry a **secure timestamp**, so a build made *now* stays valid forever.
While you still have the cert, publish the dev-signed bundles as a release (needs `gh` —
`brew install gh && gh auth login`):

```bash
# with your Developer ID cert present, after the repo is pushed:
( cd demonlock    && sudo ./install.sh )    # produces demonlock/dist/Demonlock.app  (Dev-ID-signed)
( cd settingslock && ./install.sh )         # produces settingslock/dist/settingslock (Dev-ID-signed)
ditto -c -k --keepParent demonlock/dist/Demonlock.app /tmp/Demonlock.app.zip
gh release create devsigned-$(date +%Y%m) /tmp/Demonlock.app.zip settingslock/dist/settingslock \
    --title "Developer-ID-signed bundles" \
    --notes "Prebuilt, Developer-ID-signed + timestamped — install to keep Apple-rooted trust after the cert lapses."
```

**Using them later** on a Mac with no Developer ID — it's just "copy back + install" (no Xcode, no
Apple account; the installers auto-deploy `dist/` instead of rebuilding when you have no cert):
```bash
gh release download devsigned-YYYYMM --dir /tmp/dl
ditto -x -k /tmp/dl/Demonlock.app.zip demonlock/dist/      # → demonlock/dist/Demonlock.app
cp /tmp/dl/settingslock settingslock/dist/settingslock
( cd demonlock    && sudo ./install.sh )                   # deploys the dev-signed dist/, no rebuild
( cd settingslock && ./install.sh )
```
(wtalk isn't released this way — its `.app` is a per-machine Python copy, so it just self-signs on
the new Mac, which is fine.)

## JAMF / MDM caveats (org policy — can't be fixed in code)
- A managed **content/network filter or pinned DNS** will fight nextdns-lockdown's `pf` + resolver lock.
- **PPPC** profiles can deny or lock the TCC grants above → the lockers fail-closed, wtalk can't record.
- An MDM-managed **admin group** can revert sudome's add/remove.
- Restrictions on third-party **LaunchDaemons**, or a notarization-required **Gatekeeper** policy, can block the daemons/apps.

These need the org to allowlist the tools (and stable signing identities) — not something the installers can force.
