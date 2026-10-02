# monitor-heartbeat

Tells you a long-running job is still alive, by watching only its log file.

```sh
cmd > /tmp/job.log 2>&1 &            # however you launch it
monitor-heartbeat /tmp/job.log       # one line per tick, forever
```

```
heartbeat 6m12s since start | quiet 3s | check on things and give report.
heartbeat 1h07m27s since start | quiet 5m01s | hung? check on things.
```

| flag | default | meaning |
| :- | :- | :- |
| `--every` | `75` | seconds between heartbeats |
| `--quiet-after` | `300` | seconds of no growth before the line says `hung?` |

## Why it exists

A long job either blocks you — nothing else can happen, and you cannot see progress — or
runs detached and invisible, where a hang looks exactly like work. Starting it is solved
many times over; knowing it is *still healthy* is not. Every background-job runner just
does start/stop/status/output.

So this does one thing: liveness. `quiet` is the whole point — a job that has written
nothing for five minutes is either finished, wedged, or about to disappoint you.

## How it works

- **`since start`** is measured from the log's **birth time**, not from when this process
  started. A second watcher armed an hour later reports the same elapsed, so restarting a
  watch is free and does not lie.
- **`quiet`** is time since the log last grew. Redirect both streams (`> log 2>&1`) or a
  job failing only on stderr will look silent.
- It never exits on its own, holds no state, writes no files, and does not know what a
  process is. Stop it with a signal.

Two things were tried and rejected. `ps -o etimes=` does not exist on macOS. `ps -o etime=`
returns garbage inside LXC — ox-dev reports elapsed times of 441 million days — because the
container's `/proc` boot time disagrees with the host's. File birth time is correct on both
(`stat -c %W` on Linux, `stat -f %B` on macOS), and that one `case` is the only
platform-dependent line in the tool.

If the filesystem does not record birth times, it falls back to first sighting: elapsed
restarts when a watcher does. Degraded, not wrong.

## Install

```sh
./install.sh      # copies one file to ~/.local/bin, no sudo
./uninstall.sh
```
