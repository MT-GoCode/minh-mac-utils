# fade-play-pause-chrome

macOS daemon that fades out + pauses playing browser music tabs, and fades them
back in. Works across Chromium browsers (Google Chrome, Microsoft Edge — see
`BROWSERS` in `fadedaemon.sh`). Two explicit triggers (no toggle): wire dictation
START -> pause, STOP -> resume (or bind to any hotkey).

## Files
- `fadepause-trigger.sh`  — run on dictation START (requests pause).
- `faderesume-trigger.sh` — run on dictation STOP  (requests resume).
- `fadedaemon.sh`         — long-running worker (installed via launchd).
- `install.sh` / `uninstall.sh`
- `com.user.fadedaemon.plist.template`

## Install
    cd fade-play-pause-chrome
    ./install.sh

## Wire your dictation tool to run these shell commands
    START: ~/bin/fade-play-pause-chrome/fadepause-trigger.sh
    STOP:  ~/bin/fade-play-pause-chrome/faderesume-trigger.sh

## Requirements (one-time, persist across reboot)
- For EACH browser you list in `BROWSERS`: enable
  `View > Developer > Allow JavaScript from Apple Events`.
- Grant Automation permission to control each browser on first daemon action
  (System Settings > Privacy & Security > Automation).
- Google Chrome must stay installed even if you only use Edge: the AppleScript
  borrows Chrome's scripting terminology (`using terms from application
  "Google Chrome"`) to drive every browser by a variable name.
- The startup self-check logs exactly which of these is missing — `tail` the log.

## How it behaves (robustness)
- Pause records `<app>\t<tabId>\t<url>` per paused tab; resume matches by **tab
  id** (survives track changes / tab reordering) and verifies the **host** still
  matches (so a tab-id reused after a browser restart isn't resumed by mistake).
- Every browser interaction is bounded by an Apple Event timeout + `try`, and tab
  work runs in parallel, so slept / discarded / suspended / wedged tabs (e.g. via
  a tab-suspender extension) can never hang the daemon or abort a scan — they're
  skipped. Suspended tabs (chrome-extension:// placeholders) aren't playing, so
  they're correctly ignored; if a tab gets suspended *while* paused, resume can't
  restore it (whitelist your music sites in the suspender to avoid this).
- Startup is self-healing: kills orphaned older instances, ignores a stale press
  from before startup, clears stale pause state, trims an oversized log.

## Logs / status / uninstall
    launchctl list | grep fadedaemon
    tail -f ~/Library/Logs/fadedaemon.log
    ./uninstall.sh
