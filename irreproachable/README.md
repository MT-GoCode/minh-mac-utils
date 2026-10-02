# irreproachable

Keep a Paseo agent working toward a goal until the agent says it is met.

```
irreproachable new "<goal>" [--steer-every 30m] [--idle-after 6m] [--steer-prompt TEXT] [--agent ID]
irreproachable clear [--agent ID]
irreproachable mute [DURATION] [--agent ID]
irreproachable unmute [--agent ID]
irreproachable ls
irreproachable --selftest [SECTION ...]
```

Run `new` inside a Paseo agent, and it governs that agent through `$PASEO_AGENT_ID`. `--agent` targets another
agent from a plain shell. A detached watcher then sends two kinds of message:

- **Goal prompt** (`GOAL_PROMPT` in the script) is sent once nothing has woken the agent for `--idle-after`.
  The default is 6m: pacemaker's longest ping interval (300s) plus 60s, so an agent waiting on a pacemaker
  Monitor is never prompted. It is only sent to an agent that is not busy.
- **Steer** (`STEER_HEADER`, `STEER_BODY`, `RESUME`) is sent every `--steer-every`, default 30m. It **interrupts
  a busy agent on purpose**, because Paseo has no message queue. The appended resume line tells the agent to redo
  what was cut off. `--steer-prompt` replaces only the body. A steer due within `--idle-after` goes out in place
  of a goal prompt, since it carries the goal too.

Nothing is sent while the agent has a pending permission request: it is waiting on you. `mute [DURATION]` holds
goal prompts only (steers keep their cadence) for up to 1h, the default; `unmute` ends it early. The agent ends the goal
with `irreproachable clear`. `ls` shows every goal as `watching`, `watching (muted 12m)` or `ENDED <why>`.

## How it decides

It checks the agent with `paseo inspect`. Busy means `Status` is `running` or `initializing`; quiet means
`now − max(UpdatedAt, last send)`. Between checks it sleeps until the earliest moment a send could be due, so an
agent costs one check per `--idle-after` (about 1.5 s of CPU), never a held `paseo wait`, which uses 150 MB.

State lives in `~/.irreproachable/<agent-id>/`. `meta.json` is written once, by the watcher. `log` holds
`<epoch> <event>` lines (`START`, `SEND`, `CLEARED`, `REPLACED`, `MUTED`, `UNMUTED`, `END <reason>`). A mute is a
`muted` file holding its goal's token and end time, so a mute never outlives its goal.

## Limits

- Claude Paseo agents only. Codex is deferred: in default mode it blocks on permission prompts.
- Runs on the same host as the agent's Paseo daemon.
- Goals do not survive a reboot, and may not survive a Paseo daemon restart (not measured). `ls` shows them as
  `ENDED`.
- About 1 s passes between seeing an agent idle and sending the goal prompt. A turn that starts inside that second
  is interrupted.

## Install

`./install.sh` puts one file in `~/.local/bin`. When paseo is reachable only from a login shell (nvm on macOS),
it also writes a marked `~/.local/bin/paseo` shim, because agents' shells get a plain PATH. Re-run it if node
moves. `./uninstall.sh` removes both. Both refuse while any goal is live: install would leave its watcher on the old
code, and uninstall would leave it asking an agent to run a `clear` that no longer exists. `~/.irreproachable` is kept either way.

`irreproachable --selftest` runs real throwaway Haiku agents in one `irr-selftest` workspace, one at a time, for
about 20 minutes and a few cents. It deletes every agent it made and archives the workspace. One check holds a
permission prompt open for 3 minutes; it shows up in the Paseo app and says to leave it alone, so do. Name sections (`goal`,
`steer-a`, …) to run only those.
