# Foreman Uplink

Menu-bar app that keeps a reverse SSH tunnel to the foreman orchestrator alive, forever —
and **owns the whole contract**: it provisions both machines itself, idempotently.

- **❇️** = healthy: ssh transport alive AND foreman's web UI answers (one HTTP probe
  through a local forward riding the *same* ssh connection — a zombied link can't fake
  green) AND this Mac's sshd is on.
- **❌** (pulsing) = down. Respawns ssh every 2 s, probes every 2 s, kills a zombied
  connection after 3 straight failed probes, reconnects immediately on wake. Forever.
  Nothing is logged anywhere; the only persisted state is the two settings.

## Configuration (menu → Configure…)

1. **Foreman URL** (default `http://100.59.145.138:8700`) — its host is the ssh target,
   its port is what the health probe hits.
2. **This Mac's name on foreman** (default: the Mac's hostname, e.g. `mac`).

## Self-provisioning (on every launch and every Save)

The app converges, never duplicates:

- **Mac side:** generates `~/.ssh/foreman_tunnel` keypair if missing; appends the
  `Host foreman-tunnel` ssh-config block if missing; installs foreman's agent pubkey in
  `~/.ssh/authorized_keys` restricted to `from="127.0.0.1,::1"` (tunnel-only).
- **foreman side** (over the user's existing `Host foreman` admin alias; the tunnel key
  itself deliberately cannot exec): generates `~/.ssh/mac_agent_key` if missing;
  (re)writes the tunnel key's authorization with
  `restrict,port-forwarding,permitlisten="127.0.0.1:<port>"`; installs the sshd
  keepalive drop-in; (re)writes a marker-delimited `Host <name>` block.

The reverse-tunnel **port is derived deterministically from the name** (djb2 → 2200-2899,
e.g. `mac` → 2298), so several Macs can each self-register (`ssh mac`, `ssh workmac`, …)
with their own keys and ports, no collisions, no coordination.

## Result on foreman

```
ssh <name> <command>     # e.g. `ssh mac hostname` — works whenever the menu bar is ❇️
```

That's the persistent endpoint agents (and eventually the mngr ssh provider) use.

## Permissions + capability relay (menu → Request Permissions…)

Commands run via `ssh <name> <cmd>` are attributed by TCC (macOS's privacy gatekeeper)
to sshd's own responsible process — and macOS **refuses to ever prompt** for that
identity ("does not allow prompting", permanently denied). So `ssh mac screencapture ...`
can never work no matter what's granted; there's no dialog for sshd to click Allow on.

**Request Permissions…** instead asks for Screen Recording + Accessibility for
**this app** (a real, promptable, WindowServer-attached process — the one identity
in the whole path that CAN be prompted). The app then also runs a tiny HTTP relay on
`127.0.0.1:18701`, bearer-token-gated (token at `~/.foreman-uplink/relay.token`,
0600), so remote ssh commands can ask *this process* to do the privileged thing
instead of trying it themselves:

```
TOKEN=$(ssh <name> cat ~/.foreman-uplink/relay.token)
ssh <name> curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18701/screenshot -o shot.png
ssh <name> curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:18701/health   # {"screenRecording":bool,"accessibility":bool}
ssh <name> curl -s -H "Authorization: Bearer $TOKEN" -X POST --data 'hello' http://127.0.0.1:18701/type
ssh <name> curl -s -H "Authorization: Bearer $TOKEN" -X POST 'http://127.0.0.1:18701/click?x=100&y=200'
```

Screen Recording takes effect immediately; Accessibility may need one relaunch of
the app after granting (menu → Quit, then reopen) before `/type` and `/click` work.

## Requirements

- Mac: Remote Login ON (System Settings › Sharing). The app checks and reports in the
  status line if it's off.
- Mac: a working `Host foreman` admin alias in `~/.ssh/config` (used only for
  provisioning, never in the steady-state loop).

## Install / uninstall

```
sudo ./install.sh      # build+sign as you (../sign-identity.sh ladder: $CODESIGN_IDENTITY
                       # → Developer ID → stable self-signed → ad-hoc), deploy ROOT-OWNED
                       # to /Applications, migrate old installs, relaunch
sudo ./uninstall.sh    # remove the app; ssh keys + foreman-side config are left intact
```

Root-owned `/Applications` install matters: it's what makes demonlock's spare-list entry
(`com.minh.foreman-uplink`) hold on identifier alone, regardless of signing identity.
`./build.sh` alone builds+signs `ForemanUplink.app` into this directory without deploying.
