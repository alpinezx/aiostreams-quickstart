## 0. How these steps fit with the built-in protection

The setup script already gives you the most important layer: AIOStreams' own
login (`AIOSTREAMS_AUTH` + `AIOSTREAMS_AUTH_REQUIRED=true`). That locks config
creation and editing — the web pages *and* the underlying API — behind your
username and password, and the app rate-limits its login endpoint (5 attempts
per 5-minute window per IP by default), so brute-forcing the web login is
impractical.

The steps below harden a different attack surface: **the server itself**,
mainly SSH on port 22. Think of it as layers that don't overlap:

| Layer | Protects | Provided by |
| --- | --- | --- |
| App login + rate limiting | AIOStreams configs & dashboard (web + API) | Setup script (already done) |
| HTTPS | Traffic between you and the server | Caddy (already done) |
| SSH key-only login | Server shell access | Section 1 below |
| fail2ban | SSH brute-force noise | Section 2 below |
| UFW | Accidentally exposed ports | Section 3 below |

None of the sections below are required for the AIOStreams protection to work —
they're about keeping the VPS itself tidy and hard to break into.

---

## 1. Disable SSH password login (key-only + root login lockdown)

> Tested on Ubuntu 26.04 LTS ("Resolute Raccoon"). Steps should be similar on other Debian-based distros, but file paths/behavior may differ slightly — proceed carefully if you're on something else.

⚠️ **Read this before doing anything.** This makes SSH refuse password logins entirely — only your SSH key will work afterward. If your key isn't working correctly for any reason, you can lock yourself out of your own server. Follow the safety checks at every step; don't skip them.

### Before you start

- Confirm you can currently SSH in using a **key**, not a password.
- Keep your current terminal session open throughout this whole process. Don't close it until everything is fully tested and working in a **separate, new** session.
- Some VPS providers layer their own SSH password toggle in the control panel on top of the server's own config — check there too if changes to `sshd_config` don't seem to take effect.

### 1a. If you don't have a key on the server yet

If you reinstalled the OS after originally adding a key in your provider's control panel, the reinstall may not have carried it over — some providers only inject the key at first install, not on reinstall. Check first:

```bash
cat ~/.ssh/authorized_keys
```

If that's empty or missing, and you already have an SSH key pair on your own machine (don't generate a new one if you don't need to — reuse your existing one), add your **existing public key** manually while you're still logged in with the password:

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "ssh-ed25519 AAAA...your-full-key... your-comment" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
cat ~/.ssh/authorized_keys   # confirm it's there
```

Grab your public key from your local machine first if you don't have it handy: `cat ~/.ssh/id_ed25519.pub` (Mac/Linux) or `type $env:USERPROFILE\.ssh\id_ed25519.pub` (Windows PowerShell). Then test logging in via key in a **new** terminal/tab before continuing — don't move on to disabling password login until key-based login is confirmed working.

### Steps

1. Edit the main config:
```bash
   sudo nano /etc/ssh/sshd_config
```

2. Find and set:
```bash
PermitRootLogin prohibit-password
PasswordAuthentication no
```

3. Save and exit (`Ctrl+O`, Enter, `Ctrl+X`), then restart SSH. Note: despite the config file being named `sshd_config`, the systemd service on Ubuntu/Debian is usually just called `ssh`, not `sshd` — the latter will fail with "Unit sshd.service not found":
```bash
   sudo systemctl restart ssh
```

4. **Without closing your current session**, open a brand new terminal/tab and test:
```bash
   ssh root@YOUR_SERVER_IP
```
   It should log in using your key with no password prompt at all.

5. If it works, you're done. If it fails, your original session is still open — revert the two lines back to `yes` and restart `sshd` again.

### If your provider has its own override files

If step 4 still prompts for a password despite your `sshd_config` looking correct, check for provider-specific override files that load after the main config and take priority:

```bash
sudo grep -r "PasswordAuthentication" /etc/ssh/sshd_config.d/
```

```bash
sudo nano /etc/ssh/sshd_config.d/50-cloud-init.conf
```

Either flip your provider's SSH password toggle off in their control panel (often auto-fixes this), or manually edit each file found above to say `PasswordAuthentication no`, then restart `sshd` again.

### Final check

From a fresh session with no key configured, confirm password login is genuinely refused (not just skipped):

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no root@YOUR_SERVER_IP
```

This should be rejected outright, even with a correct password.

---

## 2. Install fail2ban

Recommended once SSH is key-only, as a second layer that also cuts down log noise and wasted resources from bots repeatedly probing port 22.

### Install

```bash
sudo apt update
sudo apt install fail2ban -y
sudo systemctl enable --now fail2ban
```

### Check it's working

```bash
sudo fail2ban-client status sshd
```

Don't be alarmed if "Total failed" is already high within minutes of installing — every internet-facing IP gets constant automated login attempts. That's normal background noise, not something targeting you specifically.

**Note**: this jail only watches SSH (port 22). It has no effect on the AIOStreams web login — that has its own built-in rate limiter (5 attempts per 5 minutes per IP), so family or friends mistyping the AIOStreams password get a short cool-down from the app itself, not a firewall ban.

### Troubleshooting: "Currently failed" and "Total failed" stay at 0 forever

If you're on Ubuntu/Debian and `sudo fail2ban-client status sshd` shows `0` for
both counts no matter how much internet bot traffic your server sees — and
especially if the output includes this line:

```
Journal matches:  _SYSTEMD_UNIT=sshd.service + _COMM=sshd
```

that's a real bug in fail2ban's shipped default filter
(`/etc/fail2ban/filter.d/sshd.conf`). It hardcodes the systemd unit name as
`sshd.service`, but on Debian/Ubuntu the actual unit is `ssh.service` (no
"d"). Because of the mismatch, fail2ban runs, reports itself as active, and
*looks* completely fine in status output — while silently matching zero
journal entries and never banning anyone. It's easy to miss since nothing
about it looks broken until you actually test it.

**Fix**, without editing fail2ban's own shipped file (so package updates
don't wipe your change):

```bash
sudo nano /etc/fail2ban/jail.d/sshd.local
```
```ini
[sshd]
enabled = true
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service
```
```bash
sudo systemctl restart fail2ban
```

**Confirm it's actually watching the right place now:**

```bash
sudo fail2ban-client status sshd
```

The `Journal matches` line should now read `_SYSTEMD_UNIT=ssh.service`.

**Prove it's catching real attempts** (not just pointed the right way in
theory) by deliberately failing a login a couple of times from another
machine or terminal:

```bash
ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no wronguser@YOUR_SERVER_IP
```

Then re-check status — `Currently failed` should increment. If it stayed at
`0` before this fix and increments after, that's confirmation the fix
worked.

> If you installed fail2ban via this project's setup script (menu option 7,
> or the prompt at the end of a fresh install), this is now handled for you
> automatically — the script detects the correct unit name and writes this
> same override on every run. This section is here for anyone setting up
> fail2ban manually, or checking an install from before this fix existed.

### Useful commands

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip X.X.X.X   # manually unban an IP if needed
sudo systemctl restart fail2ban
```

---

## 3. UFW (firewall)

### Worth knowing before you set this up

Docker manipulates `iptables` directly when you publish ports (like the `80:80` and `443:443` mappings in this project's `docker-compose.yml`), and it does this in a way that **bypasses UFW's rules by default**. This catches people out — they enable UFW, feel secure, but Docker's published ports remain reachable regardless of UFW's rules, since Docker inserts its own rules at a lower level.

For this project specifically, since ports 80/443 are meant to be public anyway (that's how Stremio and browsers reach your instance), UFW's main practical benefit here is acting as a safety net against anything *else* accidentally getting exposed later — not blocking 80/443 themselves.

### Basic setup

```bash
sudo apt install ufw -y
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable
```

### After enabling, verify nothing broke

Visit your AIOStreams URL in a browser and confirm it still loads. If it doesn't, that's the Docker/iptables bypass issue — a deeper fix involves configuring Docker's daemon to not manage iptables directly (`"iptables": false` in `/etc/docker/daemon.json`) and managing container ports through UFW's Docker-specific chain instead. This is a more involved change; only pursue it if you specifically need UFW to control container-published ports, which isn't necessary for this project's default setup.
---

## 4. Credentials housekeeping (do this once, takes two minutes)

The installer writes a file called `CREDENTIALS.txt` into `~/aiostreams`
containing your `SECRET_KEY` and login username. It exists so the key doesn't
vanish into terminal scrollback — but it's not meant to live on the server
long-term.

### Why it matters

- The `SECRET_KEY` encrypts every stored config on your instance. It **cannot
  be changed** later without invalidating them, and it **cannot be recovered**
  if lost. It's the one thing you must keep a copy of somewhere safe.
- Anything sitting in plaintext on the server is one compromise away from
  being read. Off the server, it isn't.

### Steps

1. Open the file and copy its contents somewhere safe — a password manager
   entry is ideal:
```bash
   cat ~/aiostreams/CREDENTIALS.txt
```
2. Store the `SECRET_KEY` and your login username/password in that safe place.
3. Delete the file from the server:
```bash
   rm ~/aiostreams/CREDENTIALS.txt
```

### What stays on the server (and that's okay)

Your login also lives in `~/aiostreams/docker-compose.yml` on the
`AIOSTREAMS_AUTH` line — AIOStreams reads it from there every time it starts,
so that one has to stay. The script sets that file to root-only permissions
(`chmod 600`). The same file contains your `SECRET_KEY` for the same reason,
which is exactly why having an off-server copy from the steps above matters:
if the server ever dies, the compose file dies with it.

### If you ever need to restore from scratch

With your off-server `SECRET_KEY`, a backup of `~/aiostreams/data`, and your
domain pointed at a new server, you can re-run the setup script, let it
generate a fresh compose file, put your old `SECRET_KEY` back on the
`SECRET_KEY=` line, restore the `data` folder, and `docker compose up -d` —
your configs come back exactly as they were.
