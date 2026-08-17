# forcecalls endpoint

The thing that rings on your Mac. baresip, registered to SignalWire, set to **auto-answer** — because
by the time it's dialled the other person has already picked up, so there is nothing to decide.

Root-owned, with a watchdog daemon that re-bootstraps it if you `launchctl bootout` the agent. That
asymmetry is deliberate: killing baresip drops the current call, but it can't make you permanently
unreachable.

## Install

```sh
sudo ./install.sh              # asks only for the SIP password
sudo SIP_PASS=… ./install.sh   # fully non-interactive
```

**Do this while you still have sudo.** Once admin is revoked you can't install it, and without it a
forced call reaches the other person and then has nothing to bridge to.

The username and domain come out of the `creds.json` the main installer already wrote, so the
password is the only thing you supply. It also installs baresip via Homebrew if it's missing, finds
the module path from your Homebrew prefix, and waits for SIP registration before declaring success —
a wrong password shows up as a 401 here rather than as a dead call at 8:45 PM.

Uninstall: `sudo ./uninstall.sh` (leaves baresip itself installed).

## Verify before dropping sudo

```sh
pkill baresip && sleep 3 && pgrep baresip        # KeepAlive brings it straight back
launchctl bootout gui/$(id -u)/com.minh.forcecalls.endpoint
sleep 15 && pgrep baresip                        # the watchdog re-bootstraps it
forcecalls testcall +1YOUROWNCELL                # the real path, end to end
```

If the third one fails, the watchdog isn't doing its job and you have an ordinary agent you can
switch off — worth knowing before you rely on it.

## What gets installed

| Path | Owner | Notes |
|---|---|---|
| `/etc/baresip/config` | root `644` | modules, audio devices, `ctrl_tcp` on 127.0.0.1:4444 |
| `/etc/baresip/accounts` | root `600` | generated; holds the SIP password, unreadable by you |
| `/Library/LaunchAgents/com.minh.forcecalls.endpoint.plist` | root `644` | baresip, `KeepAlive` |
| `/Library/LaunchDaemons/com.minh.forcecalls.endpoint-watchdog.plist` | root `644` | re-bootstraps the agent |
| `/usr/local/libexec/forcecalls-endpoint-watchdog.sh` | root `755` | 10s poll |

## Menu bar status (optional)

`baresip.5s.sh` is a [SwiftBar](https://github.com/swiftbar/SwiftBar) plugin: an idle phone icon that
lights up with a mute toggle while a call is live. `brew install --cask swiftbar`, then drop it in
SwiftBar's plugin folder. The Forcecalls Dock app covers the same ground with a window; this is the
lighter option if you'd rather not have a Dock tile appear.

## Known ceilings

- **No runtime audio-device switching.** baresip picks its device at call start and macOS device
  selection is an unresolved gap upstream, so plugging in headphones mid-call won't follow. Set your
  default output before you lock things down; changing it later means editing a root-owned config.
- **Wi-Fi off kills the call**, and no daemon can prevent that.
- **A sleeping Mac rings nothing** — see `stayup`.
