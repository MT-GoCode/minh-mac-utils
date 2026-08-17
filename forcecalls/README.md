# forcecalls

Scheduled phone calls you have to **wait out** to cancel. At each scheduled time a root daemon rings
the other person through SignalWire; when *they* answer, your desk endpoint is dialled and
auto-answers, and a window appears. Adding a call is instant. Removing one is delay-gated.

The commitment device is the same one as demonlock's release valve: no password is held anywhere,
**the wait is the gate**.

Think "every night at 8:45 PM I call my mom, and impulse-me can't quietly delete that."

## Install

```sh
sudo ./install.sh              # builds + signs as you, deploys, prompts for SignalWire creds
```

Credentials are collected **on stdin during install** and written root-owned `0600`. Nothing secret
is committed, and you can't read them back afterwards — so a forced call can't be defanged by
editing the keys out. Replace them later with `sudo ./install.sh --reset-creds`.

Uninstall: `sudo ./uninstall.sh` (add `--purge` to also delete the schedule and credentials).

The **endpoint** — baresip, the thing that rings on your Mac — installs separately from
`endpoint/INSTALL.md`. Until it's registered, calls reach the other person and then fail to bridge.

## Setting up SignalWire (once)

Everything lives in one dashboard. Your space name becomes both URLs you need:
`fuckitall.signalwire.com` for the dashboard, `fuckitall.sip.signalwire.com` for SIP.

1. **API token** — `https://fuckitall.signalwire.com/credentials`. Create one and copy it
   immediately; it is shown once. The Project ID on the same page is the Basic-auth username.
2. **SIP credential** — `https://fuckitall.signalwire.com/resources/sips`. Pick a username and
   password. That yields `sip:<username>@fuckitall.sip.signalwire.com`, which is your endpoint.
   Leave the **call handler** on `default`: this endpoint only ever *receives* calls, so it never
   needs PSTN dialing rights, and not having them limits the damage if the credential leaks.
3. **Verified caller ID** — `https://fuckitall.signalwire.com/verified_caller_ids`. Add the number
   you want the other person to see. SignalWire calls it and reads you a code. It is outbound-only
   and does not touch your carrier service, so **you never have to rent a number** — no monthly
   line on the bill, just per-minute.

The same SIP username and password also go into `/etc/baresip/accounts` — see `endpoint/INSTALL.md`.

### Installing with the values

Interactive, which prompts for all five:

```sh
sudo ./install.sh
```

Or non-interactively, which is also the only way that works over SSH or from a script:

```sh
sudo SW_SPACE=fuckitall.signalwire.com \
     SW_PROJECT=3cfa65a8-0c88-4333-a8c4-16a09fb46f72 \
     SW_TOKEN=PT…                                     \
     SW_CALLERID=+19495404623 \
     SW_ENDPOINT=sip:minh@fuckitall.sip.signalwire.com \
     ./install.sh
```

**The token is deliberately not written down here.** It is the one real secret of the five, and this
repo's rule is that nothing secret is committed — it lives only in the root-owned `0600`
`creds.json` that the installer writes. Replace it later with `sudo ./install.sh --reset-creds`.

Caller ID must be bare E.164 — `+19495404623`, no spaces, parens, or dashes. SignalWire rejects
anything else, and it fails at call time rather than at install.

## Commands

Every command is **user-runnable — no sudo**:

```
forcecalls show                                              # calls, next fire, pending removals
forcecalls add --name <name> --destination <+E.164> --schedule <DAYS|*><HHMM>
forcecalls remove <name|id>                                  # queued; lands after the delay
forcecalls abort                                             # cancel every queued removal
forcecalls testcall <+E.164|name>                            # dial now, exactly as a scheduled call would
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

### Trying it before 8:45 PM

`testcall` takes the exact same path a scheduled fire takes — same leg order, same LaML, same
endpoint — so if it works, the real thing works. It just skips the schedule and isn't recorded
against any forced call.

```sh
forcecalls testcall +15559998888    # a raw number
forcecalls testcall mom             # or the name of a forced call you already added
```

The outcome lands in `forcecalls show` under `(testcall)`.

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
| `settings.json` | root | install | per-machine `enforcedUser`, delays |
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
