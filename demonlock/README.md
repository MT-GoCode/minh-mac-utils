# demonlock

Conditional macOS locker. One root daemon evaluates a single boolean **policy** over your
location, the time of day, and nearby Wi‑Fi access points; when you're **out of policy** it shows
a 10‑second countdown and then **force-closes your GUI apps** (`sshd`/`tmux` survive, so you can SSH
in to disarm). Replaces `location-locker` + `nightlock` with one signed Swift binary. Installs **disarmed**.

```bash
sudo ./install.sh                 # build (or deploy prebuilt) → sign → install → load. DISARMED.
demonlock scan                    # walk the floor, capture AP hardware addresses (no sudo)
demonlock zones                   # draw/name zones on a map (optional; add=admin, delete=free)
sudo demonlock setpolicy '...'    # set the allow-condition
demonlock status                  # see exactly how it evaluates right now
sudo demonlock arm                # enforcement on
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
| `Settings.swift` · `State.swift` · `Zones.swift` | settings.json, the published `StateSnapshot`/`FeedPayload`/`EvalNode` types + small root files, zone model (circle/polygon, ray-cast) |
| `Policy.swift` | tokenizer → parser → three-valued evaluator → validator (`_policytest` = unit tests) |
| `Feed.swift` | cdhash-authenticated socket server (root) + sender (agent) |
| `Sensors.swift` · `Wifi.swift` | agent CoreLocation + CoreWLAN BSSID feed; root-side Wi‑Fi keep-on |
| `Enforcerd.swift` | the root daemon: poll loop, state machine, lockout (force-kill GUI) |
| `Agent.swift` · `ZonesUI.swift` | status/countdown panel + menubar; the `zones` map program |
| `Commands.swift` | `status`/`setpolicy`/`arm`/`disarm`/`snoozetonight`/`perm-ask`/`_zonedel` |
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
3. Seeds `/Library/Application Support/Demonlock/` defaults *only if absent* (`enforcedUser`=
   `$SUDO_USER`, `wifiDevice` auto-detected; `armed=0` ⇒ **installs disarmed**).
4. Installs both plists; writes `/etc/sudoers.d/demonlock` granting passwordless `_zonedel` only.
5. `bootstrap`s `enforcerd` into `system` and `agent` into `gui/$SUDO_UID`; runs `perm-ask` (the
   Location grant — one click, once per machine).

## Post-install layout & permissions

| Path | Owner:Group | Mode | What |
|---|---|---|---|
| `/Applications/Demonlock.app` | root:wheel | 755 | the signed binary (both roles) |
| `/usr/local/bin/demonlock` | root:wheel | 755 | CLI wrapper → app binary |
| `/Library/LaunchDaemons/com.demonlock.enforcerd.plist` | root:wheel | 644 | root daemon (RunAtLoad+KeepAlive) |
| `/Library/LaunchAgents/com.demonlock.agent.plist` | root:wheel | 644 | GUI agent (RunAtLoad+KeepAlive) |
| `…/Demonlock/policy.txt` `zones.json` `settings.json` `armed` `snooze` `state.json` | root:wheel | 644 | config + state — world-readable so `status` works, **root-only writable = the lock** |
| `…/Demonlock/logs/enforcerd.log` | root:wheel | 644 | daemon log |
| `/etc/sudoers.d/demonlock` | root:wheel | 440 | passwordless `demonlock _zonedel *` only (delete tightens) |
| `/var/run/demonlock.sock` | root | 0666 | sensor feed — identity *verified by cdhash*, not access-gated |
| `~/Library/Logs/AllConditionalLocker/agent.log` (or `/tmp/demonlock-agent.log`) | you | 644 | agent log |

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
- **Zone changes are asymmetric by privilege.** Adding a zone *loosens* policy → the map UI
  escalates the write via the admin prompt. Deleting *tightens* → passwordless via the narrow
  `_zonedel` sudoers grant (survives you removing your admin rights).
- **Signing.** Developer ID + secure timestamp ⇒ runs on any Mac and stays valid after the cert
  expires; ad-hoc fallback is fully sufficient for the cdhash-trust + hardened-runtime model.

**Residual holes (honest):** OS-level location spoofing needs sudo (disable SIP / attach a
debugger to the hardened agent / tamper the signed app) — all blocked by a no-admin posture;
physical RF BSSID spoofing is exotic but possible. SSIDs are unauthenticated, which is why the
Wi‑Fi check pins BSSIDs.

## Commands & settings

User (no sudo): `status` · `zones` (`view-zones`/`edit-zones` alias it) · `scan` · `perm-ask` ·
`help`. Sudo: `setpolicy` · `arm` · `disarm` · `snoozetonight` (stands down until the next
`snoozeHHMM`, default 05:00, then auto-clears; `arm` clears an active snooze). Settings live in
`settings.json` (`pollSeconds`, `countdownSeconds`, `snoozeHHMM`, `graceSeconds`, `maxAccuracyMeters`,
`scanSeconds`, `scanWindowSeconds`, `enforcedUser` [username **or** uid — the lockout target],
`wifiKeepOn`, `wifiDevice`). There is deliberately **no fix-age knob** and no startup-grace knob — a
held fix is valid while it keeps being confirmed, never judged by raw age. See `MODEL.md`.

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
