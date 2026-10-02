# monitor-heartbeat

Tells you a long-running job is still alive, by watching only its log file.

```sh
cmd > /tmp/job.log 2>&1 &            # however you launch it
monitor-heartbeat /tmp/job.log       # one line per tick, forever
```

```
heartbeat build.log | 6m12s since start | quiet 3s | +47 lines | check on things and give report.
    Compiling serde v1.0.210
    Compiling tokio v1.40.0
heartbeat build.log | 1h07m27s since start | quiet 5m01s | +0 lines | hung, or just buffering? check on things.
```

Each tick streams what the job wrote since the previous one, at most `--tail` lines, with
the true count. `+47 lines` with 3 shown means go read the log; `+3` with 3 shown means you
have everything. A single final line was tried first and is not enough — the last line of a
traceback is `^^^^^`, and of a progress bar is a fragment.

A freshly armed watcher has no previous tick, so it says `arming` and shows the tail of
what is already there rather than relabelling old output as new.

| flag | default | meaning |
| :- | :- | :- |
| `--every` | `75` | seconds between heartbeats, 1–180 |
| `--tail` | `50` | most lines of new output to show per tick |
| `--pid` | — | also report when that pid is gone, which silence cannot tell you |
| `--quiet-after` | `300` | seconds of no growth before the line says `hung?` |

## Why it exists

A long job either blocks you — nothing else can happen, and you cannot see progress — or
runs detached and invisible, where a hang looks exactly like work. Starting it is solved
many times over; knowing it is *still healthy* is not. Every background-job runner just
does start/stop/status/output.

So this does one thing: liveness. `quiet` is the whole point — a job that has written
nothing for five minutes is either finished, wedged, or about to disappoint you.

## Buffering will fool it, and the obvious fixes do not work

`quiet` measures **flush cadence**, not progress. A job printing steadily into an 8 KiB
stdio buffer writes nothing to the file for minutes, and reads as hung. Measured here, a
healthy job printing one 18-byte line per second:

| how it is launched | max `quiet` over 75s | log after 75s |
| :- | -: | -: |
| `python3 job.py > log` | **75s** | **0 bytes** |
| `python3 -u job.py > log` | 0s | 1300 bytes |
| `python3 -u job.py \| grep -v X > log` | **75s** | **0 bytes** |
| `python3 -u job.py \| tee /dev/null > log` | 0s | 1300 bytes |
| `stdbuf -oL python3 job.py > log` | **75s** | **0 bytes** |

Two traps in that table. `-u` does **not** survive a later pipe stage — `grep` re-buffers,
so every stage needs its own flag. And `stdbuf` does **nothing** for Python, which sets its
own buffering after the `LD_PRELOAD` has taken effect.

What actually works:

```sh
python3 -u job.py > log 2>&1              # or PYTHONUNBUFFERED=1
… | grep --line-buffered pattern >> log   # every grep in the pipeline
… | awk '{print; fflush()}' >> log        # every awk
stdbuf -oL ./compiled-program > log 2>&1  # C/Go/Rust only, not Python
```

This is why the `hung?` line says `hung, or just buffering?` — check which before you
conclude anything. A buffered job also fools it the other way: an 8 KiB flush resets
`quiet` to 0, so a job that dies right after a flush looks healthy for a while.

## How it works

- **`since start`** is measured from the log's **birth time**, not from when this process
  started. A second watcher armed an hour later reports the same elapsed, so restarting a
  watch is free and does not lie.
- **`quiet`** is time since the log's mtime last changed. Redirect both streams
  (`> log 2>&1`) or a job failing only on stderr will look silent.
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
