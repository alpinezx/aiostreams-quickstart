# AIOStreams Quick Setup

A one-command installer for a self-hosted [AIOStreams](https://github.com/Viren070/AIOStreams) instance — Docker, Caddy (automatic HTTPS via Let's Encrypt), and AIOStreams' built-in login locking config creation to you alone, all in one script.

## What this gives you

- Your own AIOStreams instance, not a shared public one
- HTTPS out of the box, auto-renewing, no manual cert wrangling
- **App-level login** (AIOStreams' own auth): the configure page, dashboard, *and the config API itself* all require your username/password — nobody else can create or edit configs on your instance, even if they talk to the API directly
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

Once it finishes, visit your domain and log in via AIOStreams' login page. From there:

1. **Services** → add your debrid provider's API key (e.g. TorBox)
2. **Addons → Marketplace** → enable at least one scraper, defaults are fine
3. Copy the install link and add it to Stremio

That's the whole required setup. Filters, sorting, subtitles, and extra addons are all optional — tune those to your own preference whenever you like.

## How the protection works

The script sets two environment variables on the AIOStreams container:

- `AIOSTREAMS_AUTH=youruser:yourpassword` — defines the only valid login
- `AIOSTREAMS_AUTH_REQUIRED=true` — makes that login mandatory for the configure page, and enforces a config access key on every config create/update

Because this is enforced *inside the application*, it covers the API routes too — not just the web pages a reverse-proxy password would cover. Your installed Stremio addon keeps working uninterrupted: its access key is embedded in your config's manifest URL.

Caddy's job in this setup is purely HTTPS + reverse proxying. There is no separate proxy-level password to remember.

## Re-running the script later

Run it again any time from the same directory (`~/aiostreams`) and it'll detect your existing install and offer:

```
1) View status
2) Restart services
3) Update (pull latest images + restart)
4) Reconfigure (change domain/login — backs up your current config first)
5) Uninstall (clean removal)
6) Check / set up swap space (recommended for servers with less than 1GB RAM)
7) Exit
```

## Notes

- Your `SECRET_KEY` is generated on first install and saved to `~/aiostreams/CREDENTIALS.txt` — move it somewhere safe and delete it from the server. It can't be changed later without invalidating stored configs, and it's automatically preserved across any future Reconfigure runs.
- Your login username/password also live in `~/aiostreams/docker-compose.yml` (that's how AIOStreams reads them at startup). The script sets that file to root-only (`chmod 600`). To change the password later, use the Reconfigure menu option, or edit the `AIOSTREAMS_AUTH` line and run `docker compose up -d`.
- If you had already created a config *before* enabling this protection, open the configure page once, log in, and hit **Save** so your config picks up the access key.
- Passwords are limited to letters, numbers, and `@ % ^ * _ + = . ! ? -` — other symbols would break the `user:pass` environment format.

## Further hardening (optional)

- [Security & Hardening](./docs/security-hardening.md) — SSH key-only login, fail2ban, and UFW. Read the disclaimers before running anything.
