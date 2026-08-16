# msv2 — a scoped ⌘⇥ switcher

Not a window mover. msv2 **never moves, hides, or parks a window** — the one thing every
previous approach got wrong. It's AltTab for macOS with one twist: a private ⌘⇥ that only
offers the windows in your current *group*. Everything else keeps living exactly where it
is; you just stop tabbing to it until you switch groups.

That's the whole idea. Nothing can be stranded, shifted, mirrored to a fake display, or
mangled, because nothing is ever touched — the worst possible bug is a window with the
wrong tag, fixed by re-tagging.

## Keys

- **hold ⌘⌥** — all desktops in spaced views with live thumbnails; release to hide.
  - the grid fills progressively: 1 desktop = whole screen with a thin "+" bar below;
    2 = stacked with the "+" bar on the right; 3 = quadrants with "+" in the fourth; …
    up to the configured grid (Settings, default 3×2, both ≥2) — only past that does it
    scroll
  - hover a window → outline + ✕ close / ⏻ quit buttons; click it → raise it; thumbnails
    shrink so every window in a desktop always fits
  - **drag a thumbnail onto another desktop** to move it; drag a desktop *header* onto
    another card to reorder desktops
  - hover a desktop header → ✏ rename · 🪄 seed (runs the checked seed commands; new
    windows for the next 8s are tagged to it) · 🗑 delete (gracefully closes its windows —
    dirty documents get their save dialog and survive into the current desktop)
  - windows inside a desktop are ordered by the Settings priority list
- **⌘⇥** — switcher, scoped to the current desktop, live thumbnails. Hold ⌘, press ⇥/⇧⇥
  or arrows to pick, release ⌘ to commit, esc to cancel. Hover gives the same ✕/⏻ buttons.
- menu bar: desktops (click to jump), Show All Desktops, New Desktop, Seed Current
  Desktop, **Gather All Windows Here** (pull every window into the current desktop),
  Settings…, Quit.
- **Settings** (menu → Settings…): overview grid width/height · app priority list ·
  excluded apps · seed commands (toggle + edit) · permission status with grant buttons.
  Stored in `~/Library/Application Support/msv2/config.json`.

No numbered hotkeys — you navigate by the ⌘⌥ overview and by ⌘⇥. New windows join
whatever desktop is current; focusing a window from another desktop (⌘⇥, Dock, a
notification) makes that desktop current, so the switcher scope follows you.

Neither gesture ever moves a window on your real screen — the ⌘⌥ overview is a map, and
switching desktops just changes which windows ⌘⇥ offers and raises one of them. The
thumbnails are read-only previews.

## Install

```sh
sudo ./install.sh
```

Self-contained: `install.sh` declares a small manifest and sources the shared
`../scripts/install-lib.sh`. It builds + signs (Developer ID, team BULCQM9J2V), deploys
**root-owned** to `/Applications`, symlinks the CLI to `/usr/local/bin/msv2`, and launches.
msv2 is a **demonlock compiled-in default spare** (root-owned Regime A), so nothing is
registered at install — it's spared out of the box. `./scripts/build.sh` alone does a quick
dev build into `~/Applications`. Uninstall: `sudo ./uninstall.sh`.

## Requirements

- **Accessibility** — required (raises windows). Prompted on first launch.
- **Screen Recording** — optional; only powers the thumbnails. Without it, tiles show app
  icons and everything else works — tracking never depends on it.

## Why this is robust

- **No window is moved.** No virtual display, no offscreen parking, no AX position writes.
  The engine only reads the window list and decides what ⌘⇥ shows.
- **Reality is the source of truth.** Every 0.5s the engine reconciles its tags against
  the live window list; a wrong tag self-corrects, a closed window drops out. There is no
  bookkeeping that can diverge from what's on screen.
- **Identity survives everything.** Windows are tracked by CGWindowID from the raw list,
  so minimize / ⌘H / another Space keep a window's tag; it returns to its group when it
  does. Titles are cosmetic (thumbnails/labels), so Screen Recording is optional and only
  affects looks, never tracking.
- **Tags persist** across app restarts (session-fingerprinted so stale IDs can't kidnap
  new windows; reboot starts fresh, by design).

## Requirements

Only **Accessibility** (to raise windows), prompted on first launch. No Screen Recording,
no display-settings changes, no virtual display. Launch from a terminal that has
Accessibility.

## Run

```sh
swift build -c release
.build/release/msv2
```
