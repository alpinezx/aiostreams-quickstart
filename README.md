# AIOStreams Quick Setup

A one-command installer for a self-hosted [AIOStreams](https://github.com/Viren070/AIOStreams) instance — Docker, Caddy (automatic HTTPS via Let's Encrypt), and basic auth protecting the configure/dashboard pages, all in one script.

## What this gives you

- Your own AIOStreams instance, not a shared public one
- HTTPS out of the box, auto-renewing, no manual cert wrangling
- Login-protected homepage/configure/dashboard — nobody else can create configs on your instance or see your setup
- Built-in management menu for status, restart, updates, reconfiguration, and clean uninstall

## Prerequisites

- A fresh Ubuntu or Debian VPS (any provider)
- A domain or subdomain you control, with an **A record already pointed at your server's IP** before running the script
- Root access

## Quick start

```bash
curl -fsSL https://raw.githubusercontent.com/alpinezx/aiostreams-quickstart/refs/heads/main/setup-aiostreams.sh -o setup-aiostreams.sh && sudo bash setup-aiostreams.sh
```

The script will ask you for:
1. Your domain/subdomain
2. A username and password for logging into the instance

Everything else — Docker install, HTTPS certificate, secret key generation — is handled automatically.

Once it finishes, visit your domain, log in, and you're in AIOStreams. From there:

1. **Services** → add your debrid provider's API key (e.g. TorBox)
2. **Addons → Marketplace** → enable at least one scraper (Torrentio, Comet, MediaFusion, etc.), defaults are fine
3. Copy the install link and add it to Stremio

That's the whole required setup. Filters, sorting, subtitles, and extra addons are all optional — tune those to your own preference whenever you like.

## Re-running the script later

Run it again any time from the same directory (`~/aiostreams`) and it'll detect your existing install and offer:

```
1) View status
2) Restart services
3) Update (pull latest images + restart)
4) Reconfigure (change domain/login — backs up your current config first)
5) Uninstall (clean removal)
6) Exit
```

## Notes

- Your `SECRET_KEY` is generated on first install and saved to `~/aiostreams/CREDENTIALS.txt` — move it somewhere safe and delete it from the server. It can't be changed later without invalidating stored configs, and it's automatically preserved across any future Reconfigure runs.
- The Caddy login only protects the homepage, `/stremio/configure`, and `/dashboard`. Your installed Stremio addon keeps working uninterrupted, since stream/manifest URLs aren't behind that login wall.
- Tested through fresh install, cert reuse on reinstall, and all six management menu options.
