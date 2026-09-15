# MacUtilsCore + one-shot install — commonization design

**Date:** 2026-09-15 · **Status:** v1 draft · **Author of the tools:** Minh Trinh

## Goal

One home for every piece of plumbing the discipline tools currently carry as private copies, and a
fresh Mac that sets itself up by running one script. **Zero behavior change** to any CLI command,
delay, enforcement decision, file format, or on-disk path — the acceptance test is "every existing
test still passes and every status output is byte-identical", with the few deliberate cosmetic
exceptions listed in §Deliberate changes.

Two halves:

1. **`MacUtilsCore/`** — a Foundation-only local SwiftPM library at the repo root, depended on by
   demonlock, nextdns-sidecar, and blockrem via `.package(path: "../MacUtilsCore")`. Statically
   linked, so signing, bundles, and installers are untouched. Kills the sidecar's vendored copies
   and the `VendorSyncTests` byte-identity guard.
2. **Installer commonization + `install-all.sh`** — the four bespoke installers adopt the shared
   `scripts/install-lib.sh` they currently re-implement, the lib gains the four helpers it's missing,
   every uninstaller collapses onto one, and a top-level driver runs the whole fresh-machine setup
   with the human-only steps batched at the end.

Out of scope (deliberately): `multistreamviewer` (nothing overlaps beyond a 2-line AX prompt),
`stayup` (150 lines, two `Process()` calls — a package dependency costs more than it saves),
`remote-agent-connector` (single-file `swiftc` build; it is the SSH lifeline and stays untouched),
`wtalk` (python), `browser-blitz` (node). TCC-prompt helpers (need ApplicationServices, 2 lines
each), `parseFlags`, a `Paths` builder, the daemon run-loop — surveyed, not worth an abstraction.

## Part 1 — MacUtilsCore

### Package

```
MacUtilsCore/
  Package.swift            // swift-tools 5.9, macOS 13, one library target + one test target
  README.md                // what lives here, the "edit here, never copy" rule, author
  Sources/MacUtilsCore/
    MarkerIO.swift         // moved verbatim from demonlock (public)
    DelayQueue.swift       // moved verbatim (public: DelayQueue, Item, Outcome, Row, QStatus, QStateStore, Failure)
    DelayQueueLegacy.swift // Legacy.keyOnlyMap only (the sidecar's migration; demonlock's own decoders stay)
    JSON.swift             // loadJSON, saveJSON(mode:pretty:), lenient KeyedDecodingContainer helper
    Proc.swift             // Proc.run(quiet:), capture, captureStatus
    Users.swift            // resolveUID(String), userName(for:), consoleUID()
    Log.swift              // logStderr, nowEpoch, errOut, fail, isRoot, requireRoot
    TimeSpec.swift         // parseDuration, weekday(letter), letters(for:), validHHMM,
                           //   nextTimeOfDay, parseInstant(keywords:), fmtLeft, fmtWhen (cached formatters)
    EpochFile.swift        // the "epoch or null" scalar file (demonlock + blockrem SnoozeStore)
    Clamp.swift            // ClosedRange<Double>.clamp
    Launchd.swift          // bootstrap/kickstart/isLoaded + pgrepRunning
    Markers.swift          // dropMarker(path, payload) -> Bool (CLI side), queueStatusLines(...)
  Tests/MacUtilsCoreTests/
    MarkerIOTests.swift    // moved from demonlock
    DelayQueueTests.swift  // moved from demonlock
    MigrationTests.swift   // the keyOnlyMap cases moved; demonlock keeps its app-specific ones
    TimeSpecTests.swift    // new: both keywords, both error paths, nextTimeOfDay edge cases
    JSONUsersTests.swift   // new: lenient decode, saveJSON mode, resolveUID
```

`Package.swift` carries the author: `// MacUtilsCore — shared plumbing for Minh Trinh's macOS
self-discipline tools (minh-mac-utils). Edit here; nothing is vendored.` README repeats it.

Everything exported is `public`. Types that today are `internal` in `DemonlockCore` get `public`
+ `public init` where a caller constructs them (Item, Outcome, QStatus, Row, Failure).

### What moves, per consumer (all zero-change unless marked)

| Concept | demonlock | nextdns-sidecar | blockrem |
|---|---|---|---|
| MarkerIO, DelayQueue, keyOnlyMap | delete local copies | delete vendored copies + `DelayQueueSupport`'s shims + the VENDORED headers | — |
| loadJSON/saveJSON/nowEpoch | delete from `Util.swift` | delete from `DelayQueueSupport` | `ScheduleStore`, `ActiveStore`, `SessionStore`, `Settings.load` rewritten onto them |
| logStderr | delete; `Enforcer.log` stays (it prints to stdout — kept) | `logLine` becomes a one-line wrapper over `logStderr` — **format change, see §Deliberate** | `Enforcer.log` stays |
| Proc | delete; `run` keeps inherit-stdio via `quiet: false` default | delete; sidecar's `Proc` was silent → call sites pass `quiet: true` via a 3-line local `enum Proc` shim that forwards to core | delete |
| resolveUID / userName(for:) / consoleUID | `Settings.enforcedUID` → one-liner; the three getpwuid→name copies (`enforcedUserName`, `Enforcerd.userName`, `usernameForUID`) collapse onto `userName(for:)`; `Enforcerd.consoleUser` → `consoleUID` | `Config.enforcedUID` → one-liner | `Settings.enforcedUID` → one-liner; `Util.consoleUID` deleted |
| fail/errOut/isRoot/requireRoot | private `fail`/`requireRoot` deleted, messages stay at call sites | `fail` + four inline `geteuid()` guards → `requireRoot` | `fail`/`errOut` deleted |
| TimeSpec | `parseDuration`, `weekday`, `nextWeekdayHHMM`, `fmtLeft`, `fmtWhen` deleted; `parseTarget` = `try parseInstant(s, keywords: ["until"], from:)` mapping `ParseError` → its `TimeError`; `nextHHMM(String)` deleted — its two callers use `nextTimeOfDay(hhmm:weekday:nil)` (**junk-input edge, see §Deliberate**) | `parseDuration` free function deleted | `parseDuration`, `weekday(for:)`, `letters`, `validHHMM`, `nextTimeOfDay` deleted; `parseWhen` = `Result(catching: parseInstant(s, keywords: ["at"]))`; `parseWeekly`, `parseFirstOn`, `hhmmString` stay (app-specific) |
| clamp | `Bounds.clamp` → `range.clamp(v)` | same | — |
| lenient decode | `Settings.init(from:)` shrinks | `Config.init(from:)` shrinks | `Settings.init(from:)` shrinks |
| EpochFile | `SnoozeStore` → 2-line wrapper | — | `SnoozeStore` → 2-line wrapper |
| Launchd | watchdog's two `launchctl` calls + `pgrep` | `Lockdown`'s `launchctl print` | watchdog's calls |
| dropMarker | `dropDelayMarker` → wrapper adding its fail message | `dropMarker` → wrapper | — |
| queueStatusLines | moved; `printQueueStatus` calls it | `cmdFuture` adopts it — **layout change, see §Deliberate** | — |

`parseInstant` grammar (superset of both today's parsers, keyword-parameterised):
`"for <dur>"` → `now + parseDuration`; `"<kw> <HHMM>"` / `"<kw> <D>HHMM"` → `nextTimeOfDay`.
Rejects: bad duration, non-4-digit or invalid HHMM, unknown day letter, nil from the calendar
(fail closed — never a fallback minute). Error messages are built from the keyword so each app's
text stays exactly what it prints today (both current strings are tested).

`nextTimeOfDay(hhmm:weekday:from:) -> Date?` is blockrem's loop (0…8 days, strictly future,
optional weekday filter) returning nil instead of `now+60` — blockrem's only caller already can't
hit nil (a valid HHMM always resolves within 8 days); demonlock's `parseTarget` throws on nil as it
does today via `nextWeekdayHHMM`.

`fmtWhen(epoch, format)` keeps a per-format `DateFormatter` cache (formatters are expensive and
every call site allocates one today). Output identical for identical format strings.

### Deliberate changes (cosmetic, listed so they're reviewed, not discovered)

1. **nextdns-sidecar log prefix**: `2026-09-15T10:00:00 msg` → `[2026-09-15 10:00:00] msg`
   (demonlock/blockrem format). Nothing parses that log. `nextdns-sidecar status` reads
   `pf-state.json`, not the log.
2. **`nextdns-sidecar domains future` layout** adopts demonlock's `queueStatusLines`: rows get a
   number and the `last landed` line; same data.
3. **demonlock `nextHHMM("junk")`** used to silently mean 05:00 tomorrow; after: `parseTarget`
   already rejects non-4-digit input before reaching it, so no CLI path could observe this — the
   only change is that the helper no longer exists.
4. **`VendorSyncTests` deleted** — there is nothing left to keep in sync.

Everything else must be byte-identical: every `status` output, every log line in demonlock and
blockrem, every file on disk.

### Build / install implications

`swift build` inside each tool dir resolves `../MacUtilsCore` from the repo checkout — the only
new requirement is that the repo is cloned whole (it always is). demonlock's committed prebuilt
`dist/` (the no-toolchain path) is unaffected. Each tool's `Package.swift` adds the path dependency
and the target dependency; nothing else in build/sign/deploy changes.

### Tests

- MacUtilsCore: the moved MarkerIO/DelayQueue/keyOnlyMap suites (unchanged bodies) + new TimeSpec
  (both keywords; `for`/`at`/`until`; invalid HHMM; `U0730` next-Sunday; nil-calendar fail-closed;
  `fmtLeft` boundaries; `fmtWhen` cache returns identical strings), JSON (lenient decode: missing
  key, wrong type; `saveJSON(mode:)` result mode), Users (`resolveUID("501")`, name, garbage → nil).
- demonlock: `DemonlockCoreTests` minus the moved files still green (`_policytest` 49/49 unchanged).
- blockrem: `_selftest` 78/78 unchanged — it exercises `parseWhen`/`parseDuration`/`parseWeekly`
  through blockrem's wrappers, which is exactly the regression net for the TimeSpec merge.
- **Golden-output check (the zero-regression gate):** before the change, capture on the Mac
  `demonlock status`, `demonlock delayzones`, `demonlock delay-set-policy --status`,
  `demonlock safe-apps show`, `demonlock snooze-preset show`, `demonlock password-lockbox show`,
  `demonlock admin-release-valve status`, `blockrem list`, `nextdns-sidecar domains future`,
  `nextdns-sidecar networklockdown status`; after install, diff — only timestamps/countdowns and the
  two listed sidecar cosmetics may differ.

## Part 2 — installers and one-shot setup

### install-lib additions (`scripts/install-lib.sh`)

| Helper | Replaces |
|---|---|
| `dl_pick_bundle <app> <build.sh>` — Dev-ID/dist/build ladder: Dev ID in keychain → build; no CLT → committed `dist/` if present; else fail with the CLT hint | 3 inline copies (demonlock, blockrem, wtalk-variant) |
| `dl_stop <label> <procname> [agent\|daemon]` — bootout → pkill → sleep, **always before deploy** | MSV/wtalk/rac inline; stayup didn't stop at all (overwrote a running bundle) |
| `dl_verify_launchd <label> <agent\|daemon>` — `launchctl print`, non-zero with a "no console session — log in and run …" hint | MSV's inline hard-verify; `dl_install_launchd` now calls it and **returns non-zero** instead of swallowing |
| `dl_install_launchd … [--as-user] [--sed 'a=b' …]` | wtalk's user-context bootstrap; demonlock/blockrem's agent-log-path sed |
| `dl_install_cli_wrapper <name> <exe>` | the heredoc wrapper in demonlock/blockrem/wtalk (kept as wrapper, not symlink — demonlock's sudoers grant references it) |
| `dl_codesign <app> [entitlements]` — ladder + `--options runtime --timestamp` everywhere | 5 build.sh copies with inconsistent flags |
| `dl_uninstall_common <app> <bundle> <cli…> <label…>` + `dl_unregister_spare <bid>` | 7 hand-rolled uninstallers; the python3 JSON edit duplicated in two of them |
| `dl_user_launchd <label> <plist-body>` — no-root LaunchAgent writer + bootstrap + verify | browser-blitz, paseo |

Then demonlock, blockrem, wtalk, rac `install.sh` become manifests + `provide_bundle` + a short
`post_install` (seed support dir, sudoers, spare), like MSV/stayup today. nextdns-sidecar keeps its
bespoke credential/profile flow but adopts `dl_require_root` (drops its accept-root-shell
exception — it's the only installer that does, and the README says never run from a root shell),
`dl_install_launchd`, `dl_verify_launchd`. Every installer: `set -uo pipefail` + explicit
`|| exit 1` on the steps that matter (the manifest style), no silent `|| true` on launchd loads.

### `install-all.sh` (repo root, run as the user, calls sudo itself)

```
./install-all.sh [--from <phase>] [--only <tool>] [--no-secrets]
 0 preflight   xcode-select -p · brew · uv · ffmpeg · node/npm · jq · python3 · Karabiner ·
               ~/Downloads/NextDNS-*.mobileconfig — prints ONE fix-it block (the exact brew/curl
               lines) and exits 1 if anything is missing. SUDO_USER≠root. Console session present.
 1 secrets     ONE tty pass, skipped per-file when already filled: NextDNS profile id + API key
               (→ 0600 temp handed to the sidecar via --profile/--key-file), Gemini key
               (→ ~/.wtalk/.env), rac MIDDLEMAN/MACHINE_NAME (→ ~/.remote-agent-connector/config)
 2 identity    bash signing-ladder.sh once as the user → export CODESIGN_IDENTITY (one keychain /
               smartcard prompt instead of five; creates the self-signed cert before any build)
 3 root        sudo -v; demonlock → blockrem → multistreamviewer → stayup → remote-agent-connector
               → wtalk (setup.sh as user, then install) → nextdns-sidecar (all flags passed; no tty
               reads). demonlock is first because every other installer registers as its spare.
 4 user        browser-blitz install, setup-paseo-daemon (if Paseo present), then
               sudo demonlock/register-recommended-spares.sh
 5 verify      launchctl print for every label (system + gui), each tool's `status`, one table
 6 checklist   opens every TCC pane and both mobileconfigs, then prints the numbered human list:
               Location Always + Accessibility (demonlock) · Accessibility (blockrem, MSV, wtalk) ·
               Screen Recording (MSV, rac) · Microphone (wtalk) · approve 2 profiles · Karabiner
               key → wtalk toggle · Chrome Load-unpacked · rac setup · then the arm commands and
               `demonlock nosudo` (never automated — README §3).
```

Re-runnable end to end: every installer is already idempotent; the driver skips secrets that exist,
and `--only`/`--from` resume a failed phase. Exit code = first failing phase. `uninstall-all.sh`
mirrors the README's uninstall block using `dl_uninstall_common`.

### Tests for Part 2

- `bash -n` on every script; `shellcheck` clean on the lib and driver (warnings allowed only where
  annotated).
- Live: reinstall demonlock, blockrem, nextdns-sidecar, multistreamviewer, stayup, wtalk on the
  Mac through their new manifests under the current grant; the golden-output diff above; `launchctl
  print` for all labels; `demonlock test-lockout` still lists all spares.
- `install-all.sh --from verify` on the Mac (phases 5–6) must pass; phases 0–4 are exercised by
  `--only <tool>` for each tool. A true fresh-machine run can't be tested here — the design
  compensates by making each phase a function that is also what `--only` runs.

## Rollout

1. Part 1 (core + three consumers), tests green locally on the Mac, review round.
2. Part 2 (lib + manifests + driver), review round.
3. Reinstall the six tools under the live grant, golden diff, push. README index updated: the
   "no top-level driver" paragraph is replaced by `install-all.sh`.
