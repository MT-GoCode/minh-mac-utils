# gitas

One git identity manager for every machine. **The only tool in this repo that also runs on Linux** —
no sudo, no launchd, no bundle.

All GitHub auth goes over **HTTPS with a PAT**. git never stores a token: gitas *is* the credential
helper and reads `~/.config/gitas/accounts.ini` (0600, never committed) on each request.

## Why

Three identity mechanisms used to run in parallel and disagree — SSH host aliases, a global
`user.email`, and `gh`'s active account. The failure was silent: a work repo committing under a
personal email, or an SSH alias that authenticated as the wrong account because **GitHub refuses the
same key on two accounts**, so the "work" key was never actually registered as work.

gitas collapses all of it to one file. **Identity and auth are driven by the same trigger — the
remote URL — so they cannot drift apart.**

## Install

```bash
cp accounts.example.ini ~/my-accounts.ini    # fill in emails, usernames, PATs
./install.sh ~/my-accounts.ini
```

The installer **purges first**: global git user/credential config, `~/.config/gh`, `github.com`
keychain entries, and the GitHub `Host` blocks in `~/.ssh/config`. Every other SSH host and **every
SSH key is left untouched** — those are infrastructure, not GitHub identity.

Re-run any time after editing the config:

```bash
gitas install          # regenerate from ~/.config/gitas/accounts.ini — idempotent
./install.sh --keep-config
```

## Config

```ini
[personal]                                  # FIRST section = default
name  = Minh Trinh
email = tminh.us@gmail.com
user  = MT-GoCode
token = ghp_xxx
match = github.com/MT-GoCode/*

[work]
name  = Minh Trinh
email = minh@datologyai.com
user  = minh-datology
token = github_pat_xxx
match = github.com/datologyai/*
```

`match` is comma-separated `host/path` globs. Anything unmatched falls through to the default — so
cloning another org's repo *for personal reasons* needs no entry at all.

The PAT lives in this file rather than the macOS Keychain on purpose: Keychain is macOS-only, and
this has to work on Linux too. One 0600 file, copied per machine, is the portable answer.

## Commands

| Command | What |
|---|---|
| `gitas init` | scaffold `~/.config/gitas/accounts.ini` |
| `gitas install` | regenerate git config — idempotent |
| `gitas list` | accounts (first = default) |
| `gitas status` | which account applies in this repo, and why |
| `gitas give-pat <slug>` | print that account's PAT |
| `gitas exec <slug> -- CMD` | run CMD with `GH_TOKEN` + author identity set |
| `eval "$(gitas use <slug>)"` | force an account for **this shell only** |
| `eval "$(gitas off)"` | drop the override |
| `gitas purge` | remove all git identity state outside gitas |

Three layers, coarse to fine: **default account** → **`match` rule** → **`gitas use` / per-repo
`git config`**. Each beats the one before it.

## gh

`gh` stays installed; only its stored logins are removed. Drive it per-account:

```bash
gitas exec personal -- gh release create v1.0 dist/*.zip
```

`GH_TOKEN` takes precedence over gh's stored credentials, so no `gh auth login` is ever needed.
This is what the signed-bundle release step in the top-level README uses.

## How it works

`gitas install` writes `~/.config/git/gitas.inc` and adds one `include.path` to `~/.gitconfig`
(your own aliases there survive regeneration). The generated file:

- sets the default account's `user.name` / `user.email`
- sets `credential.useHttpPath = true` — **load-bearing**: without it git matches credentials by
  *host* only, both accounts collide on `github.com`, and you're back to manual switching
- resets `credential.helper` to empty, then points it at `gitas credential`
- emits **two** `includeIf hasconfig:remote.*.url:` patterns per non-default org —
  `**/<org>/**` and `*:<org>/**`. Both are needed: `**` only spans separators when it is its own
  path component, so the first matches `https://` and `ssh://` URLs and the second matches the
  SCP form `git@github.com:org/repo`. Miss one and routing silently does nothing.

## Uninstall

```bash
./uninstall.sh                  # keeps ~/.config/gitas/accounts.ini (your PATs)
./uninstall.sh --purge-config   # deletes it too
```

Afterwards git has **no** identity configured — set one manually or reinstall.
