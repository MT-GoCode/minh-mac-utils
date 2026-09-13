# multistreamviewer: durability

**Date:** 2026-09-13 · **Status:** draft for review

## Problem

Two reported failures:

1. **Not durable across boots/crashes.** Install launches MSV once via `open`; nothing relaunches
   it at login or after a crash. When it's gone, native ⌘⇥ returns (annoying but visible).
2. **Worse: alive but dead.** Over time, "things get closed" and MSV keeps **consuming** ⌘⇥ (and
   the other keys it taps) while doing nothing. Root causes found in source:
   - **Empty scope swallows ⌘⇥** (`Hotkeys.handle` consumes tab unconditionally, then
     `Switcher.open()` finds `switcherScope()` empty and just returns — key eaten, no HUD). This
     is exactly "all the current group's windows got closed over time."
   - **The collapse guard wedges forever** (`Engine.tick`): a degraded window list
     (`raw.count` collapse — permission flap after a re-sign/update, mid-display-reconfig) hits
     `return` *before* `lastRawCount` is updated, so if the list stays small, **every subsequent
     tick is skipped indefinitely**: no reconciliation, no `Switcher.maintainTick()` (so the
     missed-⌘-release rescue dies too), stale candidates, dead commits.
   - **A created-then-dead tap is never detected.** `Hotkeys.start()` is retried every 1 s only
     while `tap == nil`. If the tap was created and later invalidated (Accessibility revoked then
     re-granted, tap port death), `tapEnable` fails silently and nothing notices; depending on
     order, keys are either eaten or the gesture is just dead with a stale ⚠-less menu title.

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

- `SuccessfulExit=false`: crashes and kills relaunch; a **deliberate Quit** (menu → Quit, exit 0)
  stays quit until next login — durable without being demonlock.
- Single-instance flock in `main.swift`: on conflict, change `die` (exit 1) to a message +
  **exit 0**, so a manually-launched duplicate doesn't make launchd fight it.
- `install.sh`: ship the plist in `install/`, deploy via the existing
  `dl_install_launchd <plist> agent` (already handles gui-domain bootstrap), replacing the
  `post_install` `open`. `uninstall.sh`: `launchctl bootout gui/<uid>/…agent` + remove the plist.
- MSV stays a demonlock spare (unchanged), so lockouts still don't close it.

### 2. Empty scope → fall back to all windows (decided with user)

In `Engine.switcherScope()`: if the scope-filtered list is empty, return **all on-screen windows**
(same sort: MRU of the current group won't apply — order by front-window-first, then priority
rank, app, id). ⌘⇥ then always shows something committable; picking a window makes its group
current via the existing focus-follow, which self-heals the "current group is a ghost town" state.
`Switcher.open()`'s empty-candidates early-out stays as the final safety net (e.g. genuinely zero
windows) — but it must **not** have consumed the keypress for nothing more than it already does;
with the fallback, that branch becomes reachable only when there is truly nothing to switch to.

### 3. Un-wedge the collapse guard

Keep the guard (a one-tick blip must still be ignored) but give it a deadline:

- First collapsed tick: record `collapsedSince = now`, skip reconciliation as today.
- Collapsed for **> 10 s**: log `accepting collapsed window list (N → M)`, set
  `lastRawCount = raw.count`, clear `collapsedSince`, and process the tick normally — reality wins.
- On every skipped tick, still run `Switcher.maintainTick()` + `Overlay.refresh()` (they only need
  the ability to close/commit, and the stuck-⌘ rescue must never be paused).

### 4. Tap watchdog: `Hotkeys.ensureAlive()`

Replace the body of the 1 s retry in `AppDelegate` (and add a call from `Engine.tick`— cheap):

```
ensureAlive():
    if tap == nil                  → start()                      (existing behavior)
    else if !CFMachPortIsValid(tap) or !CGEvent.tapIsEnabled(tap)
                                   → invalidate + tap = nil + start()   (recreate)
    on any transition              → NSLog once + karabinerVar(0)  (never leave the gate stuck)
```

`tapIsEnabled` returning false outside our own disabled window means the OS turned it off and the
re-enable-in-callback never ran (dead port) — recreation is the only fix. The existing
`tapDisabledByTimeout` in-callback re-enable stays. Menu ⚠ indicator keeps working via `alive`.

### 5. `multistreamviewer status` — make "alive but dead" diagnosable

The app writes `~/Library/Application Support/multistreamviewer/health.json` every 30 s (and on
tap transitions): `{ updatedEpoch, tapAlive, windowCount, groupCount, currentGroup }`. New CLI
verb `status` (runs in the CLI process, no permissions needed): pgrep for the app + read
health.json → one of `not running` / `running, tap alive, N windows in M desktops` /
`running but tap DEAD — check Accessibility` / `running but stale heartbeat (wedged?)`. This is
what turns the next "it does nothing" report into a 5-second diagnosis.

## Not doing (YAGNI)

- No root daemon / un-quittable-ness — MSV is a convenience, not a commitment device.
- No tag persistence across reboots (existing boot-fingerprint design stands).
- No SMAppService migration; plain LaunchAgent matches every sibling tool.
- No change to ⌘⌥ overlay logic, engine reconciliation cadence, or Karabiner integration beyond
  clearing the gate on tap recreation.

## Tests

MSV has no test target; these are logic-level checks + a scripted live pass:

1. Extract the collapse-deadline decision into a pure function
   (`shouldSkipTick(lastCount, newCount, collapsedSince, now) -> (skip, newState)`) and the
   fallback scope into a pure filter; cover both with a tiny XCTest target (same
   `Sources/…Core` split blockrem/demonlock use is **not** needed — these two functions can live
   in a file with no AppKit imports).
   <!-- ponytail: only these two funcs unit-tested; full target split if MSV ever grows real tests -->
2. Live verification script (run at install time, on the Mac):
   - `launchctl print gui/<uid>/com.minh.multistreamviewer.agent` shows the job loaded
   - `kill -9` the app → relaunched within throttle window; menu Quit → stays quit; relogin →
     back
   - close every window in the current desktop → ⌘⇥ still opens the switcher (fallback)
   - `multistreamviewer status` correct in: running / killed / tap-dead (revoke Accessibility)
     states

## Files touched

`main.swift` (flock exit code, `status` verb) · `Hotkeys.swift` (`ensureAlive`) · `Engine.swift`
(fallback scope, collapse deadline, maintainTick-on-skip, health writes) · `Menu.swift` (retry
loop → ensureAlive) · `install.sh` / `uninstall.sh` + new `install/com.minh.multistreamviewer.agent.plist`
· `README.md`. Install rides the same gate-window sudo session as the demonlock reinstall.
