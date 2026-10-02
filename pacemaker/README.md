# pacemaker

Turn a command that is normally a silent wait into one that pings you.

Built to be run **by Monitor**, which executes it and turns every line it prints into a
notification. In a plain shell it works but it is talking to nobody.

```
Monitor(pacemaker --slug build -- make -j8)        a job
Monitor(pacemaker --slug ci --every 120)           a bare reminder, no command
Monitor(pacemaker --slug build --attach)           resume after Monitor expires
```

| flag | default | |
| :- | :- | :- |
| `--slug` | required | names the run. You choose it, so you can always `--attach` |
| `--every` | `75` | seconds between pings, max 300 |
| `--timeout` | none | kill the job after this many seconds, max 1800 |
| `--attach` | | resume watching a run that is already going |

## What it does

**Under 60 seconds it says nothing**, then hands back the whole result:

```
build completed in 12s with exit code 0.
hello
stderr:
a warning
```

So for anything short it behaves like running the command directly. Past 60 seconds it
starts reporting, and keeps whatever the job wrote attached to the ping:

```
Heartbeat. build running for 4m12s.
Compiling serde v1.0.210
Compiling tokio v1.40.0
```

```
Heartbeat. build running for 9m30s. Quiet for 5m01s. Is this hung, or is there a problem?
```

stdout is unlabelled, stderr goes under `stderr:`. At most 50 lines per stream per ping,
keeping the head as well as the tail — a burst's phase markers are at the front, and forty
trailing `ok` lines are its least informative slice.

**Eager by default.** It pings when a burst *settles* (1.5s of quiet), not on a clock —
with a floor of `--every / 3` so a chatty job cannot storm you, and a ceiling of `--every`
so a silent one still reports. Set `--every` to what you can stand hearing from.

## Surviving Monitor

Monitor caps at 30 minutes and kills what it is running. pacemaker dies; **the job does
not**. It is double-forked and reparented to init, so when the expiry notice arrives:

```
Monitor(pacemaker --slug build --attach)
```

picks it back up — elapsed still measured from the real start, and nothing in the gap is
lost, because the job has been writing to files the whole time.

A new session alone is *not* enough here, which is the non-obvious part: this harness kills
the process **tree**, and while pacemaker is still the job's parent the walk finds it
whatever session it is in. Measured — the job died. Hence two forks, not one.

## Where things go

```
~/.pacemaker/<slug>/stdout      the job's stdout
~/.pacemaker/<slug>/stderr      its stderr
~/.pacemaker/<slug>/exit        appears when it finishes, holds the code
~/.pacemaker/<slug>/meta        pid, start time, the command
~/.pacemaker/<slug>-<when>/     the previous run under this slug, kept
```

Not `/tmp`: these outlive the run and `grep` works on them later. Pruning happens between
runs — older than 7 days, or oldest-first above 500 MB — and **only ever touches runs that
have an `exit` file**. A live run's directory cannot be deleted out from under it, which
matters because a job whose directory vanishes keeps writing into an unlinked inode and can
never report that it finished.

## Buffering will fool it

`quiet` measures when the log last grew, which is flush cadence, not progress. A job
printing steadily into an 8 KiB stdio buffer writes nothing for minutes and reads as hung.

pacemaker launches everything under `stdbuf -oL -eL` with `PYTHONUNBUFFERED=1`, which
covers libc programs and Python — note `stdbuf` alone does **nothing** for Python, and
`python3 -u` does **not** survive a later pipe stage. Go and Java still buffer on their own
terms. That is why the line asks *"Is this hung, or is there a problem?"* rather than
asserting it.

## Killing a run

`--timeout` does it on a clock. By hand:

```sh
kill -TERM -$(python3 -c "import json;print(json.load(open('$HOME/.pacemaker/build/meta'))['pid'])")
```

The negative matters: the job is its own process-group leader, and killing the bare pid
orphans the command underneath it.

## Install

```sh
./install.sh      # one file to ~/.local/bin, no sudo
./test.sh         # behavioural checks — run these on each machine
./uninstall.sh
```
