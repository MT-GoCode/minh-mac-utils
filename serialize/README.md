# serialize

An always-on-top widget that pins **one line of task text** — what you're setting yourself to
work on — on screen. Pitch-black background, white text. No timers, no lock, no sudo.

Runs as a menu-bar accessory app: a little icon top-right, **no Dock icon, not in Cmd-Tab**, and
the overlay is click-through so it never steals focus or "goes into" the app.

## Menu (top-right icon)

- **Modify Text…** — set the task line.
- **Settings…** — pick position, font size, notch offset.
- **Hide / Show** — hide the overlay without quitting.
- **Quit**.

## Five positions

| Mode | Look | Behavior |
|------|------|----------|
| Top — around notch | trapezoid tab hanging from the top center, around the notch/camera block | click-through; **hides on mouse-over**; text offset below the notch |
| Left edge | trapezoid tab on the left, vertically centered | click-through; hides on mouse-over |
| Right edge | trapezoid tab on the right | click-through; hides on mouse-over |
| Top bar | full-width black strip below the menu bar | **reserves space** — maximized windows stop at it |
| Bottom bar | full-width black strip above the Dock | **reserves space** |

The two bars actually reserve desktop space via the Accessibility API (macOS has no public
space-reservation API, so it watches windows and clamps any that overlap). The first time you
pick a bar mode it asks for **Accessibility** permission (System Settings ▸ Privacy & Security ▸
Accessibility) — no sudo, no admin.

## Build & install (sudo — root-owned)

```sh
sudo ./install.sh            # build + sign (as you), deploy ROOT-OWNED to /Applications, launch
sudo ./install.sh --login    # ...and auto-start at login
sudo ./uninstall.sh
```

Installs **root-owned** to `/Applications/Serialize.app` (`root:wheel`) so the bundle can't be
modified or swapped without sudo. That's what lets **demonlock** safely whitelist Serialize from its
lockout kill — demonlock spares it only if it's the genuine signed bundle *and* root-owned, so a
look-alike you re-sign with your own cert (in `~/Applications`) won't ride the whitelist. Build runs
as you (login keychain); deploy runs as root. Spotlight then finds **Serialize**.

Signing uses the repo's shared `../sign-identity.sh` ladder (Developer ID → stable self-signed →
ad-hoc). The stable self-signed tier keeps the Accessibility grant across rebuilds; ad-hoc resets it.
