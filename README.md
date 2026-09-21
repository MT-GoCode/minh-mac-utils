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
sudo ./remote-agent-connector/uninstall.sh
./scripts/unset-paseo-daemon.sh
./browser-blitz/browser-blitz/install.sh --uninstall
sudo ./demonlock/uninstall.sh
./gitas/uninstall.sh
```

**Reinstall everything:**
```bash
cd ~/code/minh-mac-utils && git pull
sudo -v
sudo ./demonlock/install.sh
sudo ./multistreamviewer/install.sh
sudo ./stayup/install.sh
sudo ./blockrem/install.sh
sudo ./remote-agent-connector/install.sh
./wtalk/setup.sh
sudo ./wtalk/install.sh
sudo ./nextdns-sidecar/install.sh --profile-src ~/Downloads/NextDNS*.mobileconfig
./browser-blitz/browser-blitz/install.sh
./scripts/setup-paseo-daemon.sh
sudo ./demonlock/register-recommended-spares.sh
./gitas/install.sh ~/my-accounts.ini
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
| **browser-blitz** | drive your **real, logged-in Chrome** with `agent-browser`: a shim impersonates a Chrome CDP endpoint over an MV3 extension, and each agent session is fenced to its own tab group; `browser-blitz` CLI | `./browser-blitz/browser-blitz/install.sh` | no |
| **gitas** | one git identity manager: per-account name/email/PAT in one 0600 file, routed automatically by remote URL (authorship *and* auth from the same trigger). All GitHub over HTTPS+PAT — no keys, no `gh auth`. **Also runs on Linux.** | `./gitas/install.sh <accounts.ini>` | no |

**Paseo daemon (`scripts/`).** `scripts/setup-paseo-daemon.sh` hands the third-party Paseo daemon to
launchd (so it survives the desktop app dying — e.g. when demonlock closes the GUI on a lockout) and
adds a nightly refresh that restarts it only after an app auto-update and only when no agent is running.
`scripts/unset-paseo-daemon.sh` reverses it. Both are no-sudo, run as you, and need `jq`. This is
config-wiring for an external app, not a repo-built tool, so it's a manual script rather than an installer.

**Installers are commonized.** Every `install.sh` is a short manifest over the shared
`scripts/install-lib.sh` (build as you → deploy root-owned → CLI → launchd, **verified running** →
register the demonlock spare); every `uninstall.sh` is one `dl_uninstall_common` call. The shared Swift
plumbing (marker I/O, the delay queue, time parsing, JSON/process/user helpers) lives once in
`MacUtilsCore/` and is linked into demonlock, nextdns-sidecar, and blockrem. There is deliberately
**no top-level all-in-one driver**: each tool is its own install (`sudo ./<tool>/install.sh`, or
`./<tool>/install.sh` for the no-sudo ones), idempotent, and each verifies its own launchd job is
actually *running* before printing ✓. This README is the index and the order.
They don't share one rigid runtime interface — most lockers have `arm`/`disarm`, but wtalk and
browser-blitz don't fit that mold, and that's fine.

**wtalk media auto-pause (optional):** if `nowplaying-cli` is on your `PATH`
(`brew install nowplaying-cli`), wtalk fades the system volume out + pauses whatever's playing when
you start a dictation and fades it back in on stop (decoupled — it only toggles media it actually
paused; no-op if nowplaying-cli isn't installed).

## Fresh-machine setup (in order)

### 1. Base prerequisites (you have admin)
- **Full Xcode, not just the Command Line Tools** — do this FIRST. Install Xcode from the App Store, then:
  ```bash
  xcode-select --install
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  sudo xcodebuild -license accept
  sudo xcodebuild -runFirstLaunch
  ```
  CLT alone is **not enough**. `libSwiftUIMacros.dylib` ships only inside Xcode
  (`Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins/`);
  there is no copy anywhere under `/Library/Developer/CommandLineTools`. SwiftUI implements `@State`
  as an attached macro, so with CLT active every `@State` fails with *"external macro implementation
  type 'SwiftUIMacros.StateMacro' could not be found"*, followed by a cascade of `cannot find
  '$foo' in scope` and `cannot assign to property: 'self' is immutable` — all downstream of that one
  missing plugin. Verify with `xcode-select -p` (must print the Xcode path, not CommandLineTools) and
  `xcrun --show-sdk-path`. Needed to build the Swift apps (demonlock, nextdns-sidecar, blockrem,
  multistreamviewer, stayup, remote-agent-connector). *(demonlock can skip the whole toolchain:
  `sudo ./demonlock/install.sh --prebuilt` deploys its committed, signed `dist/`.)*
- **A console (GUI) login as you** — the gui-domain LaunchAgents can't load over plain SSH, and the installers now fail loudly when a job doesn't come up. Run installs from a local terminal (or `rac exec`), and reinstall `remote-agent-connector` only from a local terminal — its reinstall kills the tunnel an SSH session rides on.
- **Admin**: you must be in the `admin` group. On a hardened machine that means a live demonlock release-valve grant with enough time left (`demonlock admin-release-valve status`); the grant can be extended while live with `sudo demonlock admin-release-valve i-still-need-sudo "for 1h"`.
- **git identity (gitas)** — `./gitas/install.sh ~/my-accounts.ini` (no sudo). Do this before any git work:
  it purges every other credential store and is what makes `git push` and `gh` authenticate as the right
  account. Copy your filled-in `accounts.ini` onto the machine by hand — PATs are never committed.
- **Homebrew**, then `brew install ffmpeg` — for wtalk.
- **uv:** `curl -LsSf https://astral.sh/uv/install.sh | sh` — for wtalk.
- **Karabiner-Elements** — to bind wtalk's push-to-talk key.
- **Node** — `brew install node` — for browser-blitz (its installer also pulls `@playwright/cli` via npm).
- **Paseo.app** *(optional, for step 8)* — install and launch it once so `~/.local/bin/paseo` and
  `~/Library/Application Support/Paseo/desktop-settings.json` exist; `setup-paseo-daemon.sh` refuses without them.
- **Third-party menubar apps you use** *(optional, for step 8)* — Raycast, AltTab, Shottr, Amphetamine,
  BetterDisplay, Scroll Reverser: `register-recommended-spares.sh` can only spare what's installed (it prints ✗ per missing app).
- **NextDNS Encrypted-DNS profile** (for nextdns-sidecar's `networklockdown`): log in at <https://apple.nextdns.io> (a browser step) and download your `.mobileconfig` — it lands as `~/Downloads/NextDNS (<id>).mobileconfig` — the nextdns-sidecar installer hardens it (`--profile-src`) and prints the `open` lines to install it in System Settings ▸ General ▸ Device Management. Pass credentials via `--credentials-file <0600 file with PROFILE=… / API_KEY=…>` so the profile ID (a credential) never sits on argv. *(nextdns-sidecar refuses to `arm` without the profile — arming would strand all DNS.)*
- *(Optional)* **Pluckeye** — an extra layer; the lockers' real teeth is demonlock's admin-release-valve delay.

### 2. Install (each app is `sudo ./<app>/install.sh`)
`git clone https://github.com/MT-GoCode/minh-mac-utils.git ~/code/minh-mac-utils && cd ~/code/minh-mac-utils`
(https — a fresh machine has no SSH key yet), then, in this order:

1. **demonlock** — `sudo ./demonlock/install.sh` → `demonlock perm-ask` (grant **Location → Always** *and* **Accessibility**, the latter for settings-guard) → `demonlock scan` / `demonlock zones` / `sudo demonlock setpolicy '…'` → `sudo demonlock arm`. Configure the admin release valve (`sudo demonlock admin-release-valve set-gate-policy/set-delay/set-max-request-duration`) so you can get sudo back without holding a password.
2. **nextdns-sidecar** — `sudo ./nextdns-sidecar/install.sh --profile-src ~/Downloads/NextDNS*.mobileconfig` (enter your Profile ID + API key; it hardens that profile and prints the two `open` lines — approve both in Settings ▸ Device Management) → confirm with `nextdns-sidecar networklockdown status` → `nextdns-sidecar networklockdown arm`. (`nextdns-test <domain>` checks whether a domain is blocked.)
3. **wtalk** — `cd wtalk && ./setup.sh` (venv+deps+ffmpeg) → `sudo ./install.sh` (PyInstaller-freeze, sign, deploy **root-owned** to `/Applications`, seed `~/.wtalk`) → put your Gemini key in `~/.wtalk/.env` → `wtalk restart` → bind a key in Karabiner to `/usr/local/bin/wtalk toggle` → grant **Microphone + Accessibility**.
4. **multistreamviewer / stayup** — `sudo ./multistreamviewer/install.sh`, `sudo ./stayup/install.sh` (each builds, signs, deploys root-owned, and registers itself as a demonlock spare).
5. **blockrem** — `sudo ./blockrem/install.sh` → `blockrem perm-ask` (Accessibility, for the input freeze) → `blockrem set …` / `blockrem list`. Alarm management is no-sudo.
6. **remote-agent-connector** *(optional)* — `sudo ./remote-agent-connector/install.sh`, then Dock ▸ Get Permissions and `rac setup`.
7. **browser-blitz** *(optional, no sudo)* — `./browser-blitz/browser-blitz/install.sh` deploys the shim + CLI + extension to `~/.local/lib/browser-blitz` (nothing runs from the checkout; `git pull && ./install.sh` redeploys and restarts the shim), then load the extension once per Chrome profile you want to drive: `chrome://extensions` → Developer mode → **Load unpacked** → `~/.local/lib/browser-blitz/extension`.
8. **paseo daemon + third-party spares** *(optional)* — `./scripts/setup-paseo-daemon.sh`, then `sudo ./demonlock/register-recommended-spares.sh` (spares karabiner/alttab/raycast/etc.).

### 2b. The clicks only a human can do (once per machine)
System Settings ▸ Privacy & Security: **Location Services** → Demonlock: *Always* · **Accessibility** →
Demonlock, Blockrem, multistreamviewer, wtalk, RemoteAgentConnector · **Screen Recording** →
multistreamviewer, RemoteAgentConnector · **Microphone** → wtalk · **Automation** → RemoteAgentConnector ·
**Input Monitoring** + the driver-extension approval → Karabiner-Elements. Then General ▸ Device
Management → install the two NextDNS profiles; Karabiner → a rule `F5 → /usr/local/bin/wtalk toggle`;
Chrome → Load unpacked (above); `rac setup` once MIDDLEMAN is reachable.

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

(demonlock no longer holds a password anywhere — admin is granted only by the delay-gated release
valve, which edits the `admin` group directly.)

## TCC permissions — human-click only
**Location** → demonlock · **Accessibility** → demonlock (settings-guard) + wtalk · **Microphone** →
wtalk. macOS won't let a script grant these; you click them once per machine (`demonlock perm-ask`
opens both demonlock panes).

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
While you still have the cert, publish the dev-signed bundles as a release. `gh` needs no stored
login — gitas hands it a PAT (`brew install gh`, then prefix the command with
`gitas exec personal --`):

```bash
# with your Developer ID cert present, after the repo is pushed:
./demonlock/install/build.sh --refresh-dist  # produces demonlock/dist/Demonlock.app  (Dev-ID-signed)
ditto -c -k --keepParent demonlock/dist/Demonlock.app /tmp/Demonlock.app.zip
gh release create devsigned-$(date +%Y%m) /tmp/Demonlock.app.zip \
    --title "Developer-ID-signed bundles" \
    --notes "Prebuilt, Developer-ID-signed + timestamped — install to keep Apple-rooted trust after the cert lapses."
```

**Using them later** on a Mac with no Developer ID — "copy back + install" with the explicit
`--prebuilt` flag (a toolchain otherwise always wins and builds the current source; the old automatic
"no cert → use dist" rule silently installed stale bundles, so it's gone):
```bash
gh release download devsigned-YYYYMM --dir /tmp/dl
ditto -x -k /tmp/dl/Demonlock.app.zip demonlock/dist/      # → demonlock/dist/Demonlock.app
sudo ./demonlock/install.sh --prebuilt                     # deploys the dev-signed dist/, no rebuild, no keychain
```
Refresh a committed `dist/` deliberately with `./demonlock/install/build.sh --refresh-dist`.
(demonlock is the only app that commits a prebuilt `dist/` bundle, so it's the one that installs on a
toolchain-less Mac by copy. wtalk is PyInstaller-frozen + Developer-ID-signed by `sudo ./wtalk/install.sh`
on the machine; the other Swift apps build + sign from source at install time.)

## JAMF / MDM caveats (org policy — can't be fixed in code)
- A managed **content/network filter or pinned DNS** will fight nextdns-sidecar's `pf` lockdown + DoH profile.
- **PPPC** profiles can deny or lock the TCC grants above → the lockers fail-closed, wtalk can't record.
- An MDM-managed **admin group** can revert demonlock's release-valve admin grant/revoke.
- Restrictions on third-party **LaunchDaemons**, or a notarization-required **Gatekeeper** policy, can block the daemons/apps.

These need the org to allowlist the tools (and stable signing identities) — not something the installers can force.
