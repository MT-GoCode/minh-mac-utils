# Remote Agent Connector

One Mac app plus one CLI (`rac`) that let a remote agent reach into this Mac and act **as you**:
a real terminal for ordinary commands, and (via `rac`) full GUI plus keychain for the things
macOS forbids an `ssh` session to do directly.

Nothing listens for inbound connections on your Mac. The Mac dials out to a middleman box you
own and holds a persistent reverse tunnel; authorized agents reach your Mac through that.

---

## 1. Install

```
sudo ./install.sh
```

This builds and signs `RemoteAgentConnector.app`, deploys it root-owned to `/Applications`
(shows in the Dock, registers as a Login Item), and installs the `remote-agent-connector`
CLI plus its `rac` alias to `/usr/local/bin`.

Then once: **Dock, right-click the icon, Get Permissions**, and click Allow on each prompt
(Screen Recording, Accessibility, and a "control System Events" Automation prompt). These let
the app do GUI and keychain work on behalf of agents.

Menu-bar glyph: `●` (green) means a box has a live session right now, `○` means idle and ready,
`◌` means Remote Login is off (turn it on in System Settings, Sharing).

To reinstall after any change, run `sudo ./install.sh` again. It quits the running instance and
relaunches, so the new build is what runs.

---

## 2. Give an agent access (three setup commands, then tell the agent)

Run these on this Mac. `<ssh-target>` is literally what you would type after `ssh` to reach the
box yourself (an alias like `foreman`, or `ubuntu@1.2.3.4 -p 22`). All are idempotent; add
`--redo` to tear down and redo.

**a. Create the certificate authority (once).**
```
rac make-and-get-CA
```
Creates your CA and trusts it on this Mac. Steps b and c read it directly, nothing to copy.

**b. Set up the middleman box, and name this Mac.**
```
rac authenticate-middleman-box <ssh-target> <machine-name>
```
SSHes in and creates a locked-down `agentjump` user that trusts your CA and can only forward to
this Mac (no shell, no other ports). Needs sudo on that box. `<machine-name>` is the alias agents
will use to reach this Mac (`ssh <machine-name>`); you set it once here and every box inherits it.
The same box can be both the middleman and an authenticated box; just run step c on it too.

**c. Authenticate a whole box** (not per-agent: every agent on that box is then authorized).
```
rac authenticate-box <ssh-target>
```
SSHes into the box, generates a key there, signs it with your CA, installs the cert and an ssh
config block (with connection multiplexing, so commands are fast and the status light is
meaningful), then prints the agent briefing below. The alias is inherited from step b (pass a
name as a second argument only if you want to change it).

**d. Tell the agent:** hand it the briefing that command printed (the same text is in section 4).
The one line it needs is: `Access my personal computer with ssh <machine-name>`.

---

## 3. The `rac` hand: `exec`

Everything non-GUI runs over plain ssh as you, no prefix. The only special thing a plain ssh
session cannot do is act with GUI permission or your login keychain (macOS blocks that for sshd).
For those, there is exactly one verb: `rac exec <cmd...>`, which runs the command **as the app**,
so it carries the app's Screen Recording / Accessibility / Automation grants and your unlocked
keychain. Anything else is just a command through it:

```
rac exec screencapture -x /tmp/shot.png                       # screenshots
rac exec osascript -e 'tell application "Safari" to activate'  # AppleScript / UI automation / notifications
rac exec codesign -s "Developer ID Application: Minh Trinh" MyApp.app   # keychain / signing
rac exec pbpaste            # clipboard
rac exec open https://...   # open things
```

Higher-level conveniences (per-window screenshots, a browser fleet, structured LinkedIn tools,
etc.) are planned as a separate `mess-with-my-computer` CLI layered on top of `exec`.

---

## 4. The agent briefing

`authenticate-box` prints this with `<machine-name>` and your username filled in. Copy everything
from the line below down and hand it to the agent:

You have SSH access to my personal Mac (macOS, Apple Silicon) as the user `<user>`.
Connect with: `ssh <machine-name>`

This is a real login shell on my actual computer. Act as if you were sitting at my terminal.
Normal commands just work, as me, with my files and environment: read and write files, git,
python or node, builds, brew, curl. Run them directly, no prefix.

The one macOS rule: a plain ssh session cannot do anything that needs GUI permission (see the
screen, move the mouse or keyboard, control other apps) or my login keychain (code signing).
macOS blocks that for ssh permanently; it is not a misconfiguration and retrying will not help.
For those, prefix the command with `rac exec`, which runs it inside a small app in my logged-in
session that holds those permissions. Rule of thumb: if a bare command fails with a permission
or keychain error, re-run it as `rac exec <same command>` and it will go through. Examples:

    rac exec codesign -s "Developer ID Application: <me>" MyApp.app          # keychain / signing
    rac exec osascript -e 'tell application "Safari" to activate'            # AppleScript, control apps
    rac exec osascript -e 'display notification "done" with title "Build"'   # notifications
    rac exec screencapture -x /tmp/shot.png                                 # screenshot the screen
    rac exec pbpaste                                                        # read the clipboard
    rac exec open https://example.com                                       # open a url / file / app

Everything is one command at a time over ssh, but the connection is kept warm between commands,
so fire as many as you need, they are fast. If `ssh <machine-name>` hangs or is refused, my
connector may be offline; tell me, do not hammer it. This is my personal machine: be deliberate.

---

## 5. How it works

- **Transport (no inbound port on your Mac).** The app keeps an outbound reverse-SSH tunnel to
  your middleman alive forever and self-provisions both sides. Agents reach your Mac's sshd
  through the middleman; nothing listens on the Mac.
- **Auth by the box, via an SSH certificate authority.** You create the CA once; authorizing a
  machine is just signing its key with a cert carrying two principals (one for the middleman
  jump, one for the Mac login). Short validity by default (12 weeks, set `RAC_CERT_VALIDITY`).
- **Hands macOS will not give ssh.** A command over ssh is attributed to `sshd`, which macOS
  permanently denies Screen Recording, Accessibility, and Automation. This app holds those grants
  and your unlocked login keychain, and runs privileged work on request over a loopback,
  token-gated relay. `rac exec` runs it as the app, so screenshots, clicks, AppleScript, and
  codesign all work.
- **Sessions and speed.** Each box's ssh config uses ControlMaster multiplexing with a 20-minute
  idle window. The first command opens one connection; the rest reuse it (fast, no re-handshake),
  and it stays live while the agent keeps working, which is what the green status light reflects.

## 6. The trade to know

The CA private key (`~/.remote-agent-connector/agent_ca`) is the whole security boundary. Guard
it, keep `RAC_CERT_VALIDITY` short, and you can revoke a box with an SSH KRL. The middleman only
ever forwards ciphertext (SSH is end-to-end), so it is a dumb pipe, not a man-in-the-middle.

## 7. Uninstall

```
sudo ./uninstall.sh
```
Removes the app and CLI. Your CA, keys, and config under `~/.remote-agent-connector` are kept
(delete that folder by hand for a clean slate).
