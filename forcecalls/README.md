# forcecalls

Scheduled phone calls you have to **wait out** to cancel. At each scheduled time a root daemon rings
the other person through SignalWire; when *they* answer, your desk endpoint is dialled and
auto-answers, and a window appears. Adding a call is instant. Removing one is delay-gated.

The commitment device is the same one as demonlock's release valve: no password is held anywhere,
**the wait is the gate**.

Think "every night at 8:45 PM I call my mom, and impulse-me can't quietly delete that."

## Install

```sh
sudo ./install.sh    # one command: prerequisites, build+sign, daemon, agent, and the baresip endpoint
```

It checks its prerequisites first (Homebrew, Xcode CLT or a prebuilt `dist/`, `nc`) and refuses
before touching anything if one is missing — a half-installed system is worse than no install. It
brew-installs baresip if absent, and finishes by verifying SIP registration and the control channel.

Credentials are collected **on stdin during install** and written root-owned `0600`. Nothing secret
is committed, and you can't read them back afterwards — so a forced call can't be defanged by
editing the keys out. Replace them later with `sudo ./install.sh --reset-creds`.

Uninstall: `sudo ./uninstall.sh` removes the endpoint too (add `--purge` to also delete the schedule and credentials).

The **endpoint** — baresip, the thing that rings on your Mac — is installed by the same script; it
is not optional, since without it a call reaches the other person and has nothing to bridge to.
`endpoint/README.md` documents it, and `endpoint/install.sh` can be re-run on its own.

## Setting up SignalWire (once)

Three things to create in your Space. **Read every value off the dashboard — none of them are
guessable, and one of them looks like it should be.**

1. **API token** — Dashboard ▸ **API**. Create a token and copy it immediately; it is shown once.
   The **Project ID** on the same page is the Basic-auth username that goes with it.

2. **SIP credential** — Dashboard ▸ **Resources** ▸ Add ▸ **SIP Credential**. Type a username into
   the **URI** box. The dialog prints the domain right next to it, and that domain is *not* simply
   `<space>.sip.signalwire.com` — it carries a suffix derived from your project ID:

   ```
   <username>@<space>-<suffix>.sip.signalwire.com
   ```

   Copy what the dialog shows. Leave **Send As** and **Caller ID** blank — they apply only when a
   credential dials out to PSTN, and this one only ever *receives* calls; withholding PSTN rights
   also caps the damage if it leaks. Encryption stays default. Set a password further down the form
   and keep it: `endpoint/install.sh` asks for it.

3. **Verified caller ID** — Dashboard ▸ **Phone Numbers** ▸ **Verified Caller ID**. Add the number
   you want the other person to see. SignalWire calls it and reads you a code. It is outbound-only
   and doesn't touch your carrier service, so **you never rent a number** — no monthly line, just
   per-minute.

### Installing

Interactive, which prompts for all five:

```sh
sudo ./install.sh
```

Non-interactive — also the only form that works over SSH or from a script:

```sh
sudo SW_SPACE=<space>.signalwire.com \
     SW_PROJECT=<project-id> \
     SW_TOKEN=<api-token> \
     SW_CALLERID=+15551234567 \
     SW_ENDPOINT=sip:<username>@<space>-<suffix>.sip.signalwire.com \
     ./install.sh
```

Add `--reset-creds` to replace credentials that are already installed.

Caller ID must be bare E.164 — `+15551234567`, no spaces, parens, or dashes. SignalWire rejects
anything else, and it fails at call time rather than at install.

Nothing here is committed: all five land in the root-owned `0600` `creds.json` the installer writes.

## Commands

Every command is **user-runnable — no sudo**:

```
forcecalls show                                              # calls, next fire, pending removals
forcecalls add --name <name> --destination <+E.164> --schedule <DAYS|*><HHMM>
               [--once] [--hangup-on-machine]
forcecalls remove <name|id>                                  # queued; lands after the delay
forcecalls abort                                             # cancel every queued removal
forcecalls testcall <+E.164|name> [--hangup-on-machine]       # dial now, exactly as a scheduled call would
forcecalls presence                                          # are you active enough for a call to fire?
forcecalls selftest                                          # assert the schedule math (no side effects)
forcecalls help
```

### `--schedule` — the time string

A single token `<DAYS><HHMM>`, the same day alphabet demonlock's policy language uses: `M T W R F S U`
(R=Thu, U=Sun), or `*` for every day, then a 4-digit local time.

```sh
forcecalls add --name mom  --destination +15559998888 --schedule *2045    # every day 20:45
forcecalls add --name dad  --destination +15551112222 --schedule U1000    # Sundays 10:00
forcecalls add --name gran --destination +15553334444 --schedule MWF1900  # Mon/Wed/Fri 19:00
```

All times are **local**, resolved live in the current timezone.

### `--once` — a single call

Fires at the **next** occurrence of the schedule, then deletes itself. The schedule syntax is
exactly the same — `--once` changes the lifecycle, nothing else:

```sh
forcecalls add --name checkin --destination +15559998888 --schedule *2045 --once   # next 20:45
forcecalls add --name gran    --destination +15559998888 --schedule M0900  --once   # next Monday 09:00
```

A one-shot is spent by an actual dial attempt, success or failure — but **not** by a presence skip.
"Call once" shouldn't be consumed on a night you weren't at the desk.

### `--hangup-on-machine` — don't talk to voicemail

Without it, a voicemail greeting counts as "answered" by the carrier, so you get bridged to a
recording. With it, SignalWire runs answering-machine detection and the call is hung up instead.

```sh
forcecalls add --name mom --destination +15559998888 --schedule *2045 --hangup-on-machine
forcecalls testcall +15559998888 --hangup-on-machine
```

Two costs: a couple of seconds of detection before you're bridged, and a small per-call detection
fee. Both columns show in `forcecalls show`.

**How it works without a webhook.** The usual way to act on `AnsweredBy` is to have SignalWire POST
it to a URL you host — a public HTTPS endpoint existing solely for this. Instead the daemon asks for
detection, polls the Call resource for `answered_by`, and hangs up over REST if it reports a machine
or a fax. Serverless, at the price of that short delay.

### Trying it before 8:45 PM

`testcall` takes the exact same path a scheduled fire takes — same leg order, same LaML, same
endpoint — so if it works, the real thing works. It just skips the schedule and isn't recorded
against any forced call.

```sh
forcecalls testcall +15559998888    # a raw number
forcecalls testcall mom             # or the name of a forced call you already added
```

The outcome lands in `forcecalls show` under `(testcall)`.

### It won't ring them if you're not there

Before dialling, the daemon checks that **you** are at the machine: the console user must be the
enforced user, and macOS's `HIDIdleTime` — nanoseconds since the last keyboard or mouse event — must
be under `requireActiveSeconds` (default **5 minutes**).

```sh
forcecalls presence     # what the daemon would decide right now
```

A skipped call is recorded in `forcecalls show` with the reason, and is **not** retried later: the
occurrence is stamped before the check, so a call declined at 20:45 can't fire at 03:00 because you
got up for a glass of water.

This check fails **closed** — if idle time can't be read, it doesn't dial. Ringing someone into an
empty room is worse than missing a night.

Set `requireActiveSeconds` to `0` in `settings.json` to disable it. That file is root-owned, which is
deliberate: turning the check off is a loosening, and loosenings cost sudo.

### Removal is the whole point

`remove` doesn't remove anything. It queues a removal that lands after `removeDelaySec` (default
**12h**), and the call keeps firing until then. `abort` cancels every queued removal instantly —
tightening is never delayed, only loosening is.

The daemon stamps the request time itself, so the delay can't be backdated, and a repeat `remove`
leaves the original deadline standing rather than restarting (or shortening) it.

## How it works

- **Root daemon** (`com.minh.forcecalls.daemon`, LaunchDaemon) — owns `calls.json`, ticks every 5s,
  replays your inbox markers in order, lands due removals, and places calls whose occurrence is due.
  It lives in the `system` domain, so you can't stop it without sudo.
- **GUI agent** (`com.minh.forcecalls.agent`, LaunchAgent, `LSUIElement`) — invisible until a call is
  live, then flips to `.regular`, takes a Dock tile, and opens a window with the duration and a mute
  button. Closing the window or clicking the Dock icon only shows/hides it. There is deliberately
  **no hang-up button**.
- **Endpoint** (`endpoint/`) — baresip as a root-owned LaunchAgent with `answermode=auto`, plus a
  root LaunchDaemon watchdog that re-bootstraps it if you `launchctl bootout` the agent.

### Leg order, and why it matters

The destination is dialled **first**. Only when they answer does LaML `<Dial>` your SIP endpoint.
Two consequences worth stating plainly:

1. On a night they don't pick up, your desk never rings and there's nothing to escape.
2. Your endpoint having an established call **means**, by construction, that they answered. That's
   why the agent can treat "baresip has a call" as "they picked up" with no extra signalling.

## On-disk layout

`/Library/Application Support/Forcecalls/` is `root:wheel`, except `inbox/`, which is yours — that
asymmetry is what makes management no-sudo while the schedule itself stays out of your hands.

| File | Owner | Writer | Notes |
|---|---|---|---|
| `calls.json` | root | daemon only | `[ForcedCall]` — not hand-editable |
| `state.json` | root | daemon | fired history, pending removals, last outcome |
| `creds.json` | root `0600` | install | SignalWire keys; unreadable by you |
| `settings.json` | root | install | `enforcedUser`, delays, `requireActiveSeconds` |
| `inbox/` | you `0700` | CLI (no sudo) | `<millis>-<rand>.{add,remove,abort}` markers |
| `logs/daemon.log` | root | daemon | |

Markers are consumed through the same hardening as demonlock's `MarkerIO`: `O_NOFOLLOW`, owner must
equal the enforced user, and the unlink is verified so a `chflags uchg` marker can't re-fire.

## Notes

- **Fail-quiet, not fail-open.** A failed dial is logged and shown in `forcecalls show`; it never
  retries in a loop. The occurrence is stamped *before* the request goes out, so a crash mid-call
  costs you one missed call rather than redialling your mother every five seconds.
- **No retry/attempts knob yet.** If a missed call should redial, that's a `attempts` field on
  `ForcedCall` plus a status poll — deliberately not built until it's wanted.
- A sleeping Mac rings nothing. Check `pmset` / `stayup` if 8:45 PM regularly finds the lid shut.
