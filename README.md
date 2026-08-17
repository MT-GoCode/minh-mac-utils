# minh-mac-utils

My macOS self-discipline + workflow tools. Each is a self-contained folder with its own README
(architecture, file layout, permissions, OS interactions). This page is the **index** and the
**fresh-machine setup order** — clone the repo, install each app, and you're up.

Built for a Mac **you control** (the discipline model: you remove your own admin day-to-day and
regain it only via demonlock's **delay-gated admin release valve** — no password is held anywhere;
the wait *is* the gate). Nothing secret is committed — installers scaffold the credential files on
the target machine and you fill them in.

## Reinstall / uninstall (quick reference)

Run from a **normal Terminal, not a root shell** (the installers refuse `SUDO_USER=root`). Run `sudo -v`
first so you enter your password once. Full step-by-step setup (permissions + secrets) is in
[Fresh-machine setup](#fresh-machine-setup-in-order) below.

**Uninstall everything:**
```bash
cd ~/code/minh-mac-utils
sudo -v
sudo nextdns-sidecar networklockdown disarm
sudo demonlock disarm
rac teardown
sudo ./nextdns-sidecar/uninstall.sh
sudo ./wtalk/uninstall.sh
sudo ./multistreamviewer/uninstall.sh
sudo ./stayup/uninstall.sh
sudo ./blockrem/uninstall.sh
sudo ./forcecalls/uninstall.sh
sudo ./remote-agent-connector/uninstall.sh
./scripts/unset-paseo-daemon.sh
rm -f ~/.local/bin/chrome-browser-fleet
sudo ./demonlock/uninstall.sh
```

**Reinstall everything:**
```bash
cd ~/code/minh-mac-utils && git pull
sudo -v
sudo ./demonlock/install.sh
sudo ./multistreamviewer/install.sh
sudo ./stayup/install.sh
sudo ./blockrem/install.sh
sudo ./forcecalls/install.sh
sudo ./remote-agent-connector/install.sh
./wtalk/setup.sh
sudo ./wtalk/install.sh
sudo ./nextdns-sidecar/install.sh --profile-src ~/Downloads/NextDNS-*.mobileconfig
./agentic-browser-setup/install.sh
./scripts/setup-paseo-daemon.sh
sudo ./demonlock/register-recommended-spares.sh
```

## The tools

| Tool | What it does | Install | Root? |
|---|---|---|---|
| **demonlock** | conditional locker: location / time / Wi‑Fi-BSSID policy → 10s countdown → force-close GUI apps. Also folds in **settings-guard** (slams the FileVault / Device-Management panes shut) and the internal **admin (sudo) grant/revoke** — the release valve replaces the old `sudome`. | `sudo ./demonlock/install.sh` | yes |
| **nextdns-sidecar** | NextDNS list manager **+** DNS-bypass `pf` lockdown in one root daemon (`domains block`=no-sudo, `add`=sudo, `delay-add`=no-sudo/lands in 12h; `networklockdown arm/disarm`). Merges the old `nextdns-discipline` + `nextdns-lockdown`. | `sudo ./nextdns-sidecar/install.sh` | yes |
| **remote-agent-connector** | reverse-SSH connector + `rac` CLI so a remote agent can act **as you**: a real terminal, plus GUI/keychain via `rac exec`. Nothing listens inbound. | `sudo ./remote-agent-connector/install.sh` | yes |
| **wtalk** | push-to-talk dictation daemon (Parakeet transcribe + Gemini cleanup); PyInstaller-frozen, sealed, root-owned | `sudo ./wtalk/install.sh` | yes |
| **multistreamviewer** | desktop groups that scope ⌘⇥ + a hold-⌘⌥ overview; never moves windows; `multistreamviewer` CLI | `sudo ./multistreamviewer/install.sh` | yes |
| **stayup** | menu-bar toggle for staying awake with the lid closed (`pmset disablesleep`); `stayup` CLI | `sudo ./stayup/install.sh` | yes |
| **blockrem** | scheduled **un-quittable screen blocks** for forced breaks — a root daemon revives a grey full-screen cover + input freeze at each alarm; **fail-open** (a bug always lifts it); managing alarms is no-sudo | `sudo ./blockrem/install.sh` | yes |
| **forcecalls** | scheduled phone calls you must **wait out** to cancel — a root daemon dials the other person via SignalWire, then bridges to a local baresip endpoint that auto-answers; `add` is instant, `remove` is delay-gated (12h), managing calls is no-sudo | `sudo ./forcecalls/install.sh` | yes |
| **agentic-browser-setup** | installs `chrome-browser-fleet`: spins up isolated Chrome windows on their own CDP ports for agent browser automation | `./agentic-browser-setup/install.sh` | no |

**Paseo daemon (`scripts/`).** `scripts/setup-paseo-daemon.sh` hands the third-party Paseo daemon to
launchd (so it survives the desktop app dying — e.g. when demonlock closes the GUI on a lockout) and
adds a nightly refresh that restarts it only after an app auto-update and only when no agent is running.
`scripts/unset-paseo-daemon.sh` reverses it. Both are no-sudo, run as you, and need `jq`. This is
config-wiring for an external app, not a repo-built tool, so it's a manual script rather than an installer.

**Installers are commonized.** There is **no top-level `--all` driver** — install an app with
`sudo ./<app>/install.sh` (or `./<app>/install.sh` for the no-sudo ones). Most GUI/CLI apps' own
`install.sh` just declares a small inline manifest and sources the shared `scripts/install-lib.sh`
(build → deploy root-owned → CLI shim → launchd → register the demonlock spare); the more involved
apps (demonlock, wtalk, nextdns-sidecar, remote-agent-connector) keep a bespoke `install.sh`.
They don't share one rigid runtime interface — most lockers have `arm`/`disarm`, but wtalk and
agentic-browser-setup don't fit that mold, and that's fine.

**wtalk media auto-pause (optional):** if `nowplaying-cli` is on your `PATH`
(`brew install nowplaying-cli`), wtalk fades the system volume out + pauses whatever's playing when
you start a dictation and fades it back in on stop (decoupled — it only toggles media it actually
paused; no-op if nowplaying-cli isn't installed).

## Fresh-machine setup (in order)

### 1. Base prerequisites (you have admin)
- **Xcode Command Line Tools:** `xcode-select --install` — needed to build the Swift apps (demonlock, nextdns-sidecar, remote-agent-connector, multistreamviewer, stayup). *(demonlock can skip this: it ships a prebuilt signed `dist/`.)*
- **Homebrew**, then `brew install ffmpeg` — for wtalk.
- **uv:** `curl -LsSf https://astral.sh/uv/install.sh | sh` — for wtalk.
- **Karabiner-Elements** — to bind wtalk's push-to-talk key.
- **NextDNS Encrypted-DNS profile** (for nextdns-sidecar's `networklockdown`): download your `.mobileconfig` from <https://apple.nextdns.io> — the nextdns-sidecar installer hardens it (`--profile-src`) and prints the `open` lines to install it in System Settings ▸ General ▸ Device Management. *(nextdns-sidecar refuses to `arm` without it — arming would strand all DNS.)*
- *(Optional)* **Pluckeye** — an extra layer; the lockers' real teeth is demonlock's admin-release-valve delay.

### 2. Install (each app is `sudo ./<app>/install.sh`)
`git clone git@github.com:MT-GoCode/minh-mac-utils.git && cd minh-mac-utils`, then:

1. **demonlock** — `sudo ./demonlock/install.sh` → `demonlock perm-ask` (grant **Location → Always** *and* **Accessibility**, the latter for settings-guard) → `demonlock scan` / `demonlock zones` / `sudo demonlock setpolicy '…'` → `sudo demonlock arm`. Configure the admin release valve (`sudo demonlock admin-release-valve set-gate-policy/set-delay/set-max-request-duration`) so you can get sudo back without holding a password.
2. **nextdns-sidecar** — `sudo ./nextdns-sidecar/install.sh --profile-src ~/Downloads/NextDNS-*.mobileconfig` (enter your Profile ID + API key; it hardens that profile and prints the two `open` lines — approve both in Settings ▸ Device Management) → confirm with `nextdns-sidecar networklockdown status` → `nextdns-sidecar networklockdown arm`. (`nextdns-test <domain>` checks whether a domain is blocked.)
3. **wtalk** — `cd wtalk && ./setup.sh` (venv+deps+ffmpeg) → `sudo ./install.sh` (PyInstaller-freeze, sign, deploy **root-owned** to `/Applications`, seed `~/.wtalk`) → put your Gemini key in `~/.wtalk/.env` → `wtalk restart` → bind a key in Karabiner to `/usr/local/bin/wtalk toggle` → grant **Microphone + Accessibility**.
4. **multistreamviewer / stayup** — `sudo ./multistreamviewer/install.sh`, `sudo ./stayup/install.sh` (each builds, signs, deploys root-owned, and registers itself as a demonlock spare).
5. **forcecalls** *(optional)* — first create a **SIP credential** and a **verified caller ID** in your SignalWire space (see `forcecalls/README.md`; the verified number means you never rent a number) → `sudo ./forcecalls/install.sh`, which prompts for space / project ID / API token / caller ID / SIP endpoint, or takes them as `SW_*` env vars for a non-interactive install → set up the endpoint from `forcecalls/endpoint/README.md` (baresip, auto-answer, root-owned + a watchdog daemon — **do this while you still have sudo**) → `forcecalls testcall +1…` to rehearse it, then `forcecalls add --name mom --destination +1… --schedule *2045`.
6. **remote-agent-connector** *(optional)* — `sudo ./remote-agent-connector/install.sh`, then Dock ▸ Get Permissions and `rac setup`.
7. **agentic-browser-setup** *(optional, no sudo)* — `./agentic-browser-setup/install.sh`.
8. **paseo daemon + third-party spares** *(optional)* — `./scripts/setup-paseo-daemon.sh`, then `sudo ./demonlock/register-recommended-spares.sh` (spares karabiner/alttab/raycast/etc.).

### 3. Only then harden
Verify each tool's `status`. *Then* drop your daily admin with `demonlock nosudo` (re-login to fully
apply). Because there's **no held password**, keep a second admin recovery path (a spare admin
account, or macOS Recovery) until you've confirmed the release valve grants admin back after its
delay.

## Credentials (never in this repo)
Installers scaffold these on the target Mac; you fill them in:
| File | Created by | You |
|---|---|---|
| `/usr/local/etc/nextdns-sidecar/credentials` | nextdns-sidecar install | enter Profile ID + API key at the prompt |
| `~/.wtalk/.env` | wtalk `sudo ./install.sh` (template, user-owned `600`) | paste Gemini/Groq/HF keys |
| `/Library/Application Support/Forcecalls/creds.json` | forcecalls install (root-owned `600`) | enter SignalWire space / project / token / caller ID / SIP endpoint at the prompt — deliberately unreadable afterwards |

(demonlock no longer holds a password anywhere — admin is granted only by the delay-gated release
valve, which edits the `admin` group directly.)

## TCC permissions — human-click only
**Location** → demonlock · **Accessibility** → demonlock (settings-guard) + wtalk · **Microphone** →
wtalk. macOS won't let a script grant these; you click them once per machine (`demonlock perm-ask`
opens both demonlock panes).

## Code signing (demonlock, wtalk, multistreamviewer, stayup, remote-agent-connector, forcecalls)
Only the tools that build macOS `.app`s sign anything (nextdns-sidecar ships a plain CLI binary — no
signing; the bash tools don't sign). They all call the **same** ladder, `signing-ladder.sh`, which
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
sudo ./demonlock/install.sh                  # produces demonlock/dist/Demonlock.app  (Dev-ID-signed)
ditto -c -k --keepParent demonlock/dist/Demonlock.app /tmp/Demonlock.app.zip
gh release create devsigned-$(date +%Y%m) /tmp/Demonlock.app.zip \
    --title "Developer-ID-signed bundles" \
    --notes "Prebuilt, Developer-ID-signed + timestamped — install to keep Apple-rooted trust after the cert lapses."
```

**Using them later** on a Mac with no Developer ID — it's just "copy back + install" (no Xcode, no
Apple account; the installer auto-deploys `dist/` instead of rebuilding when you have no cert):
```bash
gh release download devsigned-YYYYMM --dir /tmp/dl
ditto -x -k /tmp/dl/Demonlock.app.zip demonlock/dist/      # → demonlock/dist/Demonlock.app
sudo ./demonlock/install.sh                                # deploys the dev-signed dist/, no rebuild
```
(demonlock is the only app that commits a prebuilt `dist/` bundle, so it's the one that installs on a
toolchain-less Mac by copy. wtalk is PyInstaller-frozen + Developer-ID-signed by `sudo ./wtalk/install.sh`
on the machine; the other Swift apps build + sign from source at install time.)

## JAMF / MDM caveats (org policy — can't be fixed in code)
- A managed **content/network filter or pinned DNS** will fight nextdns-sidecar's `pf` lockdown + DoH profile.
- **PPPC** profiles can deny or lock the TCC grants above → the lockers fail-closed, wtalk can't record.
- An MDM-managed **admin group** can revert demonlock's release-valve admin grant/revoke.
- Restrictions on third-party **LaunchDaemons**, or a notarization-required **Gatekeeper** policy, can block the daemons/apps.

These need the org to allowlist the tools (and stable signing identities) — not something the installers can force.
