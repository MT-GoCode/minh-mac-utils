# multistreamviewer: durability

**Date:** 2026-09-13 · **Status:** v2 — adversarial pass folded (14 findings)

## Problem

Two reported failures:

1. **Not durable across boots/crashes.** Install launches MSV once via `open`; nothing relaunches
   it at login or after a crash. When it's gone, native ⌘⇥ returns (annoying but visible).
2. **Worse: alive but dead.** Over time, "things get closed" and MSV keeps **consuming** ⌘⇥ (and
   the other keys it taps) while doing nothing. Root causes verified in source:
   - **Empty scope swallows ⌘⇥** (`Hotkeys.swift:96-101` consumes tab unconditionally, then
     `Switcher.open()` finds `switcherScope()` empty and just returns — key eaten, no HUD). This
     is exactly "all the current group's windows got closed over time."
   - **The collapse guard wedges forever** (`Engine.swift:251-255`): a degraded window list hits
     `return` *before* `lastRawCount` is updated, so if the list stays small — permission flap
     after a re-sign, **or a genuine mass-close like quitting a many-windowed app** — every
     subsequent tick is skipped indefinitely: no reconciliation, no `Switcher.maintainTick()`
     (so the missed-⌘-release rescue dies too), stale candidates, dead commits.
   - **A created-then-dead tap is never detected.** The 1 s retry (`Menu.swift:34-39`) only fires
     while `tap == nil`; `alive` is just `tap != nil`, so a tap invalidated after creation
     (Accessibility revoked, port death) is invisible — keys dead or eaten, no ⚠ in the menu.

## Design — four small fixes + one diagnostic

### 1. LaunchAgent: start at login, restart on crash

`/Library/LaunchAgents/com.minh.multistreamviewer.agent.plist` (root-owned, matching blockrem's
agent):

```
Label            com.minh.multistreamviewer.agent
ProgramArguments /Applications/multistreamviewer.app/Contents/MacOS/multistreamviewer run
RunAtLoad        true
KeepAlive        { SuccessfulExit = false }
LimitLoadToSessionType  Aqua
ProcessType      Interactive
ThrottleInterval 30
```

**Exit-code contract (finding #1 — BLOCKER in v1):**

- **flock conflict → exit 1** (v1 said exit 0 — that would make launchd record a *successful*
  exit at the first upgrade install, never respawn, and MSV silently dies when the orphaned old
  instance quits). With exit 1, launchd retries every ThrottleInterval and wins the lock the
  moment the old instance is gone — self-healing, mild log noise.
- **Install kills the old instance first**: `install.sh` gains `pkill -x multistreamviewer`
  before deploy (the current flow `rm -rf`s the bundle out from under a running copy anyway),
  then deploys, then bootstraps the agent — so the normal upgrade path never even hits the flock
  race.
- **SIGTERM/SIGINT/SIGHUP handlers exit 1, not 0** (finding #3: today `Engine.swift:55-64` exits
  0 on TERM, so a stray `pkill` or another tool's cleanup would count as "successful" and stay
  dead until next login). Handlers still clear the Karabiner gate first. At logout the gui
  domain is torn down regardless of exit code, so logout stays clean. The **only** deliberate
  way to stay quit is menu → Quit (`NSApp.terminate`, exit 0).
- `install.sh`: ship the plist in `install/`, deploy via the existing
  `dl_install_launchd <plist> agent`, replacing the `post_install` `open` — then **hard-verify**
  with `launchctl print gui/<uid>/com.minh.multistreamviewer.agent` and fail the install if it
  isn't loaded (finding #12: install-lib swallows all launchctl errors, e.g. installing over SSH
  with no console session would otherwise print ✓ and do nothing). `uninstall.sh`:
  `launchctl bootout gui/<uid>/…agent` + remove the plist.
- MSV stays a demonlock spare (unchanged), so lockouts still don't close it.

### 2. Empty scope → fall back to all windows (decided with user)

If the scope-filtered list is empty, the switcher offers **all on-screen windows** (ordered
front-window-first, then priority rank, app, id). Picking one makes its group current via the
existing focus-follow, which self-heals the "current group is a ghost town" state.

**The fallback decision is frozen at `open()`** (finding #4): `Switcher.open()` records
`(scopeID, fellBack)`; while the HUD is up, `maintainTick` filters candidates **against that
frozen scope** — in fallback mode it drops only windows that actually closed, never re-derives
the scope. Without freezing, one engine tick after opening (a new window adopted into the
current group, or focus-follow moving `currentID`) would snap `switcherScope()` back to a
1-window group and prune the whole fallback list mid-⌘-hold, collapsing the HUD under the
user's fingers. `open()`'s empty-candidates early-out stays as the final safety net — with the
fallback it's reachable only when **nothing is on-screen at all** (everything minimized/hidden
still eats the key by design — finding #13 noted, accepted).

### 3. Un-wedge the collapse guard

Keep the guard (a one-tick blip must still be ignored) but give it a deadline — **which only
counts while the session is active** (finding #2 — BLOCKER in v1: the window list also degrades
for the whole time the session is off-console — screen lock, fast user switch — which routinely
exceeds any deadline; accepting that "reality" would mark every window missing, prune all
assignments after 2 ticks, and dump every tag into one group on unlock. Total tag loss on every
lock ≥ 11 s.):

- Subscribe to `NSWorkspace.sessionDidResignActiveNotification` /
  `sessionDidBecomeActiveNotification`; on resign **and** on become-active, extend `graceUntil`
  (same 3 s treatment `didWake` already gets, `Engine.swift:51-54`). While in grace or
  off-console, the collapse clock does not run.
- First collapsed tick (session active): record `collapsedSince = now`, skip as today.
- Collapsed for **> 10 s of active session**: log `accepting collapsed window list (N → M)`, set
  `lastRawCount = raw.count`, clear `collapsedSince`, process normally — a genuine mass-close
  becomes reality within ~10 s instead of wedging forever.
- On skipped ticks, run **only the stuck-⌘ rescue** — the `flagsState` check at
  `Switcher.swift:101-103` — *not* the full `maintainTick` reconcile and not `Overlay.refresh`
  (finding #5: reconciling candidates against the degraded snapshot would close the switcher on
  the very blip the guard exists to ignore). Factor the rescue into its own method.

### 4. Tap watchdog: `Hotkeys.ensureAlive()`

**One caller** — the existing 1 s timer in `AppDelegate` (finding #6: v1 also called it from
`Engine.tick`; dual cadence was creep and, with Accessibility revoked, ~3 recreate attempts +
log lines per second forever):

```
ensureAlive():
    if tap == nil                          → throttled start()        (create attempt ≤ 1/5 s)
    else if !CFMachPortIsValid(tap) or tap disabled on TWO consecutive checks
                                           → invalidate; tap = nil; throttled start()
    on state transition                    → NSLog once; karabinerVar(0) only if !Switcher.isOpen
```

- **Two consecutive disabled observations** before recreating (finding #7: after
  `tapDisabledByTimeout` there's a real window where the in-callback re-enable hasn't run yet;
  one sample there would tear down a tap that was about to self-heal).
- Recreate attempts and their logs throttled to once per 5 s while failing.
- Karabiner gate cleared on recreation only when the switcher isn't open (finding #10: if the
  tap dies mid-switch the gate is legitimately 1; the flagsState rescue closes it properly).
- `alive` becomes "tap exists ∧ passed its last health check", so the menu ⚠ finally shows for
  dead-but-non-nil taps too.

### 5. `multistreamviewer status` — make "alive but dead" diagnosable

A **separate 30 s main-runloop timer** (not the engine tick — the tick is exactly what can
wedge) writes `~/Library/Application Support/multistreamviewer/health.json`:
`{ updatedEpoch, lastTickEpoch, tapAlive, windowCount, groupCount, currentGroup }`. New CLI verb
`status` (runs in the CLI process, no permissions): process check via `pgrep -f` on the full
`/Applications/...` binary path **excluding its own pid** (finding #8: bare `pgrep -x` matches
the status process itself) + read health.json → one of `not running` /
`running, tap alive, N windows in M desktops` / `running but tap DEAD — check Accessibility` /
`running but heartbeat stale (hung?)`. Stale threshold **90 s** (3× cadence; a just-woken Mac
briefly reads stale — say so in the output). `lastTickEpoch` vs `updatedEpoch` distinguishes
"engine stopped ticking" from "whole main thread hung."

## Not doing (YAGNI)

- No root daemon / un-quittable-ness — MSV is a convenience, not a commitment device.
- No tag persistence across reboots (existing boot-fingerprint design stands).
- No SMAppService migration; plain LaunchAgent matches every sibling tool.
- No fallback to minimized/hidden windows (native ⌘⇥-style unminimize is out of scope).
- No second ensureAlive cadence; no change to overlay logic or reconciliation cadence.

## Tests

MSV has no test target; these are logic-level checks + a scripted live pass:

1. Extract two pure functions and cover with a tiny XCTest target (no package split — the file
   imports no AppKit): `collapseDecision(lastCount, newCount, collapsedSince, sessionActive,
   now) -> (skip, acceptReality, newSince)` and the frozen-scope candidate filter
   `(candidates, liveIDs, frozenScope, fellBack)`. Cases: one-tick blip skipped · >10 s active
   collapse accepted · lock-screen collapse never accepted (sessionActive false) · fallback list
   survives a window appearing in the original group · closed windows still pruned in fallback.
   <!-- ponytail: only these two funcs unit-tested; full target split if MSV ever grows real tests -->
2. Live verification script (run at install time, on the Mac):
   - `launchctl print gui/<uid>/com.minh.multistreamviewer.agent` shows the job loaded (this is
     also the install script's own hard gate)
   - `kill -9` the app → relaunched (**wait 35 s** — ThrottleInterval, finding #11); plain
     `kill` (TERM) → also relaunched; menu Quit → stays quit; relogin → back
   - close every window in the current desktop → ⌘⇥ opens the all-windows switcher (fallback)
   - lock screen ≥ 30 s, unlock → **tags intact** (the #2 regression test)
   - `multistreamviewer status` correct in: running / killed / tap-dead (revoke Accessibility)
     states

## Files touched

`main.swift` (flock exit 1, `status` verb) · `Hotkeys.swift` (`ensureAlive`, throttle,
two-strike) · `Engine.swift` (frozen-scope fallback, collapse deadline + session gate,
rescue-only skips, TERM exit 1) · `Switcher.swift` (frozen scope in open/maintainTick, rescue
split) · `Menu.swift` (timer → ensureAlive, ⚠ from health) · `install.sh` (pre-kill, plist,
hard verify) / `uninstall.sh` + new `install/com.minh.multistreamviewer.agent.plist` ·
`README.md`. Install rides the same gate-window sudo session as the demonlock reinstall.
