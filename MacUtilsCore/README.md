# MacUtilsCore

Shared plumbing for **Minh Trinh's** macOS self-discipline tools (`demonlock`, `nextdns-sidecar`,
`blockrem`). Foundation-only, statically linked into each tool via
`.package(path: "../MacUtilsCore")`.

**The rule: edit here, never copy.** Nothing in this package is vendored anywhere; a fix to the
inbox-marker reader or the delay queue is made once and every daemon gets it on its next build.

| File | What |
|---|---|
| `MarkerIO.swift` | hardened user-inbox marker I/O (NDJSON append, owner/symlink/hardlink checks, `LOCK_NB`) |
| `DelayQueue.swift` | the keyed, root-owned, daemon-stamped delay queue every no-sudo loosening waits in |
| `DelayQueueLegacy.swift` | migration decoder for the pre-queue key-only map (sidecar) |
| `JSON.swift` | `loadJSON` / `saveJSON(mode:pretty:)` / lenient `Codable` decode |
| `Proc.swift` | `Proc.run(quiet:)` / `capture` / `captureStatus` |
| `Users.swift` | `resolveUID` / `userName(for:)` / `consoleUID` |
| `Log.swift` | `logStderr`, `nowEpoch`, `errOut`, `fail`, `requireRoot` |
| `TimeSpec.swift` | duration / HHMM / weekday-letter primitives, `nextTimeOfDay`, `fmtLeft`, `fmtWhen` |
| `EpochFile.swift` | the "epoch or `null`" scalar file (snooze) |

Tests: `swift test` here. The tools' own tests cover their wrappers on top of these.
