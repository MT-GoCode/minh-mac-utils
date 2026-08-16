# betterat

A personal, **no-sudo** "better `at(1)`": schedule shell commands to run at an
exact Unix time (or a friendly duration from now). Commands are stored in a
SQLite database and executed by a per-user **launchd agent** — so they survive
shutdown and **catch up on boot/login**: anything whose time passed while the
Mac was off runs on the next startup.

Everything runs as **you**. No root, no sudo, no setuid. Install and uninstall
need no elevated permissions.

## Standalone

Depends only on base-macOS tools — `/bin/bash`, `/usr/bin/sqlite3`, `launchctl`,
`date`, `base64`. No Python, no virtualenv, no third-party packages, no build
step. A single self-contained script.

## Install

```bash
./betterat install                 # copies itself to ~/.local/bin, loads the agent
./betterat install --interval 30   # daemon tick every 30s (default 15, min 10)
```

`install` is idempotent — re-run it any time to update the binary or reload the
agent. It also adds `~/.local/bin` to your `PATH` (in `~/.zshrc`) if it isn't
already, so `betterat` is callable on a fresh shell.

> **`betterat install` is the real installer.** The repo also carries a
> `betterat/install.sh` (the shared-lib manifest the other tools use), but it only
> stages the script system-wide in `/usr/local/bin` root-owned — it does **not** set
> up your per-user launchd agent or database. betterat is a no-sudo, runs-as-you tool,
> so use `./betterat install`; jobs won't fire until you do.

## Schedule

```bash
# duration from now — D/H/M/S, any order; a bare integer is seconds
betterat -command "backup.sh" -in 2h30m
betterat -label nightly -command "rsync ..." -in 1d

# absolute Unix timestamp (seconds)
betterat -label release -command "deploy.sh" -at 1735689600
```

Flags: `-command` (required), `-label` (optional name), and exactly one of
`-in <dur>` / `-at <unix-ts>`. Long forms `--command`/`--label`/`--in`/`--at`
also work.

## Manage

```bash
betterat list [--full]            # ID STATE LABEL QUEUED RUN/ETA EXIT COMMAND
betterat log [<label|id>] [-n N]  # stdout/stderr of commands that ran
betterat check-queued <label>     # exit 0 if a pending/running job has that label, else 1
betterat cancel <label|id>        # cancel matching pending job(s) (exit 0 if any, else 1)
betterat abort                    # cancel ALL pending jobs
betterat status                   # daemon + queue summary
betterat uninstall [--purge]      # unload agent (--purge also deletes the DB + binary)
```

`check-queued` is built for scripting — it prints a line but the **exit code** is
the contract:

```bash
betterat check-queued nightly || betterat -label nightly -command "..." -in 1d
```

States: `pending` → `running` → `done` / `failed`. `cancel`/`abort` move pending
jobs to `cancelled`. A job left `running` by a crash/shutdown is marked `failed`
on the next tick (**not** silently re-run — its side effects may have partly
happened).

## How it works

- `betterat install` writes `~/Library/LaunchAgents/com.minh.betterat.plist` and
  bootstraps it into your `gui/<uid>` domain. The agent runs `betterat run-due`
  every `StartInterval` seconds and at load (`RunAtLoad`, the boot/login
  catch-up).
- Each tick runs every job whose `run_at <= now`, claiming it atomically
  (`UPDATE ... WHERE state='pending'`) so overlapping ticks can't double-run it.
  A `mkdir` lock additionally serializes a manual `run-due` against the daemon.
- Scheduled commands run via `zsh -lc` from your home directory, using the
  `PATH` captured at install time (so they find conda / homebrew / `~/.local/bin`
  tools, just like your interactive shell).
- Command, label, stdout and stderr are stored **base64-encoded** in the DB, so
  arbitrary shell text never has to be escaped into SQL.

## Files & locations

| Path | What it is |
|---|---|
| `~/.local/bin/betterat` | the installed script (this file) |
| `~/.local/share/betterat/betterat.db` | SQLite job database |
| `~/.local/share/betterat/daemon.out` / `.err` | launchd stdout/stderr |
| `~/Library/LaunchAgents/com.minh.betterat.plist` | the per-user agent |

## Note on precision

Execution lands within one daemon tick of the scheduled time (default 15s).
`-at`/`-in` record the exact intended Unix second; nothing fires early. Lower the
tick with `install --interval N` (min 10; launchd throttles faster agents).
