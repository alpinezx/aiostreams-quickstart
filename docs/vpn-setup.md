# VPN Setup (optional — server-side WireGuard via gluetun)

## What this is for

The [Proxy Setup](./proxy-setup.md) guide covers routing debrid traffic
through your VPS to dodge ISP blocking. This guide covers the next layer:
what to do if your **VPS's own IP** ever gets blocked too.

`setup-vpn-gluetun.sh` adds an optional VPN tunnel that only the AIOStreams
container uses. Flip it on, and AIOStreams' outbound traffic (to TorBox,
scrapers, etc.) exits through a WireGuard VPN server instead of your VPS's
own IP. Flip it off, and it goes back to exiting through your VPS directly.

**Read this before anything else:** this cannot lock you out of your
server. SSH, Caddy, and everything else stay on your VPS's normal network
the entire time — only the AIOStreams container's traffic is ever affected.
See [How it works](#how-it-works) below if you want the full explanation.

---

## Prerequisites

- This project's main setup already run (`setup-aiostreams.sh`) — you need
  a working AIOStreams install first.
- A VPN provider that supports **WireGuard**, with a way to export a
  `.conf` config file (most major providers support this — check their
  site or app for an "advanced," "manual setup," or "WireGuard" section).
- That `.conf` file uploaded somewhere on the VPS (SFTP works fine — see
  [Getting your config onto the server](#getting-your-config-onto-the-server)).

---

## Getting a WireGuard config from your VPN provider

Steps vary by provider, but you're looking for a **WireGuard configuration
file** (not their regular desktop app installer). Most providers offer this
under an "advanced," "manual setup," or "router setup" section of their
site or app, often letting you generate one for a specific server/location.

⚠️ **Test the file works before uploading it to the VPS.** Import it into
any WireGuard-compatible client on your desktop first (the official
WireGuard app, or a third-party client) and confirm it connects. This
confirms the file itself is valid before we involve Docker at all — if
something's wrong, it's much easier to diagnose on a desktop client than
inside a container.

If you test it locally, **disconnect it on your desktop before running it on
the VPS** — using the identical key from two places at once can cause the
provider to disconnect one side.

---

## Important: gluetun needs an IP, not a hostname

Open your `.conf` file and look at the `Endpoint =` line under `[Peer]`.

If it looks like this, you're fine:
```
Endpoint = 212.15.80.116:51820
```

If it looks like this, you have one extra step first:
```
Endpoint = new-york.us.wg.someprovider.net:51820
```

gluetun's custom-provider mode requires a literal IP address here —
domain/hostnames aren't supported (this is a known gluetun limitation, not
a bug in this script). Resolve it once and edit the file:

```bash
dig +short new-york.us.wg.someprovider.net
```

Take the IP that comes back and replace the hostname in the `Endpoint` line,
keeping the port (`:51820`) as-is.

**Worth knowing:** some providers' regional hostnames (like the example
above) load-balance across a pool of servers, so the specific IP you
resolve today isn't guaranteed to stay the one you'd get resolving it again
in future. If the tunnel ever mysteriously stops connecting months from
now, re-running `dig` and updating the endpoint is the first thing to check.
Provider hostnames that point at one specific server (rather than a
regional pool) don't have this issue.

---

## Getting your config onto the server

Any file transfer method works — SFTP (e.g. via Termius, FileZilla, WinSCP)
is the easiest for most people. Drop the `.conf` file directly into your
home directory on the server, e.g. `/root/myvpn.conf`. No special folder
needed, just remember the path — you'll be asked for it.

---

## Installing the script

From the same directory as your AIOStreams install (`~/aiostreams`):

```bash
cd ~/aiostreams
curl -fsSL https://raw.githubusercontent.com/alpinezx/aiostreams-quickstart/refs/heads/main/setup-vpn-gluetun.sh -o setup-vpn-gluetun.sh
chmod +x setup-vpn-gluetun.sh
sudo ./setup-vpn-gluetun.sh
```

## First-time setup

The first run detects it hasn't been configured yet and walks you through
setup automatically:

1. Reads your existing domain/login straight out of your current
   `docker-compose.yml` — nothing to re-enter.
2. Asks for the path to your `.conf` file (from the step above).
3. Backs up your current config.
4. Builds both a "direct" and a "VPN" version of your stack, and switches
   you into VPN mode.
5. Waits for the tunnel to connect and shows you gluetun's detected exit IP.

If the tunnel doesn't confirm within the wait period, the script tells you
exactly which log command to check and which commands would roll you back.

## Day-to-day usage

Run the script again any time and you'll get a menu instead of the setup
flow:

```
1) Status
2) Turn VPN ON
3) Turn VPN OFF (direct connection)
4) Reconfigure VPN (change WireGuard server/config)
5) Exit
```

- **Status** — shows current mode, container health, and (in VPN mode)
  gluetun's live exit IP.
- **Turn VPN ON / OFF** — instantly swaps between your two saved configs and
  restarts the stack (a few seconds of downtime either way).
- **Reconfigure** — swap in a different `.conf` file (e.g. a different
  country/server) without redoing the whole setup.

---

## Verifying it's actually working

From the VPS terminal:

```bash
# Your VPS's own IP — should NOT change, ever, regardless of VPN mode
curl ifconfig.me

# The AIOStreams/gluetun container's IP — changes based on VPN mode
docker exec gluetun wget -qO- ifconfig.me/ip
```

In VPN mode, these two should be different. In direct mode, they'll match
(since without the tunnel, the container just uses the VPS's own IP).

Then confirm end to end: load `https://yourdomain`, log in, and try a stream
that previously needed a client-side VPN to work, with any VPN on your
playback device turned off.

---

## How it works

Two independent things are happening on your server, and it helps to think
of them as separate rooms in the same building:

- **The host** (SSH, Caddy, the firewall, the VPS itself) — always on your
  VPS's normal IP. None of this setup ever touches it.
- **The AIOStreams container** — shares its network with the `gluetun`
  container (`network_mode: "service:gluetun"` in Docker terms). When VPN
  mode is on, this whole bubble's outbound traffic exits through gluetun's
  WireGuard tunnel. When it's off, this bubble just uses the VPS's own
  network like everything else.

Because SSH was never part of that bubble, toggling VPN mode on/off can
never affect your ability to access the server — worst case if something's
wrong with the tunnel is that AIOStreams itself stops responding, which you
fix by switching back to direct mode from the menu.

## Relationship to the Proxy setting

This VPN layer only affects traffic that already passes through your VPS.
If the [built-in AIOStreams proxy](./proxy-setup.md) is turned **off**,
playback devices connect to your debrid service directly — bypassing your
VPS (and therefore gluetun) entirely for that traffic. The proxy needs to
be on for VPN mode to have any effect on your actual stream playback.

---

## Troubleshooting

**"Couldn't confirm the tunnel came up" / status shows unhealthy**
Check the raw logs: `docker compose logs gluetun`. Look for connection
errors near the `[wireguard] Connecting to ...` line. A stale endpoint IP
(see the hostname section above) is the most common cause.

**Orphan container warnings when switching modes**
Already handled — the script uses `docker compose down --remove-orphans`
so switching to direct mode fully stops gluetun rather than leaving it
idling in the background.

**Rolling back entirely**
Choose option 3 (Turn VPN OFF) from the menu — this returns you to a plain
AIOStreams + Caddy stack, identical to before this script ever ran.
