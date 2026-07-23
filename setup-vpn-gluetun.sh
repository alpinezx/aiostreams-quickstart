#!/usr/bin/env bash
#
# Adds an optional gluetun VPN container to an existing AIOStreams Docker
# stack (installed via setup-aiostreams.sh), routing ONLY the aiostreams
# container's network through it — never the host.
#
# Re-run this script any time to get a menu: turn the VPN on/off, check
# status, or reconfigure which WireGuard server it uses. Toggling is an
# instant swap between two saved docker-compose.yml variants, not a manual
# rollback — both "direct" (no VPN) and "vpn" versions are kept on disk.
#
# Why gluetun instead of host-level WireGuard (wg-quick):
#   - Runs entirely inside Docker's own network namespace.
#   - Never touches the host's routing table, so it CANNOT cut off your SSH
#     session, unlike wg-quick with a full-tunnel (0.0.0.0/0) config.
#   - Worst case if something's wrong: aiostreams stops responding. Switch
#     back to "direct" mode from the menu and you're back to normal.
#
# Usage:
#   chmod +x setup-vpn-gluetun.sh
#   sudo ./setup-vpn-gluetun.sh

set -euo pipefail

info()  { printf '\n\033[1;34m==>\033[0m %s\n' "$1"; }
warn()  { printf '\033[1;33m!! \033[0m %s\n' "$1"; }
error() { printf '\033[1;31mXX \033[0m %s\n' "$1"; exit 1; }

INSTALL_DIR="$HOME/aiostreams"
COMPOSE_FILE="$INSTALL_DIR/docker-compose.yml"
CADDYFILE="$INSTALL_DIR/Caddyfile"
STATE_DIR="$INSTALL_DIR/vpn-state"
DIRECT_COMPOSE="$STATE_DIR/docker-compose.direct.yml"
VPN_COMPOSE="$STATE_DIR/docker-compose.vpn.yml"
DIRECT_CADDYFILE="$STATE_DIR/Caddyfile.direct"
VPN_CADDYFILE="$STATE_DIR/Caddyfile.vpn"
ACTIVE_MARKER="$STATE_DIR/active"

[[ -f "$COMPOSE_FILE" ]] || error "Couldn't find $COMPOSE_FILE — run setup-aiostreams.sh first."
[[ -f "$CADDYFILE" ]] || error "Couldn't find $CADDYFILE — run setup-aiostreams.sh first."

cd "$INSTALL_DIR"
mkdir -p "$STATE_DIR"

# ---------- helpers used by multiple menu options ----------

read_existing_values() {
    DOMAIN=$(grep -oP 'BASE_URL=https://\K[^"]+' "$1" || true)
    SECRET_KEY=$(grep -oP 'SECRET_KEY=\K[^"]+' "$1" || true)
    AUTH_LINE=$(grep -oP 'AIOSTREAMS_AUTH=\K[^"]+' "$1" | head -1 || true)
    [[ -n "$DOMAIN" && -n "$SECRET_KEY" && -n "$AUTH_LINE" ]] || \
        error "Couldn't parse DOMAIN/SECRET_KEY/AUTH from $1. Check it hasn't been hand-edited into an unexpected format."
}

write_direct_files() {
    cat > "$DIRECT_COMPOSE" << EOF
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
      - AIOSTREAMS_AUTH=${AUTH_LINE}
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
    cat > "$DIRECT_CADDYFILE" << EOF
${DOMAIN} {
    reverse_proxy aiostreams:3000
}
EOF
}

write_vpn_files() {
    cat > "$VPN_COMPOSE" << EOF
services:
  gluetun:
    image: qmcgaw/gluetun:latest
    container_name: gluetun
    restart: unless-stopped
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    environment:
      - VPN_SERVICE_PROVIDER=custom
      - VPN_TYPE=wireguard
      - WIREGUARD_PRIVATE_KEY=${WG_PRIVATE_KEY}
      - WIREGUARD_ADDRESSES=${WG_ADDRESS}
      - WIREGUARD_PUBLIC_KEY=${WG_PUBLIC_KEY}
      - WIREGUARD_ENDPOINT_IP=${WG_ENDPOINT_IP}
      - WIREGUARD_ENDPOINT_PORT=${WG_ENDPOINT_PORT}
  aiostreams:
    image: viren070/aiostreams:latest
    container_name: aiostreams
    restart: unless-stopped
    network_mode: "service:gluetun"
    depends_on:
      - gluetun
    volumes:
      - ./data:/app/data
    environment:
      - PORT=3000
      - BASE_URL=https://${DOMAIN}
      - SECRET_KEY=${SECRET_KEY}
      - AIOSTREAMS_AUTH=${AUTH_LINE}
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
      - gluetun
      - aiostreams
volumes:
  caddy_data:
  caddy_config:
EOF
    cat > "$VPN_CADDYFILE" << EOF
${DOMAIN} {
    reverse_proxy gluetun:3000
}
EOF
}

apply_mode() {
    local mode="$1"  # "direct" or "vpn"
    if [[ "$mode" == "direct" ]]; then
        cp "$DIRECT_COMPOSE" "$COMPOSE_FILE"
        cp "$DIRECT_CADDYFILE" "$CADDYFILE"
    else
        cp "$VPN_COMPOSE" "$COMPOSE_FILE"
        cp "$VPN_CADDYFILE" "$CADDYFILE"
    fi
    chmod 600 "$COMPOSE_FILE"
    echo "$mode" > "$ACTIVE_MARKER"

    # Read fresh from whichever Caddyfile we just activated, rather than
    # relying on a $DOMAIN set earlier in the script's execution — toggling
    # straight from the menu doesn't go through read_existing_values.
    local domain
    domain=$(head -1 "$CADDYFILE" | awk '{print $1}')

    info "Restarting the stack in '$mode' mode"
    docker compose down --remove-orphans
    docker compose up -d

    if [[ "$mode" == "vpn" ]]; then
        info "Waiting 15s for the tunnel to come up..."
        sleep 15
        echo ""
        docker compose logs gluetun --tail=15
        echo ""
        if docker exec gluetun wget -qO- ifconfig.me/ip 2>/dev/null | grep -qE '^[0-9]'; then
            EXIT_IP=$(docker exec gluetun wget -qO- ifconfig.me/ip 2>/dev/null)
            echo -e "\033[1;32mVPN is up.\033[0m gluetun's exit IP: $EXIT_IP"
        else
            warn "Couldn't confirm the exit IP automatically. Check manually with:"
            echo "  docker exec gluetun wget -qO- ifconfig.me/ip"
        fi
    fi

    echo ""
    echo "Confirm at https://${domain}"
}

do_status() {
    local active
    active=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")
    echo ""
    echo "Current mode: $active"
    echo ""
    docker compose ps
    if [[ "$active" == "vpn" ]]; then
        echo ""
        echo "gluetun exit IP:"
        docker exec gluetun wget -qO- ifconfig.me/ip 2>/dev/null || warn "Couldn't reach ifconfig.me from inside gluetun — tunnel may be down."
    fi
}

do_reconfigure_vpn() {
    read_existing_values "$COMPOSE_FILE" 2>/dev/null || read_existing_values "$DIRECT_COMPOSE"
    info "WireGuard config"
    echo "Point this at a WireGuard .conf file already on this server."
    read -rp "Path to .conf file: " WG_PATH
    [[ -f "$WG_PATH" ]] || error "File not found: $WG_PATH"

    WG_PRIVATE_KEY=$(grep -i '^PrivateKey' "$WG_PATH" | head -1 | cut -d= -f2- | tr -d ' ')
    WG_ADDRESS=$(grep -i '^Address' "$WG_PATH" | head -1 | cut -d= -f2- | tr -d ' ')
    WG_PUBLIC_KEY=$(grep -i '^PublicKey' "$WG_PATH" | head -1 | cut -d= -f2- | tr -d ' ')
    WG_ENDPOINT=$(grep -i '^Endpoint' "$WG_PATH" | head -1 | cut -d= -f2- | tr -d ' ')

    [[ -n "$WG_PRIVATE_KEY" && -n "$WG_ADDRESS" && -n "$WG_PUBLIC_KEY" && -n "$WG_ENDPOINT" ]] || \
        error "Couldn't parse PrivateKey/Address/PublicKey/Endpoint from $WG_PATH."

    WG_ENDPOINT_IP="${WG_ENDPOINT%%:*}"
    WG_ENDPOINT_PORT="${WG_ENDPOINT##*:}"

    if ! [[ "$WG_ENDPOINT_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "Endpoint '$WG_ENDPOINT_IP' isn't a literal IP. gluetun requires an IP, not a hostname — resolve it first (e.g. 'dig +short $WG_ENDPOINT_IP') and edit the .conf file's Endpoint line before retrying."
    fi

    echo "  Parsed endpoint: $WG_ENDPOINT_IP:$WG_ENDPOINT_PORT"
    write_vpn_files
    echo "VPN config saved. Choose 'Turn VPN ON' from the menu to apply it."
}

# ---------- first-time setup ----------

first_time_setup() {
    info "First-time VPN setup"
    read_existing_values "$COMPOSE_FILE"
    echo "  Domain: $DOMAIN"
    echo "  Auth user: ${AUTH_LINE%%:*}"

    write_direct_files   # capture current (pre-VPN) state as the "direct" variant

    do_reconfigure_vpn

    BACKUP_DIR="$INSTALL_DIR/backup-pre-vpn-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cp "$COMPOSE_FILE" "$BACKUP_DIR/"
    cp "$CADDYFILE" "$BACKUP_DIR/"
    echo "(Original config also backed up to $BACKUP_DIR, just in case.)"

    apply_mode "vpn"
}

# ---------- menu ----------

if [[ ! -f "$ACTIVE_MARKER" ]]; then
    first_time_setup
    exit 0
fi

while true; do
    echo ""
    echo "=== AIOStreams VPN control ==="
    CURRENT=$(cat "$ACTIVE_MARKER" 2>/dev/null || echo "unknown")
    echo "Current mode: $CURRENT"
    echo ""
    echo "1) Status"
    echo "2) Turn VPN ON"
    echo "3) Turn VPN OFF (direct connection)"
    echo "4) Reconfigure VPN (change WireGuard server/config)"
    echo "5) Exit"
    read -rp "Choose an option [1-5]: " CHOICE

    case "$CHOICE" in
        1) do_status ;;
        2) apply_mode "vpn" ;;
        3) apply_mode "direct" ;;
        4) do_reconfigure_vpn ;;
        5) exit 0 ;;
        *) warn "Not a valid option." ;;
    esac
done
