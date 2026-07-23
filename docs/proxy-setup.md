# Proxy Setup (built-in AIOStreams proxy)

## What this is for

Some ISPs block or throttle direct connections to debrid services (TorBox,
Real-Debrid, etc.), causing streams to fail to load or time out — sometimes
inconsistently, since only *some* IP ranges get flagged. If you've noticed
that a VPN "fixes" playback, this is usually why.

Rather than running a VPN client on every playback device, you can route just
the debrid traffic through your own VPS instead. Your VPS fetches the stream
from the debrid service and relays it to your device — since your VPS has its
own clean IP, it sidesteps the same blocking a home ISP connection runs into.

This is a feature built into AIOStreams itself (not something this script
installs) — this doc just covers where to find it and how to set it up
sensibly.

---

## Important: this is per-config, not instance-wide

The proxy setting lives inside your saved AIOStreams config (the same JSON
object you'd get from Export Config), not in the container's environment
variables. Enabling it once does **not** apply automatically to every config
you might create in the future — if you ever build a second config from
scratch (rather than editing your existing one), you'll need to enable the
proxy on that config too.

For a typical single-user setup, you'll only ever have one config, so this
is a one-time step.

---

## Enabling it

1. Open your AIOStreams configure page and log in.
2. Go to the **Proxy** settings page (found alongside Deduplicator, Result
   Limits, etc.).
3. Toggle **Enable**.
4. Leave **Proxy Service** as `Builtin Proxy` — no separate proxy software
   needed, it runs as part of the AIOStreams container itself.
5. **Credentials**: only required if you set `AIOSTREAMS_AUTH` on your
   instance (this project's setup script always sets this). Enter the same
   `username:password` pair from your login here — it's not a new/separate
   credential, just confirming the one already configured.
6. **Public IP**: leave blank. This is only relevant if you're running the
   Builtin Proxy locally behind a separate proxy server — not the case for a
   standard remote VPS install like this one.
7. Under **Proxy Controls → Proxied Services**, select your debrid
   service(s) (e.g. TorBox). This scopes proxying to just that service's
   streams, rather than proxying everything.
8. Leave **Proxied Addons** empty so the scoping is handled by the service
   filter above.
9. Save.

Test it by loading a stream that previously failed, with any client-side VPN
turned off. If it loads, the proxy is doing its job.

---

## Bandwidth note

Unlike the rest of what this project sets up, proxied streams route actual
video data through your VPS, not just lightweight config/API traffic. Keep
an eye on your VPS provider's bandwidth allowance if you use this heavily —
this is the one part of the setup that can meaningfully add to your monthly
data usage.
