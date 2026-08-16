# demonlock

Conditional macOS locker. One root daemon evaluates a single boolean **policy** over your
location, the time of day, and nearby Wi‑Fi access points; when you're **out of policy** it shows
a 10‑second countdown and then **force-closes your GUI apps** (`sshd`/`tmux` survive, so you can SSH
in to disarm). Replaces `location-locker` + `nightlock` with one signed Swift binary. Installs **disarmed**.

demonlock also **absorbs two former standalone tools**: **settings-guard** (the old `settingslock` —
slams System Settings shut on the FileVault / Device-Management / Profiles panes; needs an
Accessibility grant) and the **internal admin grant/revoke** (the old `sudome`, now done directly by
the root daemon — no setuid binary, no held password). Getting sudo back is the delay-gated
**admin release valve**.

```bash
sudo ./install.sh                 # build (or deploy prebuilt) → sign → install → load. DISARMED.
demonlock scan                    # walk the floor, capture AP hardware addresses (no sudo)
demonlock zones                   # draw/name zones on a map (add/delete = admin now, or queue 36h)
sudo demonlock setpolicy '...'    # set the allow-condition
demonlock status                  # see exactly how it evaluates right now
sudo demonlock arm                # enforcement on (also drops admin + closes the release valve)
```

## Architecture

One Mach-O, multiplexed by subcommand into two long-running roles:

| Role | launchd job | Runs as | Job |
|---|---|---|---|
| `enforcerd` | LaunchDaemon, **`system`** domain | **root** | the *only* evaluator/enforcer: polls, evaluates the policy, runs the countdown, performs the lockout (force-kills GUI apps, sparing the agent), keeps Wi‑Fi on, writes `state.json` |
| `agent` | LaunchAgent, **`gui/<uid>`** domain | **you** | reads CoreLocation + scans Wi‑Fi BSSIDs (CoreWLAN), feeds them to the daemon over a cdhash-authenticated socket, draws the status/countdown panel |

**Why the split is forced.** macOS delivers CoreLocation / CoreWLAN scan results only to a
*foreground GUI app* holding a TCC Location grant — never to a root daemon ⇒ sensing must live in
the agent. But a logged-in user can `launchctl bootout` their *own* `gui/<uid>` agents without
admin ⇒ the *enforcer* must be a root `system` daemon (needs sudo to stop).

**Trust boundary (the security core).** The daemon accepts location/BSSID data only from a socket
peer whose code-signature **cdhash** matches its own — it pulls the peer's kernel **audit token**
off the unix socket, builds a `SecCode`, and runs `SecCodeCheckValidity` against a
`cdhash H"…"` requirement built from its *own* running code. Because the daemon and agent are the
*same signed binary*, their cdhashes are identical. A killed, modified, or
Location-revoked agent can't feed it ⇒ **fail-closed**. Hardened runtime stops anyone injecting a
fake fix into the live agent.

**Verdict is three-valued (Kleene).** Each clause is true / false / **unknown** (its sensor input
is unavailable). `OR` = true if *any* branch true (even with unknowns); `AND` = false if *any*
false. Verdict **ALLOW** only when the whole expression is true; **BLOCK** on false (out of policy)
*or* unknown (genuinely can't determine). So sabotaging a sensor can only push a clause to
false/unknown, never true — you can never *gain* access by killing the agent.

## Policy language

The ALLOW condition, with `AND` / `OR` / `NOT` / parens and three primitives:

| Function | True when |
|---|---|
| `LOCATED_IN_ANY(["zone", …])` | inside any named zone (circle or simple polygon) |
| `FOUND_IN_NEARBY_BSSID(["aa:bb:cc:dd:ee:ff", …])` | any pinned AP hardware MAC is in range |
| `TIME_IS_ANY([MTWRF0900-1700, *1000-1800, …])` | now ∈ a window — days `M T W R F S U` (R=Thu,U=Sun) or `*`; `HHMM` `0000`–`2400`, `start<end` (no midnight wrap) |

`setpolicy` parses, checks every referenced zone exists, dry-runs, and refuses to install a bad
policy. **BSSID** (AP hardware MAC) is used over the SSID name because names are trivially spoofed;
`scan` flags **stable** hardware APs vs random/virtual ones — pin the stable ones.

## Source files

| File | Role |
|---|---|
| `main.swift` | subcommand dispatch + grouped help |
| `Paths.swift` | every path / launchd label / bundle id (single source of truth) |
| `Settings.swift` · `State.swift` · `Zones.swift` | settings.json (v2: baked `Bounds`, per-slot delays, `safeApps`/`snoozePresets`), the published `StateSnapshot`/`FeedPayload`/`EvalNode` types + small root files, zone model (circle/polygon, ray-cast) |
| `Policy.swift` · `PolicyTest.swift` | tokenizer → parser → three-valued evaluator → validator; `_policytest` unit tests |
| `Feed.swift` | cdhash-authenticated socket server (root, euid-pinned) + sender (agent) |
| `Sensors.swift` · `Wifi.swift` | agent CoreLocation + CoreWLAN BSSID feed + GUI kill-target enumeration; root-side Wi‑Fi keep-on |
| `Enforcerd.swift` | the root daemon: poll loop, state machine, lockout (force-kill GUI), drives every subsystem tick |
| `Agent.swift` · `ZonesUI.swift` | status/countdown panel + menubar (also runs settings-guard); the `zones` map program |
| `Commands.swift` | the CLI: `status`/`setpolicy`/`arm`/`disarm`/`nosudo`/`snooze`/`perm-ask`/`test-lockout` + the subsystem parsers |
| `Admin.swift` | internalized admin (sudo) grant/revoke via `dseditgroup` — replaces the retired `sudome` |
| `SettingsGuard.swift` | the folded-in `settingslock` — kills System Settings on a guarded pane (Accessibility) |
| `ReleaseValve.swift` | the delay-gated admin release valve (config + lifecycle + tick) |
| `SafeApps.swift` · `SnoozePresets.swift` · `Lockbox.swift` | the request→delay→apply subsystems: spare list, named snooze shortcuts, password lockbox |
| `DelayedChange.swift` · `MarkerIO.swift` · `TimeSpec.swift` · `Tables.swift` | delayed policy/zones/gate-policy engine; hardened marker read (O_NOFOLLOW + owner-check + unlink-verify); duration/target parsing; table renderer |
| `install/` | `build.sh` (codesign), `install.sh`, `uninstall.sh`, `Info.plist`, two `.plist`s |
| `dist/Demonlock.app` | prebuilt, signed bundle so a toolchain-less Mac installs by copy |

## Install

`sudo ./install.sh` (auto-detects what it needs):

1. **Picks the bundle by what you have:** if a **Developer ID cert** is in your login keychain →
   builds + re-signs fresh as `$SUDO_USER` (`swift build -c release` → `codesign --options runtime
   --timestamp`, refreshing `dist/`). **No cert** → deploys the bundled `dist/Demonlock.app`
   (already Developer-ID-signed + timestamped) **without re-signing**, so it isn't downgraded to
   ad-hoc. (Ad-hoc build is the last resort: toolchain but no cert and no `dist/`.) Strips
   quarantine either way.
2. Copies app → `/Applications`, a CLI wrapper → `/usr/local/bin/demonlock`.
3. Seeds `/Library/Application Support/Demonlock/` — `enforcedUser`=`$SUDO_USER` + `wifiDevice`
   auto-detected; `armed=0` ⇒ **installs disarmed**. A reinstall **merges** those two per-machine
   keys into any existing `settings.json` (it never overwrites your registered safe-apps, snooze
   presets, or tuned delays). Creates the **user-owned `rv/` inbox** so the no-sudo request commands
   can drop markers without sudo.
4. Installs both plists; writes `/etc/sudoers.d/demonlock` granting passwordless **`arm`** and
   **`nosudo`** only (both TIGHTEN — safe without admin, survive you dropping it). The grants target
   the go-w, root-owned **bundle binary** (`/Applications/Demonlock.app/Contents/MacOS/demonlock`),
   NOT the `/usr/local/bin` wrapper, and the installer **asserts `/usr/local[/bin]` is root-owned**
   and aborts otherwise (else a wrapper-path grant could be arbitrary root). The old free `_zonedel`
   grant is **gone** (zone delete isn't monotone → now admin-or-delayed). Also removes any retired
   setuid `sudome` binary + `/usr/local/etc/sudome`.
5. Points the agent log at `~/Library/Logs/demonlock-agent.log` (not world-writable `/tmp`),
   `bootstrap`s `enforcerd` into `system` and `agent` into `gui/$SUDO_UID`, verifies `com.demonlock`
   is in the spare list, and runs `perm-ask` (opens the **Location** *and* **Accessibility** panes —
   one click each, once per machine).

## Post-install layout & permissions

| Path | Owner:Group | Mode | What |
|---|---|---|---|
| `/Applications/Demonlock.app` | root:wheel | 755 | the signed binary (both roles) |
| `/usr/local/bin/demonlock` | root:wheel | 755 | CLI wrapper → app binary |
| `/Library/LaunchDaemons/com.demonlock.enforcerd.plist` | root:wheel | 644 | root daemon (RunAtLoad+KeepAlive) |
| `/Library/LaunchAgents/com.demonlock.agent.plist` | root:wheel | 644 | GUI agent (RunAtLoad+KeepAlive) |
| `…/Demonlock/policy.txt` `zones.json` `settings.json` `armed` `snooze` `state.json` `heldfix.json` | root:wheel | 644 | config + state — world-readable so `status` works, **root-only writable = the lock** |
| `…/Demonlock/` subsystem state: `releasevalve.json` `rv-state.json` `delayed-{policy,zones,gatepolicy}.json` `safe-apps-pending.json` `snooze-presets.json` `lockbox-state.json` | root:wheel | 644 | request→delay→apply pending state for each subsystem (never secrets) |
| `…/Demonlock/lockbox.json` | root:wheel | **600** | the password-lockbox secret vault — root-only, never group/other-readable |
| `…/Demonlock/rv/` | **you** | 755 | the **user-owned inbox**: no-sudo request/abort markers (the daemon stamps the real request time itself, so the delay can't be backdated) |
| `…/Demonlock/logs/enforcerd.log` | root:wheel | 644 | daemon log |
| `/etc/sudoers.d/demonlock` | root:wheel | 440 | passwordless **`arm`** + **`nosudo`** only (both tighten), targeting the bundle binary |
| `/var/run/demonlock.sock` | root | 0666 | sensor feed — identity *verified by cdhash* + peer euid pinned to the enforced uid, not access-gated |
| `~/Library/Logs/demonlock-agent.log` | you | 644 | agent log (moved off world-writable `/tmp`) |

(`/Library/Application Support/Demonlock/` is `755 root:wheel`.)

### Moving your zones (and policy) to a new machine

Everything you author lives in `/Library/Application Support/Demonlock/`. The two files worth
carrying over are **`zones.json`** (your named circles/polygons) and **`policy.txt`** (the rule
string). They're plain text, root-owned `644` — readable by anyone, writable only by root. To
clone them onto a freshly-installed Mac:

```bash
# on the OLD machine — grab the files (no sudo needed to read)
cp "/Library/Application Support/Demonlock/zones.json"  ~/Desktop/
cp "/Library/Application Support/Demonlock/policy.txt"  ~/Desktop/

# on the NEW machine — after `sudo ./install.sh` has created the support dir:
sudo cp ~/Desktop/zones.json "/Library/Application Support/Demonlock/zones.json"
sudo demonlock setpolicy "$(cat ~/Desktop/policy.txt)"   # validates names + dry-runs before it lands
```

`sudo cp` is required on the destination because the support dir is root-writable only (that's the
lock). Use `setpolicy` rather than copying `policy.txt` directly so it re-checks every zone name
exists and dry-runs the tree first. The daemon picks up the new `zones.json` on its next tick — no
reload needed.

## OS interactions & enforcement

- **Poll loop.** `enforcerd` ticks immediately, then every `pollSeconds` (1s), tightening to
  `countdownPollSeconds` (0.5s) during a countdown. It only acts when the **console user**
  (`/dev/console` owner) equals `enforcedUser`.
- **Sensing under TCC.** The agent's CoreLocation `authorizedAlways` grant is what un-redacts both
  the location fix *and* CoreWLAN BSSID scans (macOS redacts SSIDs/BSSIDs to any process without a
  Location grant — which is also why `scan` refuses to run as root: root has no grant).
- **Location model: held fix + ONE confidence timer (see `MODEL.md`, the design of record).**
  Macs position from Wi‑Fi only; CoreLocation goes silent when nothing changes, so a fix is **never
  judged by raw age**. The held fix carries one timer, `confirmedUntil`: a genuine new fix, or the
  live scan still overlapping the fix's **BSSID anchor** (per-AP hardware MACs, not network names; ≥1
  shared = still here — moving to a different physical router, even on the same SSID, drops it to zero),
  pushes it `graceSeconds` into the future. While `now < confirmedUntil` the fix is **LIVE** and drives
  the policy; once nothing confirms it — Wi‑Fi off, anchor mismatch, **or the agent dies** — the timer
  runs out → STALE → fail-closed. One timer, every "no signal" case coasts the same. The agent runs
  **foreground (`.regular`, dock icon)** and feeds a rolling union of recent BSSIDs, so a full sweep
  catches both bands of a dual-band router (band-steering can't false-lock you) and an empty window is
  read as real signal-loss. The held fix persists root-owned (`heldfix.json`, heartbeat-rewritten so a
  restart resumes without a false lock) across reboot/sleep — login/wake need no special cases, and the
  user can't forge it.
- **Wi‑Fi keep-on.** While armed, each tick re-enables the radio via `networksetup
  -setairportpower` if it's off — CoreLocation positions from Wi‑Fi, so the radio must stay on.
- **Lockout.** At countdown zero, armed → the root daemon **force-kills the user's GUI apps** every
  tick, **sparing the agent** so it keeps sensing and recovery is instant (back in policy → killing
  stops). If the agent itself is dead, it falls back to `killall WindowServer` (rate-limited). `sshd`/
  `tmux` survive so you can SSH in and `sudo demonlock disarm`. No penalty box; no logout.
- **Fail-closed, but only when it matters.** Stale/missing agent feed, denied Location, missing or
  invalid policy, or a missing `armed` file all resolve to a block *when armed* — but the
  three-valued logic means a still-decidable clause (e.g. an allowed time window, or another zone)
  keeps you allowed. Disarmed = same evaluation, countdown shows, but the lockout is a no-op (title
  reads `(DISARMED)`).
- **Zone changes go through the admin-or-delayed path — both directions.** Adding a zone *loosens*
  policy, so the map UI asks **"Save now (admin)"** vs **"Save in 36h"**. Deleting *looks* like it
  tightens, but a zone referenced under `NOT` actually loosens on delete, so zone delete is **not
  monotone** — the old free `_zonedel` sudoers grant is **removed**, and a dangling zone reference now
  evaluates to `.unknown` (fail-closed) rather than false. Delete is therefore admin-or-delayed too.
- **Signing.** Developer ID + secure timestamp ⇒ runs on any Mac and stays valid after the cert
  expires; ad-hoc fallback is fully sufficient for the cdhash-trust + hardened-runtime model.

**Residual holes (honest):** OS-level location spoofing needs sudo (disable SIP / attach a
debugger to the hardened agent / tamper the signed app) — all blocked by a no-admin posture;
physical RF BSSID spoofing is exotic but possible. SSIDs are unauthenticated, which is why the
Wi‑Fi check pins BSSIDs.

## Commands & settings

**User (no sudo):** `status` · `zones` (`view-zones`/`edit-zones` alias it; `zones list` prints
names) · `scan` · `perm-ask` · `arm` (tightens — passwordless via sudoers; also drops admin + closes
the release valve) · `nosudo` (drop admin now) · `test-lockout` (see below) · `settings-guard` (+
`dump`) · `admin-release-valve …` · `safe-apps …` · `snooze-preset …` · `password-lockbox …` ·
`delay-set-policy "<expr>"` (queue a policy; lands after the delay — `--status`/`--abort`;
`delaysetpolicy` still aliases it) · `delayzones --status`/`--abort` (view/cancel a zones change
queued from the map) · `help`.

**Sudo:** `setpolicy` · `disarm` · `snooze "<spec>"` (flexible stand-down: `"for <duration>"` in
d/h/m/s, or `"until <[day]HHMM>"`, e.g. `snooze "for 90m"` / `snooze "until 0730"`; **capped at 18h**;
implies armed and **RE-ARMS automatically** at expiry — so escape-then-resume is just `snooze`) · plus
the immediate/config variants of the subsystems (`safe-apps register`, `snooze-preset add`,
`password-lockbox add`, `admin-release-valve set-*`, `… i-still-need-sudo`).

`arm` = enforce now (cancels a snooze); `disarm` = off indefinitely. `snoozetonight` and
`igotshitdueatmidnight` are **gone** — `snooze-preset` supersedes both (see below).

Settings live in root-owned `settings.json` (v2 — **644, root-writable-only = the lock**; the agent
must read it, so it can't be 600). Knobs: sensing/timing (`pollSeconds`, `countdownPollSeconds`,
`countdownSeconds`, `graceSeconds`, `maxAccuracyMeters`, `scanSeconds`, `scanWindowSeconds`,
`agentRefreshSeconds`, and the internal `feedFreshSeconds`/`agentGraceSeconds`/`agentKickSeconds`/
`nuclearRelockSeconds`/`heldPersistSeconds`); identity (`enforcedUser` [username **or** uid — the
lockout target], `wifiKeepOn`, `wifiDevice`); settings-guard (`guardSettingsPanes`,
`guardedSettingsTitles`); the per-subsystem delays (`policyDelaySec`, `zonesDelaySec`,
`gatePolicyDelaySec`, `safeAppsDelaySec`, `snoozePresetAddDelaySec`); and the subsystem tables
(`safeAppsUser`/`safeAppsRemoved`, `snoozePresetsUser`/`snoozePresetsRemoved`). `snoozeHHMM` remains
only as a legacy field. There is deliberately **no fix-age knob** and no startup-grace knob — a held
fix is valid while it keeps being confirmed, never judged by raw age. See `MODEL.md`.

**Baked bounds (the commitment device).** Only the **floors/ceilings of the no-sudo request paths**
are compiled into the binary (a `Bounds` enum), not read from any file — a root `settings.json` edit
is silent, a recompile is not. They **clamp at request and apply time**, so a stale or hand-edited
settings file can't shorten a no-sudo delay: safe-apps register `8h–168h`, snooze-preset add
`24h–168h`, snooze-preset invoke `≥1h`, snooze duration `≤18h`, policy / zones / gate-policy delay
`12h–168h`, release-valve request delay `≥30m`, max grant duration `≤4h`, `i-still-need-sudo` `≤1h`
per call, lockbox unlock delay `≥1h`.

## settings-guard (the folded-in `settingslock`)

Slams **System Settings** shut the instant it renders a **guarded pane** — the FileVault recovery-key
pane (so you can't read your own key) and Device Management / Profiles (so you can't yank the NextDNS
DoH profile or an MDM profile that enforces discipline). The window **title** becomes the pane name
exactly, so a cheap title check every 100 ms catches it long before "Show"/Remove can be clicked, then
`SIGKILL`s System Settings. It runs **inside demonlock's agent** (a GUI process), so it needs an
**Accessibility** grant (`demonlock perm-ask` opens the pane), and it's **active only while armed**.

```bash
demonlock settings-guard        # status: enabled?, the trigger strings, Accessibility granted?
demonlock settings-guard dump   # print every window title on the current Settings pane, to confirm
                                #   the exact trigger string for a pane on this macOS version
```

## Admin (sudo) model — internalized, no `sudome`

The retired setuid `sudome` binary is **gone**. Because the enforcer is already root, demonlock
grants/revokes admin **itself** (`Admin.swift`): grant = `dseditgroup -a … admin`, revoke =
`dseditgroup -d` + drop any stale per-user `sudoers.d` override + wipe cached sudo timestamps
(`/var/db/sudo/ts/*`) so a revoke bites immediately, not after sudo's 5-minute window. There is **no
password anywhere**. Every grant path (the release valve) and every revoke path (valve expiry/abort,
`arm`, `nosudo`) routes through here, so revocation is uniform and idempotent.

**Honest limit (by design, out of the threat model):** admin obtained during a grant is not truly
*contained* — a login shell open during the grant keeps `admin` in its cached supplementary groups
after `dseditgroup -d`, and a determined user could plant residue a revoke won't clean. That's
inherent to handing out real root. **The REQUEST DELAY is the commitment gate; the auto-revoke is
anti-accident** (stop sudo lingering by mistake), not a containment boundary.

## safe-apps (replaces the old `spareApps` map)

The LOCKED action SIGKILLs **every `.regular` (Dock) app — including Apple ones like Safari — plus
every non-Apple `.accessory` (menubar) app**, so a distraction repackaged as `LSUIElement` can't dodge
the lockout. A `.accessory` app not on the list is spared **only if its live signature is genuinely
Apple-signed** (`anchor apple`), so Control Center / Spotlight / Siri survive but an `LSUIElement`
distraction stamped `com.apple.…` is killed — the bundle-id string is never trusted, the signature is
verified. The agent is spared by PID; pure daemons (nextdns-sidecar) have no `.regular` GUI
app and are never in the kill-list. Everything else dies unless it's a **verified** safe-app.

Each safe-app is `{name, bid, tid, rootOwned}`, and is spared by **one of two regimes** (`spareVerified`
in `Sensors.swift`):

- **`rootOwned: true` → Regime A** (our own apps, root-owned installs in `/Applications`): spared if it
  has an **intact signature matching the identifier — ANY signing identity**. No Team ID / Apple anchor
  required, so your own apps **keep working even if you lose your Developer ID**. Safe because the
  adversary has no sudo, so can't create or modify a root-owned bundle (the check now also stats the
  inner `Contents/MacOS/<exec>`, not just the top `.app`).
- **`rootOwned: false` → Regime B** (third-party, e.g. Raycast): spared only if **Apple-rooted with the
  vendor's Team ID** (`anchor apple generic` + that bid + that Team OU). **Refused for our own team** —
  an own-team app *must* be root-owned (we hold the `BULCQM9J2V` key, so a Regime-B fallthrough would
  let a browser renamed `com.demonlock` be spared).

**Baked blocklist (`register` refuses):** every browser bundle id (Chrome/Safari/Firefox/Edge/Brave/
Arc/Opera/Vivaldi/Yandex, incl. beta/dev channels) and `sh.paseo.desktop` — sparing any of them would
defeat the whole point. (The Paseo daemon helper `sh.paseo.desktop.helper` is a *different* bundle id,
so it can still be spared — the GUI dies, the daemon lives.) `com.demonlock` is **unremovable** (losing
it → the agent dies on lockout → nuclear WindowServer loop).

**The compiled default spare list is just `com.demonlock` itself** — demonlock is standalone and coupled
to nothing. Everything else registers INTO it over time: your own apps (`wtalk`/`remote-agent-connector`/
`msv2`/`stayup`, Regime A) from their own installers, the paseo daemon (Regime B) from
`setup-paseo-daemon.sh`, and third-party utils (`alttab`/`raycast`/`shottr`/`amphetamine`/`betterdisplay`/
`scroll-reverser`/`karabiner-*`, Regime B) via `register-recommended-spares.sh`.

```bash
demonlock safe-apps show                                    # the effective list + pending registrations
sudo demonlock safe-apps register com.x.Foo                 # immediate; root-owned (Regime A) — bundle only
sudo demonlock safe-apps register com.x.Foo --no-root-ownership --tid TEAMID10   # Developer-ID (Regime B)
demonlock safe-apps delayed-register com.x.Foo              # no sudo; lands after the delay
demonlock safe-apps delayed-register abort <name> | --all
demonlock safe-apps remove <name>                           # no sudo, IMMEDIATE (removing tightens)
sudo demonlock safe-apps set-delay "24h"                    # delayed-register delay (baked 8h–168h)
```

**Root-owned needs ONLY the bundle id** — Regime A never reads the team. `--no-root-ownership` (Regime B)
needs `--tid <TEAM>`; own-team apps can't use it. Optional `--name` overrides the auto-derived handle.
`demonlock safe-apps show` is the single source of truth — `verify-spare.sh` queries it.

### To whitelist a new app of yours

A brand-new own app is **killed** unless you do BOTH: install it **root-owned** in `/Applications`
(sudo — a `~/Applications` copy is user-owned ⇒ fails the owner check), and register it root-owned
(`sudo demonlock safe-apps register <bundle-id>`, or the installer's tail does it for you). A self-made `com.demonlock` impostor you can write to is user-owned ⇒ killed; the genuine
one is root-owned and tamper-evident (editing it breaks the signature ⇒ also killed).

## test-lockout

Prove the per-app kill works without arming and waiting to fall out of policy:

```bash
demonlock test-lockout        # DRY RUN — lists exactly the apps a real lockout would SIGKILL
demonlock test-lockout --go   # actually close them now
```

Spared apps, Apple menubar items, and `sshd`/`tmux` survive; a test **never** does the nuclear
`killall -9 WindowServer`.

## admin-release-valve (the delay-gated admin grant)

Get sudo back on *your* terms. Configure it once (sudo), then `request` (no sudo); the daemon stamps
the request time itself, waits out the delay, and — the first tick the **gate policy** is provably
true — grants admin for your requested duration, then revokes. **The request delay is the real gate**
(you can't backdate it — the marker lands in the user-owned `rv/` inbox but the *root daemon* clocks
it); the auto-revoke after the duration is anti-accident, not containment (see the admin model above).
Old aliases `release-valve` / `rv` still route here.

```bash
# configure (sudo; each sets one field):
sudo demonlock admin-release-valve set-gate-policy "IN_POLICY AND TIME_IS_ANY([*1000-1100])"
sudo demonlock admin-release-valve set-delay "12h"                 # wait after request before eligible (≥30m)
sudo demonlock admin-release-valve set-max-request-duration "1h"   # ceiling on a request's grant length (≤4h)
# use (no sudo, once all three are set):
demonlock admin-release-valve request "1h"    # ask for ≤1h of admin; granted after the delay, at the next open gate
demonlock admin-release-valve status          # phase / countdown / gate-eval tree
demonlock admin-release-valve abort           # cancel a pending request OR close a live grant now
# extend a LIVE grant (SUDO — you only hold admin during a grant, so this can EXTEND but never bootstrap):
sudo demonlock admin-release-valve i-still-need-sudo "for 45m"     # ≤1h more per call, in-window only
```

- **`IN_POLICY`** is a policy primitive valid **only** in the gate policy — the main policy's current
  verdict, so you can gate grants on being in-policy (plus any time/location clause). The valve grants
  **admin only**; it does not stand demonlock down, so keep `IN_POLICY` in your gate policy if you
  don't want to be locked out during the grant.
- **`request` is idempotent while pending** — a repeat only updates the duration, never resets the
  frozen eligibility (can't shorten *or* re-extend the delay). Once granted, extend via
  `i-still-need-sudo` (sudo, in-window) or `abort` and re-request.
- **`arm` and `nosudo` close the valve** (abort a pending request + revoke a live grant inline), so a
  request can't hand out sudo minutes after you armed and `status` never lies.
- **delay-set-gate-policy** changes the gate policy itself on a delay (no sudo):
  `demonlock admin-release-valve delay-set-gate-policy "<expr>"` (+ `status`/`abort`;
  `sudo … delay-set-gate-policy set-delay "<dur>"`, baked 12h–168h).
- Notifications fire on grant and revoke; `demonlock status` and the panel show the phase,
  delay/duration remaining, and the gate-eval tree.

## snooze-presets (replaces `snoozetonight` + `igotshitdueatmidnight`)

Named snooze shortcuts, each `{name, spec, invokeDelay}` where `spec` is a `"for <dur>"` /
`"until <[day]HHMM>"` target and `invokeDelay` is how long **after** you invoke it before the snooze
lands (the commitment device). A snooze **stands down THEN re-arms**; `"until"` targets are **frozen
at invoke time** (keeps the midnight fail-closed lesson) and every stand-down is **capped at 18h**.

Two defaults reproduce the retired commands: **`tonight`** (`until 0500`, 1h invoke delay ≈
`snoozetonight`) and **`midnight`** (`until 0005`, 1.5h ≈ `igotshitdueatmidnight`).

```bash
demonlock snooze-preset show                     # presets + pending delayed-adds
demonlock snooze-preset invoke tonight           # stand down after the invoke-delay, then re-arm (no sudo)
demonlock snooze-preset abort                     # cancel the in-flight invocation (ONE globally)
demonlock snooze-preset remove <name>            # no sudo, IMMEDIATE (removing tightens)
demonlock snooze-preset delayed-add --name crunch --duration "for 4h" --delay "24h"   # lands after the add-delay
demonlock snooze-preset delayed-add abort <name> | --all
sudo demonlock snooze-preset add --name crunch --duration "for 4h" --delay "1h"       # immediate
sudo demonlock snooze-preset set-delay "48h"     # the delayed-add delay (baked 24h–168h)
```

Only **one invocation is in flight at a time**. `sudo demonlock snooze "<spec>"` remains the immediate
root escape hatch alongside the presets.

## password-lockbox (a delay-gated secret store — NOT a privilege path)

A general password manager for arbitrary secrets. It does **not** hold the admin password (admin is
only via the release valve; there's no password anywhere). Secrets live in a **separate 0600 root-only
file** (never `settings.json`, which is 644); only lock *state* (names, locked/unlocked, time-left) is
published for `show`.

```bash
demonlock password-lockbox show                              # names, unlock-delay, locked/unlocked
demonlock password-lockbox unlock <name>                     # no sudo; copyable after the entry's delay
demonlock password-lockbox abort <name>                      # cancel a pending unlock / relock now
demonlock password-lockbox copy <name>                       # if unlocked: copy (concealed) + relock immediately
demonlock password-lockbox add --name <n> --delay "1h"       # then paste the secret twice (no sudo; sudo add = direct)
```

`copy` puts the secret on the clipboard as a **concealed pasteboard type**
(`org.nspasteboard.ConcealedType`) so a spared clipboard manager (Raycast keeps history) doesn't retain
it. An unlocked entry **auto-relocks 15 min** later if never copied; per-entry unlock delay floor is 1h.

## Delayed changes (`delay-set-policy` + the map's "Save in 36h")

Where the release valve hands back **admin on a delay**, delayed changes hand back the **policy and
zones themselves on a delay** — no sudo, no admin, ever. The gate is purely the **wait** (default 36h,
baked 12h–168h): queue a loosening now, and only calmer-you-later actually gets it. Same trust split as
the valve (root-owned pending state; a user-owned inbox marker; the **daemon stamps the request time**),
and the change is **re-validated at apply time** (a referenced zone could be gone) — fail-closed if it
no longer parses.

```bash
demonlock delay-set-policy '(LOCATED_IN_ANY(["office"])) AND TIME_IS_ANY([MTWRF0700-2000])'
                                    # queue a NEW allow-policy; lands after the delay (no sudo now OR then)
demonlock delay-set-policy --status # what's queued + when it lands   (delaysetpolicy still aliases it)
demonlock delay-set-policy --abort  # cancel it
```

Zones ride the **same engine**: in the map (`demonlock zones`), a save asks **"Save now (admin)"** vs
**"Save in 36h"**; *36h* queues the change and the daemon installs it after the wait. View/cancel with
`demonlock delayzones --status` / `--abort`.

- **Applies regardless of arm / snooze / who's logged in** — run at the very top of the enforcer tick,
  so this tick's own evaluation already sees the freshly-written `policy.txt` / `zones.json`.
- **Re-queueing resets the delay** (stricter, never shorter). An **alert dialog** (breaks Focus/DnD)
  fires when a change lands; `demonlock status` and the panel show what's pending.
- Immediate `sudo demonlock setpolicy` and admin zone-saves are untouched — this only *adds* a
  no-sudo, delayed path alongside them.

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

Override with `CODESIGN_IDENTITY="…"`. (demonlock also keeps a committed Developer-ID `dist/` bundle
it deploys when you have no cert — so it's never downgraded.)

## Uninstall

```bash
sudo ./uninstall.sh            # bootout both, remove app/CLI/plists/sudoers/socket (keeps config)
sudo ./uninstall.sh --purge    # also wipe /Library/Application Support/Demonlock
```
