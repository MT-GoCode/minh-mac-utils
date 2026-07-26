# MultiStreamViewer — virtual desktops for macOS

Your own desktops, fully independent of native macOS Spaces (which have no public
API and are SIP-locked). One real desktop; inactive groups park 1px off the
bottom-right corner via Accessibility. Everything is manageable: create, close,
rename, reorder, seed, drag windows between desktops.

## Hotkeys (built-in event tap — no Karabiner)
- hold **⌘⌥** — overlay of all desktops; release hides
- **⌘⌥1..9** — switch to desktop N · **⌘⌥⇥** — next · **⌘⌥=** — new desktop
- **⌘⇥** — window switcher within current desktop: keep holding ⌘, press ⇥/⇧⇥ or
  arrow keys to pick in the grid, release ⌘ to commit, esc to cancel

## Overlay (also fully interactive when pinned to a second display)
Tile banner: ≡ drag to reorder · number · name (double-click switches, ✏ renames)
· 🪄 seed · 🗑 close desktop (closes its windows). Thumbnails: click to jump,
drag onto another tile to move the window, hover for ✕ close / ⏻ quit app.
Fullscreen apps appear in a read-only strip (native fullscreen can't be managed;
click jumps to it).

## Safety
Quit/termination restores every parked window to its saved position. Menu →
"Restore All Windows" is the manual rescue.

## Install
```sh
sudo ./install.sh   # builds, signs, deploys root-owned to /Applications, launches
/Applications/MultiStreamViewer.app/Contents/MacOS/msv run
```
Root-owned matters: it is what lets demonlock spare it (its spareApps entry only
holds for a root-owned /Applications bundle). `./scripts/build.sh` alone still
works for a quick dev iteration -- it signs + installs to ~/Applications, just
unprotected by demonlock until you run install.sh.
Launch from a terminal that has Screen Recording + Accessibility so the app
inherits them. CLI: `msv show|hide|toggle|new|restore|switch N|next`.
