# TailGuard

Keep **Tailscale** working on macOS when a VPN messes with your routing table.

Some VPNs (and especially anti-censorship VPNs that get toggled on and off) leave
the routing table in a state where Tailscale can no longer reach its **control
plane** or **DERP relays** — so it gets stuck on *"Starting…"* or silently can't
connect. TailGuard fixes this by **pinning Tailscale's infrastructure traffic to
your physical uplink**, so it always bypasses the VPN-induced breakage.

It's a tiny, event-driven background daemon. Pure `bash` + built-in macOS tools.
**No dependencies, no Homebrew, no config.**

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/<you>/tailguard/main/install.sh | sudo bash
```

or clone and run:

```bash
sudo ./install.sh
```

That's it. The daemon starts immediately and on every boot.

## Commands

```bash
sudo ./install.sh status      # daemon state + current routes + recent log
sudo ./install.sh uninstall   # remove the daemon and scripts
tail -f /var/log/tailguard.log
```

## How it works

1. A LaunchDaemon runs `route-monitor.sh`, which listens to the kernel routing
   socket via `route -n monitor`.
2. When a **relevant** routing change happens (default route changes, an interface
   goes up/down, or anything touches Tailscale's control-plane subnet), it waits
   ~2s for the change storm to settle (debounce), then runs `fix-routes.sh` once.
3. `fix-routes.sh` pins the bypass set to the current **physical** default gateway:
   - **DERP relays** — fetched live from Tailscale's DERP map.
   - **Control plane** — `192.200.0.0/24` (owned by Tailscale Inc.) plus whatever
     `controlplane.tailscale.com` / `login.tailscale.com` currently resolve to.
   - Any stale `/32` host routes a VPN injected into those subnets are removed.
4. When nothing is wrong it's a **silent no-op**. Idle machines do zero work and
   write zero log lines — the daemon just sleeps on the routing socket.

Typical cost: **0** activity when idle; **one** fix run (and one log line) per real
network change.

## Limitations — read this

TailGuard works by **steering routes**, so it can only help when routing is the
problem:

- **Full-tunnel kill-switch VPNs are NOT supported.** Mullvad, Proton, NordVPN
  etc. with a kill-switch use a packet *firewall* (`pf`) to drop all non-tunnel
  traffic. Route changes can't get around a firewall — the packets are dropped,
  not misrouted. TailGuard detects when the default route is on a tunnel
  interface and **safely does nothing** rather than break things.
- **It pins to whatever your physical default gateway is.** It's designed for
  VPNs that don't hold the default route (split-tunnel) or that leave stale routes
  behind after disconnecting. If a VPN owns the default route, TailGuard steps
  aside.
- **macOS only.** It uses `route monitor`, `netstat`, and BSD `route` semantics.
- **Runs as root.** It edits the system routing table; that requires root. All it
  ever changes are host/subnet routes for Tailscale's published IP ranges.

## What it installs

| Path | What |
|------|------|
| `/Library/Application Support/tailguard/fix-routes.sh` | the route-pinning logic |
| `/Library/Application Support/tailguard/route-monitor.sh` | the event-driven daemon |
| `/Library/LaunchDaemons/com.tailguard.monitor.plist` | LaunchDaemon (RunAtLoad + KeepAlive) |
| `/var/log/tailguard.log` | activity log (only real changes) |

Uninstall removes all of the above except the log.

## License

MIT.
