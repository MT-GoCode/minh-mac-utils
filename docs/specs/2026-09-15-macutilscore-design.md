# MacUtilsCore + one-shot install — commonization design

**Date:** 2026-09-15 · **Status:** v3 — two adversarial passes + two confirm passes folded (17 + 40 + 4 + 7 findings) ·
**Author of the tools:** Minh Trinh

## Goal

One home for the plumbing the discipline tools carry as private copies, and a fresh Mac that sets
itself up by running one script. **Zero behavior change** to any CLI command, delay, enforcement
decision, file format, or on-disk path. Acceptance = every existing test green + the golden-output
gate (§Gate) byte-identical, with only the items in §Deliberate changes allowed to differ.

Two halves:

1. **`MacUtilsCore/`** — a Foundation-only local SwiftPM library at the repo root, depended on by
   demonlock, nextdns-sidecar, and blockrem via `.package(path: "../MacUtilsCore")`. Statically
   linked: signing, bundles, installers untouched. Kills the sidecar's vendored copies and the
   `VendorSyncTests` byte-identity guard.
2. **Installer commonization + `install-all.sh`** — bespoke installers adopt the shared
   `scripts/install-lib.sh`, the lib gains the helpers it's missing, uninstallers collapse onto one,
   and a top-level driver runs the whole fresh-machine setup with human-only steps batched last.

Out of scope, deliberately: `multistreamviewer` (nothing overlaps beyond a 2-line AX prompt),
`stayup` (150 lines; a package dependency costs more than two `Process()` calls), the
`remote-agent-connector` *binary* (single-file `swiftc`, the SSH lifeline — untouched; its installer
is touched only where §Part 2 says), `wtalk` (python), `browser-blitz` (node). Surveyed and rejected
as not worth an abstraction: TCC-prompt helpers, `parseFlags`, a `Paths` builder, the daemon
run-loop, launchd/pgrep wrappers (two watchdogs with different semantics — `kickstart -k` vs not —
four one-liners are not an abstraction), `clamp` (one line, 20 call-site edits), the sidecar's
`future` layout (stays), `dropMarker` (**cannot** be shared: demonlock appends the payload as ONE
line — a multi-line policy must stay one request — while the sidecar splits on `\n` into N domain
rows; both already route through the shared `MarkerIO.append`, which is the real common piece).

## Part 1 — MacUtilsCore

### Package

```
MacUtilsCore/
  Package.swift            // swift-tools 5.9, macOS 13; library + test target
  README.md                // what lives here; the "edit here, nothing is vendored" rule; author
  Sources/MacUtilsCore/
    MarkerIO.swift         // verbatim from demonlock, `public`
    DelayQueue.swift       // verbatim, `public`
    DelayQueueLegacy.swift // `public enum Legacy { static func keyOnlyMap() }` — the sidecar's migration
    JSON.swift             // loadJSON, saveJSON(mode:pretty:), KeyedDecodingContainer.lenient(_:default:)
    Proc.swift             // Proc.run(_:_:quiet:) / capture / captureStatus
    Users.swift            // resolveUID(_:), userName(for:), consoleUID()
    Log.swift              // logStderr, nowEpoch, errOut, fail(_:), requireRoot(_ message:)
    TimeSpec.swift         // PRIMITIVES ONLY: parseDuration, weekday(_:), letters(for:), validHHMM,
                           //   nextTimeOfDay(hhmm:weekday:from:calendar:) -> Date?, fmtLeft, fmtWhen, ParseError
    EpochFile.swift        // read(path) -> Date? / write(_:to:) — the "epoch or null" scalar file
  Tests/MacUtilsCoreTests/
    MarkerIOTests.swift, DelayQueueTests.swift   // moved from demonlock, bodies unchanged
    MigrationTests.swift                          // only the keyOnlyMap cases move
    TimeSpecTests.swift                           // new — fixed America/Los_Angeles calendar
    JSONUsersTests.swift                          // new
```

`Package.swift` header: `// MacUtilsCore — shared plumbing for Minh Trinh's macOS self-discipline
tools (minh-mac-utils). Edit here; nothing is vendored anywhere.` README repeats the author line.
`.gitignore` gains `MacUtilsCore/.build/`.

### Public surface (compile-blocking if missed — enumerated)

`public` + `public init` with today's default arguments for: `DelayQueue.init(kind:store:
requestMarker:abortMarker:onFailure:payloadIsJSON:auditLog:)`, `DelayQueue.QStateStore.init(load:
save:)`, `DelayQueue.QState.init(pending:nextSeq:lastAppliedAt:recent:)` + `QState()`,
`DelayQueue.Item.init(payload:requestedAt:applyAt:seq:retries: = nil, nextRetryAt: = nil)`,
`Outcome.init`, `Row.init`, `QStatus.init`; `QStateStore.file(_:legacyDecode:)`, every `DelayQueue` instance method, all stored properties of
`Item`/`Outcome`/`QState`/`Row`/`QStatus` as `public var`, `QState.fixSeq()`, `DelayQueue.cap`,
`DelayQueue.maxLinesPerMarker`, every `MarkerIO` static, `Failure` (enum), `TimeSpec` + its statics,
`ParseError.init(message:)` (blockrem's verbatim `parseWhen` constructs it), `Legacy.keyOnlyMap`.
Anything `private` that `DelayQueue` uses internally stays private. Core's root gate is
`requireRoot(or:)` so it can't shadow demonlock's `requireRoot(_ cmd:)` template.

Imports are per-file in Swift: every source file that uses a core symbol gets its own
`import MacUtilsCore` (mechanical). Additionally `@_exported import MacUtilsCore` in
`DemonlockCore/Util.swift` so the `@testable import DemonlockCore` tests see the symbols — that line
does nothing for the two single-executable packages.

App-side additions to core types are **extensions, never same-named local types** (a module-local
`enum TimeSpec` would shadow the core one and break every call site): demonlock's `parseTarget`,
`TimeError`, `nextHHMM`-replacement live in `extension TimeSpec { }`; blockrem's `parseWhen`,
`parseWeekly`, `parseFirstOn`, `hhmmString` likewise; demonlock's app-specific migration decoders
in `extension Legacy { }`. Blockrem's top-level `ParseError` is deleted — core's (same shape,
`message`) replaces it.

### What moves, per consumer

| Concept | demonlock | nextdns-sidecar | blockrem |
|---|---|---|---|
| MarkerIO, DelayQueue, keyOnlyMap | delete local files; `Legacy` keeps `singleSlot`/`zonesDropSnapshot`/`safeApps` as an extension | delete vendored files + `DelayQueueSupport.swift` entirely | — |
| loadJSON / saveJSON / nowEpoch | delete from `Util.swift` | delete from `Core.swift`/`DelayQueueSupport` | `ScheduleStore` → `saveJSON(pretty: true)` (today `[.prettyPrinted,.sortedKeys]`); `ActiveStore`, `SessionStore` → default (today `[.sortedKeys]`); `Settings.load` → `loadJSON ?? Settings()` |
| logStderr | delete; `Enforcer.log` **stays** (it prints to stdout — different sink) | `logLine` → `logStderr` — **format change, §Deliberate #1** | `Enforcer.log` → `logStderr` (byte-identical format + sink) |
| Proc | delete; `run` default `quiet: false` = today's inherit-stdio; `capture` stderr → `nullDevice` (§Deliberate #3) | delete; its ~12 `Proc.run` sites pass `quiet: true` (today's silence); `captureStatus` is core's | delete |
| resolveUID / userName(for:) / consoleUID | `Settings.enforcedUID` → one-liner; `enforcedUserName`, `Enforcerd.userName`, `usernameForUID` → `userName(for:)`; `Enforcerd.consoleUser` → `consoleUID()` and the local binding at `Enforcerd.swift:95` is renamed (`guard let cuid = consoleUID()`) | `Config.enforcedUID` → one-liner | `Settings.enforcedUID` → one-liner; `Util.consoleUID` deleted |
| fail / errOut / requireRoot | private `fail`/`requireRoot` deleted; `requireRoot("demonlock \(cmd): requires sudo — …")` keeps the exact text | `fail` deleted; the four `geteuid()` guards → `requireRoot("<their exact current text>")` | `fail`/`errOut` deleted |
| TimeSpec | delete `parseDuration`, `weekday`, `nextWeekdayHHMM`, `nextHHMM`, `fmtLeft`, `fmtWhen`; keep `parseTarget` + `TimeError` verbatim (same strings), now calling `nextTimeOfDay(hhmm:weekday:from:)` for both branches (`nextHHMM`'s `?? 500` junk default was dead: `parseTarget` rejects before it) | delete free `parseDuration` | delete `parseDuration`, `weekday(for:)` (→ `weekday(_:)`), `letters`, `validHHMM`, `nextTimeOfDay`; keep `parseWhen` verbatim (same strings) |
| lenient decode | `Settings.init(from:)` uses `c.lenient(.x, default: d.x)` | `Config.init(from:)` | `Settings.init(from:)` |
| EpochFile | `SnoozeStore` → 2-line wrapper | — | `SnoozeStore` → 2-line wrapper |

`nextTimeOfDay(hhmm:weekday:from:calendar: = .current) -> Date?`: blockrem's 0…8-day loop,
strictly future, optional weekday filter, **nil** instead of `now+60`. Blockrem's caller can't hit
nil (a valid HHMM resolves within 8 days); demonlock's `parseTarget` throws on nil exactly as it
did via `nextWeekdayHHMM`. Both today derive the candidate from day components + hh:mm with
`Calendar.current`, so DST behavior is identical; the `calendar:` parameter exists so tests pin
`America/Los_Angeles`.

`fmtWhen(epoch, format)` — **no formatter cache** (demonlock's header mandates "render in the
current tz"; a cached `DateFormatter` freezes the tz in a long-lived daemon). Same body as today.

### Deliberate changes (cosmetic; listed so they're reviewed, not discovered)

1. **nextdns-sidecar log prefix** `2026-09-15T10:00:00 msg` → `[2026-09-15 10:00:00] msg`.
   Nothing parses that log (`status` reads `pf-state.json`).
2. **`VendorSyncTests` deleted** — nothing left to keep in sync.
3. **`Proc.capture` stderr → `/dev/null`** in demonlock/blockrem (was an undrained `Pipe()`: a
   child writing >64 KiB to stderr would deadlock the daemon). Not observable — the pipe was never
   read. The sidecar already did this.

Everything else — every `status` output, every stderr message on bad input, every demonlock /
blockrem log line, every byte on disk — must be identical.

### Build / install implications

`swift build` inside each tool dir resolves `../MacUtilsCore` from the whole-repo checkout
(`install/build.sh` and the sidecar's `--package-path` both run there, as the user). Linking is
static; `codesign` on the bundle is unchanged. demonlock's committed prebuilt `dist/` is refreshed
(`--refresh-dist`) and committed at rollout so the no-toolchain path ships the same code.

## Part 2 — installers and one-shot setup

### install-lib additions (`scripts/install-lib.sh`)

| Helper | Semantics (pinned) |
|---|---|
| `dl_pick_bundle <app> <build.sh> [committed-dist]` | **Explicit rungs**: (1) CLT present → build (the ladder picks Dev ID → stable self-signed → ad-hoc); (2) no CLT + committed `dist/` present → deploy it; (3) neither → fail with the CLT hint. **Build always wins when a toolchain exists** — today's *automatic* "no Dev ID → prefer dist" rung is deleted (it installed a month-stale committed bundle on any no-Dev-ID machine). The README's Dev-ID-preservation workflow survives as an **explicit** `--prebuilt` flag (wtalk already has it): `sudo ./demonlock/install.sh --prebuilt` deploys the committed dist without building; README §Preserving is rewritten to say so. Explicit, never automatic. Never consumes a locally produced dist: blockrem/wtalk `build.sh` stop writing `dist/` unconditionally (demonlock's `--refresh-dist` gate everywhere). Never falls back to "any existing bundle" on build failure (today's `dl_swift_bundle` does; that path is removed). |
| `dl_stop <procname> [--label L --domain gui\|system] [--pre <fn>]` | pkill (+ bootout when a label is given), after an optional graceful `--pre` hook. Used **only** by the apps whose launchd job would respawn or that overwrite a running GUI app: MSV (`SuccessfulExit=false`), wtalk, stayup (label-less; today it `open`s a second instance every run), rac (`--pre` = its osascript quit + tunnel pkill, kept bespoke). demonlock/blockrem keep **deploy → bootout → bootstrap** (their daemons stay up through the deploy — no enforcement gap while armed). Invariant everywhere: **build before stop**. |
| `dl_verify_launchd <label> <gui\|system>` | `launchctl print` parsed for `state = running` and a `pid` (loaded-but-crash-looping is a failure); non-zero with a "no console session — log in locally, then: launchctl bootstrap …" hint. `dl_install_launchd` calls it and **returns non-zero** (no more `\|\| true`). |
| `dl_install_launchd <plist> <agent\|daemon> [--as-user] [--sed 'K=V' …]` | `--sed` only substitutes; the manifest pre-creates dirs (`~/Library/Logs`, chown) and computes values (wtalk's ffmpeg PATH discovery stays in its `post_install`). `--as-user` = wtalk's `sudo -u USER launchctl bootstrap gui/…`; both error texts ("Bootstrap failed: 5" root / "Domain does not support specified action" user) map to the same hint. |
| `dl_install_cli_wrapper <name> <exe>` | the heredoc wrapper (demonlock, blockrem, wtalk). Kept as a wrapper for parity with today; **not** because sudoers needs it — demonlock's sudoers grant references the bundle binary (deliberately, review H4), and `Agent.swift`'s `do shell script` would work with a symlink too. |
| `dl_seed_support_dir` | **not shared** — demonlock *merges* `settings.json` (user state lives there), blockrem *overwrites* (code defaults must win; nothing else writes it). Each stays in its `post_install`. demonlock's `chown -R root:wheel $SUPPORT` is fixed to exclude `rv/` (a pending user marker was re-owned to root and rejected by the owner check). |
| `dl_uninstall_common <app> <bundle> <cli…> <label…> [--purge]` + `dl_unregister_spare <bid>` | replaces 7 uninstallers. Keeps the **console-user fallback when `SUDO_USER` is empty** (uninstall from a root/Recovery shell is the lock-out escape). **No `tccutil reset`** in the common path (opt-in flag; only MSV uses it today). `--purge` = remove the support dir; MSV/stayup/rac keep their current "always"/"never" prefs behavior, documented. |
| `dl_user_launchd <label> <plist-body>` | no-root LaunchAgent writer + bootstrap + verify (browser-blitz, paseo). |

Not added: `dl_codesign` — making `--options runtime --timestamp` universal is a behavior change
for MSV/stayup/rac (rac sends Apple events; `--timestamp` makes builds network-dependent). Each
`build.sh` keeps its flags; the two-line ladder call is not worth a helper.

Then demonlock, blockrem, wtalk `install.sh` become manifests (`provide_bundle` = `dl_pick_bundle`,
`post_install` = seed + sudoers (written **before** deploy so an invalid sudoers can't leave a
half-install) + spare). rac's installer stays bespoke except `dl_deploy_app`/`dl_register_spare`.
nextdns-sidecar keeps its credential/profile flow, adopts `dl_require_root` (drops its accept-root
exception — the README forbids root shells; the *uninstaller* keeps the fallback per above),
`dl_install_launchd`, `dl_verify_launchd`, and gains `--credentials-file <path>` (two-line
`PROFILE=…\nAPI_KEY=…`, the file it already writes) so the profile ID never appears on argv.
Every installer forwards `CODESIGN_IDENTITY` through its `sudo -u USER … build.sh` (sudo's
`env_reset` strips it otherwise, and the ladder would re-prompt the keychain per build).

### `install-all.sh` (repo root, run as the user from a **local terminal or tmux**)

```
./install-all.sh [--from <phase>] [--only <tool>] [--no-secrets]
 0 preflight   ORDER MATTERS: `xcode-select -p` FIRST (the /usr/bin/python3 + git stubs pop the CLT
               GUI dialog if CLT is absent); then export PATH=/opt/homebrew/bin:$HOME/.local/bin:$PATH;
               probe brew · uv · ffmpeg · node/npm · jq · Karabiner · Paseo(optional) by absolute
               path; repo path is stable (not /tmp, /private/var/folders, no '#'); SUDO_USER≠root;
               console session = $USER (`who | grep console`); **admin membership**
               (`dseditgroup -o checkmember -m $USER admin`) — if false: "request admin via
               demonlock admin-release-valve request, then re-run" and exit; if `/usr/local/bin/demonlock` exists AND the admin is a live release-valve grant, require
               ≥30 min left (else print the i-still-need-sudo line); a fresh machine has no demonlock
               → plain admin, no check;
               require a real tty (`[ -t 0 ] && [ -t 1 ]` — this also catches `rac exec`, which has no env
               marker and no tty; phase 1 needs one); if $SSH_CONNECTION: warn, require tmux/nohup,
               and SKIP rac (its reinstall kills the tunnel this shell rides on; run
               `--only remote-agent-connector` locally); `--no-secrets` is only valid when every
               secret target is already filled;
               NextDNS: resolve `~/Downloads/NextDNS-*.mobileconfig` to the NEWEST single file (two
               matches would be "unknown argument" to the sidecar) — downloading it (browser login at
               apple.nextdns.io) is a human step BEFORE this phase, said so in the fix-it block.
               Prints ONE fix-it block (exact brew/curl/xcode-select lines, noting which ones open a
               GUI dialog) and exits 1 if anything is missing.
 1 secrets     ONE tty pass, never `set -x`, each skipped when its target already has content:
               NextDNS profile id + API key → `mktemp` 0600 two-line credentials file, deleted by
               `trap EXIT` (a leftover from a failed run is never reused — re-prompt; `--from 3`
               re-runs this prompt). The root-only `/usr/local/etc/nextdns-sidecar/` can't be
               `test -s`'d as the user, so "already filled" is decided by the sidecar: the driver
               passes `--credentials-file` only when it collected one, else no `--reconfigure` and
               the sidecar keeps its existing creds without touching the tty; Gemini key →
               `~/.wtalk/.env` written as the user with wtalk's FULL template (GROQ/HF lines too),
               0600; rac MIDDLEMAN/MACHINE_NAME → `~/.remote-agent-connector/config` as valid shell
               (quoted, no managed-values section).
 2 identity    `bash signing-ladder.sh` once as the user → CODESIGN_IDENTITY; over SSH with a Dev ID
               that needs a smartcard PIN, refuse (no GUI to answer it).
 3 root        ONE `sudo` root subshell (not one `sudo` per installer — the timestamp expires during
               wtalk's 10-min PyInstaller build, and a release-valve revoke mid-run would strand later
               steps) running: demonlock → blockrem → multistreamviewer → stayup → wtalk (setup.sh as
               the user first) → nextdns-sidecar (--profile-src/--credentials-file; zero tty reads)
               → remote-agent-connector LAST (skipped over SSH). CODESIGN_IDENTITY passed explicitly.
               **Stop at first failure** (a demonlock failure would make every later spare
               registration a no-op and register-recommended-spares hard-exit).
 4 user        STILL inside the phase-3 root subshell (so no second sudo prompt after a long npm
               install), user steps via `sudo -u "$SUDO_USER"`: browser-blitz install;
               setup-paseo-daemon ONLY if Paseo is present and its daemon isn't already loaded with
               an unchanged binary path (it bounces running agents); then
               `demonlock/register-recommended-spares.sh` as root.
 5 verify      ROOT-FREE (so `--from verify` works after `nosudo`): agents via
               `launchctl print gui/$UID/<label>` parsed for state=running+pid; daemons via
               `pgrep -x` + each tool's own `status` (unprivileged `launchctl print system/…` is not
               relied on); one table. Spares registered for apps not yet installed are fine
               (`test-lockout` lists them; not a failure).
 6 checklist   runs from the console session (or via `rac exec`): opens every TCC pane + both
               mobileconfigs, prints the numbered human list — demonlock: Location Always +
               Accessibility · blockrem: Accessibility · MSV: Accessibility + Screen Recording ·
               wtalk: Microphone + Accessibility · rac: Screen Recording + Accessibility +
               Automation · Karabiner: Input Monitoring + driver-extension approval · approve the 2
               profiles · Chrome Load-unpacked · `rac setup` (scriptable, but needs MIDDLEMAN
               reachable) · Karabiner rule → `wtalk toggle` (written for you into karabiner.json via
               jq if Karabiner is present — Karabiner hot-reloads) · then the arm commands and
               `demonlock nosudo`, never automated (README §3).
```

Re-run semantics: `--only <tool>` runs phases 0–2 then that tool; `--from <phase>` resumes.
Idempotency fixes that make "re-run end to end" true: wtalk `--no-prime-perms` (the driver passes it
only when `/Applications/wtalk.app` already existed at phase 0 — NOT keyed on `~/.wtalk`, which phase 1 always creates — because `--prime-perms` blocks on a pending dialog with no GUI and the TCC panes list an app only after it has asked); stayup and rac
`open` only when not already running; paseo skip rule above. `uninstall-all.sh [--purge]` mirrors the
README block via `dl_uninstall_common`.

README: clone via **https** (a fresh machine has no SSH key), `cd minh-mac-utils && ./install-all.sh`;
the "no top-level driver" paragraph is replaced.

## Gate (the zero-regression check, run on the Mac before and after)

1. **stdout**: `demonlock status`, `delayzones`, `delay-set-policy --status`, `safe-apps show`,
   `snooze-preset show`, `password-lockbox show`, `admin-release-valve status`, `help`;
   `blockrem list`, `help`; `nextdns-sidecar domains future`, `networklockdown status`, `help`.
2. **stderr on bad input** (where string drift would hide): `demonlock snooze "until junk"`,
   `demonlock snooze "for x"`, `blockrem snooze "at x"`, `blockrem set --onetime "for x" …`,
   non-root `nextdns-sidecar … set-delay`.
3. **on-disk bytes**: `shasum` of `schedule.json` after a blockrem `set`+`delete` round-trip,
   demonlock `state.json`/`settings.json`, sidecar `config.json`/`pf-state.json` after one daemon
   tick.
4. **daemon logs**: tail the three logs across one watchdog tick (child `launchctl` noise must be
   present/absent exactly as before).
5. **marker line semantics**: demonlock — a `DemonlockCoreTests` case: `dropDelayMarker` with an
   embedded `\n` yields ONE line; sidecar (no test target) — live: `domains delay-add a.test b.test`
   then `future` shows 2 rows (seeded before the Gate #1 diff so it's captured there).

Only timestamps/countdowns and §Deliberate #1 may differ.

## Tests

- MacUtilsCore: moved suites unchanged + TimeSpec (both keywords via each app's wrapper tests;
  `parseDuration` table; `nextTimeOfDay` with a fixed LA calendar: today-later, tomorrow, weekday
  filter, 8-day search, DST spring-forward day) + JSON (lenient missing/wrong-type; `saveJSON(mode:)`
  result mode; `pretty` bytes) + Users.
- demonlock: remaining `DemonlockCoreTests` green; `_policytest` 49/49.
- blockrem: `_selftest` 78/78 (exercises `parseWhen`/`parseWeekly` through its wrappers).
- Part 2: `bash -n` all scripts; `shellcheck` on lib + driver; live reinstall of demonlock, blockrem,
  nextdns-sidecar, multistreamviewer, stayup, wtalk through the new manifests under the current
  grant; the Gate; `install-all.sh --from verify`; `--only <tool>` for each tool.

## Rollout

1. Part 1 + tests green on the Mac → implementation review round (code vs this spec).
2. Part 2 + `bash -n`/shellcheck → review round.
3. Refresh + commit `demonlock/dist`; reinstall the six tools under the live grant; run the Gate;
   push. README updated.
