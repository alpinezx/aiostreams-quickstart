## 1. Disable SSH password login (key-only + root login lockdown)

> Tested on Ubuntu 26.04 LTS ("Resolute Raccoon"). Steps should be similar on other Debian-based distros, but file paths/behavior may differ slightly — proceed carefully if you're on something else.

⚠️ **Read this before doing anything.** This makes SSH refuse password logins entirely — only your SSH key will work afterward. If your key isn't working correctly for any reason, you can lock yourself out of your own server. Follow the safety checks at every step; don't skip them.

### Before you start

- Confirm you can currently SSH in using a **key**, not a password.
- Keep your current terminal session open throughout this whole process. Don't close it until everything is fully tested and working in a **separate, new** session.
- Some VPS providers layer their own SSH password toggle in the control panel on top of the server's own config — check there too if changes to `sshd_config` don't seem to take effect.

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

3. Save and exit (`Ctrl+O`, Enter, `Ctrl+X`), then restart SSH:
```bash
   sudo systemctl restart sshd
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

**Note**: this jail only watches SSH (port 22). It has no effect on your AIOStreams/Caddy login page — family or friends mistyping the AIOStreams password won't get banned by this.

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