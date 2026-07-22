#!/usr/bin/env bash
#
# AIOStreams self-hosted install & management script
# Sets up AIOStreams + Caddy (HTTPS via Let's Encrypt) in Docker.
# Access control uses AIOStreams' built-in login (AIOSTREAMS_AUTH +
# AIOSTREAMS_AUTH_REQUIRED), which protects the configure page, the
# dashboard, AND the underlying config API — so nobody can create or
# modify configs on your instance without logging in.
#
# Can also manage an existing installation (status, restart, update, uninstall).
#
# Run as root (or with sudo) on a fresh Ubuntu/Debian VPS.
#
# Usage:
#   chmod +x setup-aiostreams.sh
#   ./setup-aiostreams.sh

set -euo pipefail

# ---------- helpers ----------

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

require_cmd() {
    command -v "$1" >/dev/null 2>&1
}

# Auto-detects RAM, decides whether swap is needed, sizes it safely against
# available disk space, and creates it. Skips cleanly if swap already exists
# or if RAM is already above 1GB.
setup_swap() {
    local total_ram_mb swap_mb avail_disk_mb max_safe_swap_mb

    total_ram_mb=$(free -m | awk '/^Mem:/{print $2}')
    info "Detected ${total_ram_mb}MB RAM"

    if [[ "$total_ram_mb" -gt 1024 ]]; then
        echo "System has more than 1GB RAM — a swap file isn't necessary. Skipping."
        return 0
    fi

    if swapon --show 2>/dev/null | grep -q .; then
        echo "Swap is already configured, skipping."
        return 0
    fi

    # Recommended size: ~2x RAM for low-RAM systems, capped at 4GB (diminishing
    # returns beyond that), rounded up to the nearest 256MB.
    swap_mb=$(( total_ram_mb * 2 ))
    if [[ "$swap_mb" -gt 4096 ]]; then
        swap_mb=4096
    fi
    swap_mb=$(( ( (swap_mb + 255) / 256 ) * 256 ))

    # Don't let the swap file eat more than 25% of free disk space, and always
    # leave at least 1GB free afterward.
    avail_disk_mb=$(df --output=avail -m / | tail -n1 | tr -d ' ')
    max_safe_swap_mb=$(( avail_disk_mb / 4 ))
    if [[ "$swap_mb" -gt "$max_safe_swap_mb" ]]; then
        swap_mb="$max_safe_swap_mb"
    fi

    if [[ "$swap_mb" -lt 256 || $(( avail_disk_mb - swap_mb )) -lt 1024 ]]; then
        warn "Not enough free disk space (${avail_disk_mb}MB available) to safely create a swap file. Skipping."
        return 1
    fi

    info "Creating a ${swap_mb}MB swap file (based on ${total_ram_mb}MB RAM and ${avail_disk_mb}MB free disk)"

    if ! fallocate -l "${swap_mb}M" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count="$swap_mb"
    fi

    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile

    if ! grep -q '^/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    if swapon --show 2>/dev/null | grep -q '/swapfile'; then
        echo "Swap file created and activated successfully (${swap_mb}MB)."
        free -h
        return 0
    else
        warn "Swap setup ran, but /swapfile doesn't show as active. Check manually with: swapon --show"
        return 1
    fi
}

# Installs fail2ban (SSH brute-force protection) and UFW (firewall allowing
# only 22/80/443). Idempotent: skips anything already installed and active.
# Deliberately does NOT touch SSH password settings — that's a manual,
# check-every-step process; see docs/security-hardening.md section 1.
harden_server() {
    info "Server hardening: fail2ban + UFW"

    apt-get update -qq || { warn "apt update failed — check your network and try again."; return 1; }

    # --- fail2ban ---
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        echo "fail2ban is already installed and running, skipping."
    else
        echo "Installing fail2ban (bans IPs that repeatedly fail SSH login)..."
        apt-get install -y -qq fail2ban || { warn "fail2ban install failed."; return 1; }
        systemctl enable --now fail2ban
        echo "fail2ban is active. Check it any time with: fail2ban-client status sshd"
        echo "(A high 'Total failed' count is normal — that's internet bot noise, not you being targeted.)"
    fi

    # --- UFW ---
    if require_cmd ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "UFW is already active, ensuring rules for 22/80/443 are present..."
    else
        echo "Installing and enabling UFW (firewall)..."
        apt-get install -y -qq ufw || { warn "UFW install failed."; return 1; }
    fi
    # Allow required ports BEFORE enabling, so an active SSH session is never cut off.
    ufw allow 22/tcp  >/dev/null
    ufw allow 80/tcp  >/dev/null
    ufw allow 443/tcp >/dev/null
    ufw --force enable >/dev/null
    echo "UFW is active: only ports 22 (SSH), 80 and 443 (web) are open."
    echo ""
    echo "Note: Docker publishes ports 80/443 by writing its own firewall rules underneath"
    echo "UFW, so those stay reachable regardless — which is fine, they're meant to be public."
    echo "UFW's job here is stopping anything ELSE from being accidentally exposed later."
    return 0
}

INSTALL_DIR="$HOME/aiostreams"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDYFILE="$INSTALL_DIR/Caddyfile"

# ---------- pre-flight ----------

if [[ $EUID -ne 0 ]]; then
    error "Please run this script as root (or with sudo)."
fi

# ---------- existing install: show management menu ----------

if [[ -f "$COMPOSE_FILE" ]]; then
    if ! require_cmd docker || ! docker compose version >/dev/null 2>&1; then
        error "Existing AIOStreams config found at $INSTALL_DIR, but Docker/Compose isn't available. Reinstall Docker or remove $INSTALL_DIR to start fresh."
    fi

    echo ""
    echo "Existing AIOStreams installation detected at $INSTALL_DIR"
    echo ""
    echo "What would you like to do?"
    echo "  1) View status"
    echo "  2) Restart services"
    echo "  3) Update (pull latest images + restart)"
    echo "  4) Reconfigure (change domain/login, backs up current config)"
    echo "  5) Uninstall (clean removal)"
    echo "  6) Check / set up swap space (recommended for servers with less than 1GB RAM)"
    echo "  7) Harden server (install fail2ban + UFW firewall)"
    echo "  8) Exit"
    echo ""
    read -rp "Select an option [1-8]: " MENU_CHOICE

    case "$MENU_CHOICE" in
        1)
            echo ""
            echo "=== Container Status ==="
            cd "$INSTALL_DIR"
            docker compose ps
            echo ""
            echo "=== Recent Caddy cert log lines ==="
            docker compose logs caddy 2>/dev/null | grep -i "certificate" | tail -5 || echo "No cert-related log lines found."
            exit 0
            ;;
        2)
            echo ""
            echo "Restarting AIOStreams services..."
            cd "$INSTALL_DIR"
            docker compose restart
            echo "Restarted. Check status with: docker compose ps"
            exit 0
            ;;
        3)
            echo ""
            echo "Updating AIOStreams (pull + recreate)..."
            cd "$INSTALL_DIR"
            docker compose pull
            docker compose up -d --force-recreate --remove-orphans
            echo ""
            echo "Update complete. Current images:"
            docker compose images
            exit 0
            ;;
        4)
            echo ""
            echo "Proceeding with reconfiguration. Current config will be backed up first."
            BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"
            cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak_${BACKUP_SUFFIX}"
            [[ -f "$CADDYFILE" ]] && cp "$CADDYFILE" "${CADDYFILE}.bak_${BACKUP_SUFFIX}"
            echo "Backed up to *.bak_${BACKUP_SUFFIX}"
            # falls through to the install flow below
            ;;
        5)
            echo ""
            echo "=== AIOStreams Uninstall ==="
            read -rp "Are you sure you want to completely remove AIOStreams? [y/N]: " CONFIRM_UNINSTALL
            if [[ ! "$CONFIRM_UNINSTALL" =~ ^[Yy]$ ]]; then
                echo "Uninstall cancelled."
                exit 0
            fi

            cd "$INSTALL_DIR"
            read -rp "Delete Docker volumes too? This removes your Caddy HTTPS certificates. [y/N]: " REMOVE_VOLUMES
            if [[ "$REMOVE_VOLUMES" =~ ^[Yy]$ ]]; then
                docker compose down -v --rmi local
                echo "Containers, volumes, and images removed."
            else
                docker compose down --rmi local
                echo "Containers and images removed (volumes preserved)."
            fi

            read -rp "Delete the config directory ($INSTALL_DIR), including your SECRET_KEY backup? [y/N]: " REMOVE_CONFIG
            if [[ "$REMOVE_CONFIG" =~ ^[Yy]$ ]]; then
                rm -rf "$INSTALL_DIR"
                echo "Configuration removed."
            else
                echo "Configuration preserved in $INSTALL_DIR"
            fi

            echo ""
            echo "Uninstall complete."
            exit 0
            ;;
        6)
            echo ""
            echo "=== Swap Status ==="
            free -h
            echo ""
            setup_swap || true
            exit 0
            ;;
        7)
            echo ""
            harden_server || warn "Hardening did not fully complete — see messages above. Safe to re-run any time."
            exit 0
            ;;
        8)
            echo "Exiting."
            exit 0
            ;;
        *)
            error "Invalid selection."
            ;;
    esac
else
    info "AIOStreams self-hosted setup"
    echo "This will set up:"
    echo "  - Docker (installed automatically if missing)"
    echo "  - AIOStreams (the Stremio meta-addon)"
    echo "  - Caddy (reverse proxy with automatic HTTPS via Let's Encrypt)"
    echo "  - AIOStreams' built-in login, locking config creation/editing to your account only"
    echo ""
    read -rp "Press Enter to continue, or Ctrl+C to cancel..."
fi

# ---------- collect input up front ----------

info "A few questions before we start"

while true; do
    read -rp "Domain/subdomain for this instance (e.g. streams.example.com): " DOMAIN
    DOMAIN=$(echo "$DOMAIN" | xargs)  # trim whitespace

    if [[ -z "$DOMAIN" ]]; then
        warn "Domain cannot be empty."
        continue
    fi

    # Reject raw IPs — Let's Encrypt needs a real domain name
    if [[ "$DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        warn "Please enter a domain name, not an IP address. Caddy needs a domain to issue an HTTPS certificate."
        continue
    fi

    break
done

echo ""
echo "Checking DNS resolution for $DOMAIN..."
if require_cmd getent; then
    RESOLVED_IP=$(getent hosts "$DOMAIN" | awk '{ print $1 }' | head -n1 || true)
else
    RESOLVED_IP=$(ping -c1 "$DOMAIN" 2>/dev/null | awk -F'[()]' '/PING/{print $2}' || true)
fi

if [[ -z "$RESOLVED_IP" ]]; then
    warn "Could not resolve $DOMAIN. If you haven't set the DNS A record yet, Caddy will fail to get an HTTPS certificate."
    read -rp "Continue anyway? (y/N): " CONTINUE_ANYWAY
    if [[ ! "$CONTINUE_ANYWAY" =~ ^[Yy]$ ]]; then
        error "Aborting. Set up your DNS A record first, then re-run this script."
    fi
else
    echo "Resolved $DOMAIN -> $RESOLVED_IP"
fi

echo ""
while true; do
    read -rp "Username for logging into AIOStreams (configure page + dashboard): " AUTH_USER
    if [[ -z "$AUTH_USER" ]]; then
        warn "Username cannot be empty."
        continue
    fi
    # AIOSTREAMS_AUTH is a comma-separated list of user:pass pairs, so these
    # characters would break the format. Keep it to simple safe characters.
    if [[ ! "$AUTH_USER" =~ ^[A-Za-z0-9._-]+$ ]]; then
        warn "Username can only contain letters, numbers, dots, underscores, and hyphens."
        continue
    fi
    break
done

while true; do
    read -rsp "Password for that account (input hidden): " AUTH_PASS
    echo ""
    if [[ -z "$AUTH_PASS" ]]; then
        warn "Password cannot be empty. Try again."
        continue
    fi
    if [[ ${#AUTH_PASS} -lt 8 ]]; then
        warn "Please use at least 8 characters."
        continue
    fi
    # The password is stored in the AIOSTREAMS_AUTH env var (user:pass,user:pass
    # format) inside docker-compose.yml, so ':' ',' and shell/YAML-special
    # characters would break things. Letters, numbers, and these symbols are safe:
    if [[ ! "$AUTH_PASS" =~ ^[A-Za-z0-9@%^*_+=.!?-]+$ ]]; then
        warn "Password can only contain letters, numbers, and these symbols: @ % ^ * _ + = . ! ? -"
        continue
    fi
    read -rsp "Confirm password: " AUTH_PASS_CONFIRM
    echo ""
    if [[ "$AUTH_PASS" != "$AUTH_PASS_CONFIRM" ]]; then
        warn "Passwords didn't match. Try again."
        continue
    fi
    break
done

# ---------- swap setup for low-RAM servers ----------

# '|| true' matters here: under 'set -e', setup_swap returning 1 (e.g. not
# enough disk space for a swap file) would otherwise abort the whole install.
setup_swap || true

# ---------- install Docker if missing ----------

if require_cmd docker; then
    info "Docker is already installed, skipping install."
else
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker >/dev/null 2>&1 || true
    systemctl start docker >/dev/null 2>&1 || true
fi

if ! docker compose version >/dev/null 2>&1; then
    error "Docker Compose plugin not found even after install. Check 'docker compose version' manually."
fi

# ---------- build the install directory ----------

info "Setting up $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

# ---------- preserve existing SECRET_KEY on reconfigure, else generate one ----------

if [[ -f "$COMPOSE_FILE" ]] && grep -q "SECRET_KEY=" "$COMPOSE_FILE"; then
    info "Reusing existing SECRET_KEY from current config (changing it would invalidate stored configs)"
    SECRET_KEY=$(grep "SECRET_KEY=" "$COMPOSE_FILE" | head -n1 | sed 's/.*SECRET_KEY=//')
else
    info "Generating SECRET_KEY (used to encrypt stored AIOStreams configs)"
    SECRET_KEY=$(openssl rand -hex 32)
fi

# ---------- write docker-compose.yml ----------

info "Writing docker-compose.yml"
cat > docker-compose.yml << EOF
services:
  aiostreams:
    image: viren070/aiostreams:latest
    container_name: aiostreams
    restart: unless-stopped
    volumes:
      - ./data:/app/data
    environment:
      - PORT=3000
      - BASE_URL=https://${DOMAIN}
      - SECRET_KEY=${SECRET_KEY}
      # Built-in login: protects the configure page, dashboard, AND the
      # config API itself — nobody can create/edit configs without this login.
      - AIOSTREAMS_AUTH=${AUTH_USER}:${AUTH_PASS}
      - AIOSTREAMS_AUTH_REQUIRED=true
  caddy:
    image: caddy:latest
    container_name: caddy
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile
      - caddy_data:/data
      - caddy_config:/config
    depends_on:
      - aiostreams
volumes:
  caddy_data:
  caddy_config:
EOF

# The compose file now contains your login password (AIOSTREAMS_AUTH), so
# make it readable by root only.
chmod 600 docker-compose.yml

# ---------- write Caddyfile ----------

info "Writing Caddyfile (HTTPS reverse proxy; access control is handled by AIOStreams' own login)"
cat > Caddyfile << EOF
${DOMAIN} {
    reverse_proxy aiostreams:3000
}
EOF

# ---------- launch ----------

info "Pulling images"
MAX_RETRIES=3
attempt=1
until docker compose pull; do
    if [[ $attempt -ge $MAX_RETRIES ]]; then
        error "Failed to pull images after $MAX_RETRIES attempts. Check your network connection and try again."
    fi
    warn "Pull failed (attempt $attempt/$MAX_RETRIES) — retrying in 5s..."
    attempt=$((attempt + 1))
    sleep 5
done

info "Starting containers"
docker compose up -d --force-recreate --remove-orphans

echo "Waiting for aiostreams to become healthy..."
MAX_WAIT=90; INTERVAL=3; elapsed=0; success=false
while [[ $elapsed -lt $MAX_WAIT ]]; do
    if [[ "$(docker inspect -f '{{.State.Health.Status}}' aiostreams 2>/dev/null)" == "healthy" ]]; then
        success=true
        break
    fi
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done
if $success; then
    echo "aiostreams is healthy (took ~${elapsed}s)."
else
    warn "aiostreams didn't report healthy after ${MAX_WAIT}s. Check 'docker compose logs aiostreams' for details."
fi

echo "Waiting for Caddy to obtain its HTTPS certificate (this can take longer on a genuinely fresh cert request)..."
MAX_WAIT=90; INTERVAL=3; elapsed=0; cert_ok=false
while [[ $elapsed -lt $MAX_WAIT ]]; do
    if docker compose logs caddy 2>/dev/null | grep -q "certificate obtained successfully"; then
        cert_ok=true
        break
    fi
    # Also treat "already have a valid cert on disk" as success — happens on reinstalls
    # where the Docker volume still holds a cert from a previous run.
    if docker compose logs caddy 2>/dev/null | grep -qE "storage cleaning happened too recently|certificate.*already exists"; then
        cert_ok=true
        break
    fi
    echo "  Not confirmed yet... (${elapsed}s elapsed)"
    sleep "$INTERVAL"
    elapsed=$((elapsed + INTERVAL))
done
if $cert_ok; then
    echo "HTTPS certificate confirmed (obtained fresh, or reused an existing valid one)."
else
    warn "Couldn't confirm certificate issuance after ${MAX_WAIT}s. Check 'docker compose logs caddy' — this is usually a DNS propagation delay if the domain is brand new."
fi

# ---------- save credentials for the human, not just terminal scrollback ----------

CREDS_FILE="$INSTALL_DIR/CREDENTIALS.txt"
cat > "$CREDS_FILE" << EOF
AIOStreams self-hosted setup — credentials generated on $(date)

Site URL:         https://${DOMAIN}
Login username:   ${AUTH_USER}
Login password:   (the one you typed in — write it down in your password manager)

Note: the username & password also live in ~/aiostreams/docker-compose.yml
(the AIOSTREAMS_AUTH line) because AIOStreams reads them from there on startup.
That file is readable by root only (chmod 600). If you ever change the
password, edit that line and run: docker compose up -d

SECRET_KEY (do NOT lose this — cannot be changed later without resetting stored configs):
${SECRET_KEY}

Reminder: move this file somewhere safe (password manager, encrypted notes) and then delete it from the server:
  rm ${CREDS_FILE}
EOF
chmod 600 "$CREDS_FILE"

# ---------- optional hardening ----------

echo ""
read -rp "Also install fail2ban + UFW firewall now? Recommended, safe, and re-runnable. [y/N]: " DO_HARDEN
if [[ "$DO_HARDEN" =~ ^[Yy]$ ]]; then
    harden_server || warn "Hardening did not fully complete — see messages above. Re-run via the menu (option 7) any time."
else
    echo "Skipped. You can run it later via the management menu (option 7),"
    echo "or follow docs/security-hardening.md manually."
fi

# ---------- summary ----------

info "Done!"
echo ""
echo "Visit: https://${DOMAIN}"
echo "Log in with the username/password you just set (AIOStreams' own login page)."
echo ""
echo "Config creation and editing now require that login — including the API,"
echo "not just the web pages — so nobody else can piggyback on your instance."
echo ""
echo "IMPORTANT:"
echo "  - Your SECRET_KEY and login username are saved to: $CREDS_FILE"
echo "  - Move that file somewhere safe (off the server) and then delete it — it currently sits in plaintext on disk."
echo "  - If you already had a config from before this change: open the configure page,"
echo "    log in, and hit Save once so it picks up the new access protection."
echo "  - Next step in AIOStreams itself: go to Services, add your debrid provider's API key, then Addons > Marketplace to add a scraper (Torrentio, Comet, etc.)."
echo ""
echo "Useful commands:"
echo "  cd $INSTALL_DIR && docker compose ps         # check container status"
echo "  cd $INSTALL_DIR && docker compose logs -f     # tail logs"
echo "  ./setup-aiostreams.sh                         # re-run any time for status/update/reconfigure/uninstall menu"