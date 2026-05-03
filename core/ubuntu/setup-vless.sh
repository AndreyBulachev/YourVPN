#!/bin/bash
# =============================================================================
#  VLESS + XTLS-Reality VPN Server Setup
#  Ubuntu/Debian | Port 443 | Sections 2.3 and 3 of C1-vpn-theory-and-setup.md
# =============================================================================

set -Eeuo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Constants ─────────────────────────────────────────────────────────────────
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_LOG_DIR="/var/log/xray"
readonly SYSCTL_CONF="/etc/sysctl.d/99-xray.conf"
readonly CLIENT_OUTPUT="/root/xray-client.txt"
readonly VLESS_PORT=443
# Pin Xray version by setting XRAY_TARGET_VERSION before running (e.g. XRAY_TARGET_VERSION=v1.8.24).
# Leave empty to install the latest release.
readonly XRAY_TARGET_VERSION="${XRAY_TARGET_VERSION:-}"
readonly PRESET_SITES=(
    "www.microsoft.com"
    "www.samsung.com"
    "www.asus.com"
    "dl.google.com"
    "www.logitech.com"
    "www.apple.com"
)

# ── Helpers ───────────────────────────────────────────────────────────────────
step() {
    echo -e "\n${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}${BLUE}  ► $1${NC}"
    echo -e "${BOLD}${BLUE}══════════════════════════════════════════════════════${NC}"
}
ok()   { echo -e "${GREEN}  ✓ $1${NC}"; }
info() { echo -e "${CYAN}  ℹ $1${NC}"; }
warn() { echo -e "${YELLOW}  ⚠ $1${NC}"; }
die()  { echo -e "${RED}  ✗ FATAL: $1${NC}" >&2; exit 1; }

confirm() {
    local answer
    read -r -p "$1 [y/N]: " answer
    [[ "$answer" =~ ^[YyДд]$ ]]
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash $0"

if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "$ID" != "ubuntu" && "$ID" != "debian" ]] && die "Requires Ubuntu or Debian (detected: ${ID:-unknown})"
else
    die "Cannot detect OS (/etc/os-release missing)"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
cat << 'BANNER'
╔══════════════════════════════════════════════════════╗
║      VLESS + XTLS-Reality VPN Server Setup           ║
║      Protocol: VLESS  |  Transport: TCP + Reality    ║
╚══════════════════════════════════════════════════════╝
BANNER
echo -e "${NC}"

warn "This script will modify firewall, sysctl, install Xray and overwrite ${XRAY_CONFIG}."
confirm "Continue with installation?" || die "Installation cancelled."

# =============================================================================
# STEP 1/10 — System Update
# =============================================================================
step "Step 1/10 — System update"

DEBIAN_FRONTEND=noninteractive apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get autoremove -y

ok "System packages updated"

# =============================================================================
# STEP 2/10 — Install utilities
# =============================================================================
step "Step 2/10 — Installing required utilities"

PACKAGES=(
    ca-certificates curl wget htop net-tools
    netcat-openbsd iputils-ping
    openssl jq ufw qrencode
)

DEBIAN_FRONTEND=noninteractive apt-get install -y "${PACKAGES[@]}"

ok "Utilities installed"

# =============================================================================
# STEP 3/10 — Firewall (UFW)
# =============================================================================
step "Step 3/10 — Configuring UFW firewall"

# Detect actual SSH port — sshd -T resolves all Include directives
SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)"
if [[ -z "$SSH_PORT" ]]; then
    SSH_PORT="$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2; exit}' /etc/ssh/sshd_config 2>/dev/null || true)"
fi
SSH_PORT="${SSH_PORT:-22}"
info "SSH port detected: ${SSH_PORT}"

ufw allow "${SSH_PORT}/tcp" comment "SSH"
ufw allow "${VLESS_PORT}/tcp" comment "VLESS/Reality"
ufw --force enable

ufw status verbose
ok "Firewall active: SSH (${SSH_PORT}/tcp) and VLESS (${VLESS_PORT}/tcp) open"

# =============================================================================
# STEP 4/10 — BBR + Kernel network optimization
# =============================================================================
step "Step 4/10 — BBR + kernel network optimization"

cat > "$SYSCTL_CONF" << 'EOF'
# Xray VLESS Reality — TCP tuning
net.core.default_qdisc           = fq
net.ipv4.tcp_congestion_control  = bbr
net.ipv4.tcp_rmem                = 4096 87380 67108864
net.ipv4.tcp_wmem                = 4096 65536 67108864
net.core.rmem_max                = 67108864
net.core.wmem_max                = 67108864
net.ipv4.tcp_max_syn_backlog     = 4096
net.core.netdev_max_backlog      = 4096
net.ipv4.tcp_tw_reuse            = 1
net.core.somaxconn               = 4096
net.ipv4.ip_local_port_range     = 1024 65535
EOF

sysctl --system > /dev/null

BBR_ACTIVE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [[ "$BBR_ACTIVE" == "bbr" ]]; then
    ok "BBR enabled (tcp_congestion_control=bbr)"
else
    warn "BBR not yet active (current: ${BBR_ACTIVE}) — may require a reboot."
fi
ok "Kernel TCP parameters written to ${SYSCTL_CONF}"

# =============================================================================
# STEP 5/10 — Install Xray-core
# =============================================================================
step "Step 5/10 — Installing Xray-core"

XRAY_INSTALL_ARGS=(install)
[[ -n "$XRAY_TARGET_VERSION" ]] && XRAY_INSTALL_ARGS+=(--version "$XRAY_TARGET_VERSION")
bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ "${XRAY_INSTALL_ARGS[@]}" \
    || die "Xray installation script failed"

command -v xray > /dev/null 2>&1 || die "xray binary not found after installation"
XRAY_VERSION=$(xray -version 2>&1 | head -1)
ok "${XRAY_VERSION}"

install -d -m 755 "$XRAY_LOG_DIR"
chown nobody:nogroup "$XRAY_LOG_DIR" 2>/dev/null \
    || chown nobody "$XRAY_LOG_DIR" 2>/dev/null \
    || true
ok "Log directory: ${XRAY_LOG_DIR}"

# =============================================================================
# STEP 6/10 — Generate UUID, keypair, Short ID
# =============================================================================
step "Step 6/10 — Generating keys and UUID"

UUID=$(xray uuid) || die "Failed to generate UUID"
ok "UUID:       ${UUID}"

KEY_OUTPUT=$(xray x25519 2>&1) || die "Failed to generate x25519 keypair"
# Supports both output formats:
#   old (≤v1.x):  "Private key: ..."        / "Public key: ..."
#   new (v25.x+): "PrivateKey: ..."         / "Password (PublicKey): ..."
# Note: new format has ")" between "Key" and ":", so we match without the colon.
PRIVATE_KEY=$(awk -F': ' '/PrivateKey|[Pp]rivate key/{print $2; exit}' <<< "$KEY_OUTPUT")
PUBLIC_KEY=$(awk  -F': ' '/PublicKey|[Pp]ublic key/{print $2; exit}'   <<< "$KEY_OUTPUT")

if [[ -z "$PRIVATE_KEY" ]]; then
    die "Could not parse private key from xray x25519 output.\nRaw output was:\n${KEY_OUTPUT}"
fi
if [[ -z "$PUBLIC_KEY" ]]; then
    die "Could not parse public key from xray x25519 output.\nRaw output was:\n${KEY_OUTPUT}"
fi

ok "Public key: ${PUBLIC_KEY}"
info "Private key stored only in server config"

SHORT_ID=$(openssl rand -hex 8) || die "Failed to generate Short ID"
ok "Short ID:   ${SHORT_ID}"

# =============================================================================
# STEP 7/10 — Detect server address
# =============================================================================
step "Step 7/10 — Server address"

DETECTED_IP=""
for SVC in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
    set +e
    DETECTED_IP=$(curl -4 -s --max-time 8 "$SVC" 2>/dev/null | tr -d '[:space:]')
    set -e
    [[ "$DETECTED_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    DETECTED_IP=""
done

if [[ -n "$DETECTED_IP" ]]; then
    read -rp "  Server address [${DETECTED_IP}]: " SERVER_ADDRESS
    SERVER_ADDRESS="${SERVER_ADDRESS:-$DETECTED_IP}"
else
    warn "Could not auto-detect public IP."
    read -rp "  Enter server public IP or domain: " SERVER_ADDRESS
fi

[[ -n "$SERVER_ADDRESS" ]] || die "Server address is required for the client link."

# Validate format: allow IPv4, hostname, domain, or bare IPv6
if [[ ! "$SERVER_ADDRESS" =~ ^[a-zA-Z0-9._-]+$  && \
      ! "$SERVER_ADDRESS" =~ ^[0-9a-fA-F:]+$ ]]; then
    die "Invalid server address '${SERVER_ADDRESS}'. Use an IPv4, IPv6, or domain name."
fi

# For VLESS URI: IPv6 addresses must be wrapped in brackets
if [[ "$SERVER_ADDRESS" =~ : ]]; then
    SERVER_ADDRESS_URI="[${SERVER_ADDRESS}]"
else
    SERVER_ADDRESS_URI="$SERVER_ADDRESS"
fi

ok "Server address: ${SERVER_ADDRESS}"

# =============================================================================
# STEP 8/10 — Select dest site for Reality
# =============================================================================
step "Step 8/10 — Selecting dest site for Reality masking"

# ── Site compatibility checker ─────────────────────────────────────────────
check_site() {
    local site="$1"
    local tls13_ok=false
    local reach_ok=false

    info "Checking ${site} …"

    # TLS 1.3 with SNI (mandatory)
    local tls_out
    set +e
    tls_out=$(echo "" | timeout 10 openssl s_client \
        -tls1_3 -servername "$site" -connect "${site}:443" 2>/dev/null)
    set -e
    if echo "$tls_out" | grep -q "TLSv1.3"; then
        echo -e "    ${GREEN}✓ TLS 1.3 supported${NC}"
        tls13_ok=true
    else
        echo -e "    ${RED}✗ TLS 1.3 not supported — site cannot be used${NC}"
    fi

    # HTTP/2 (strongly recommended, non-blocking)
    set +e
    local h2_hdr
    h2_hdr=$(curl -4 -sI --http2 "https://${site}" --connect-timeout 10 2>/dev/null | head -1)
    set -e
    if echo "$h2_hdr" | grep -qiE "HTTP/2|^HTTP/[0-9.]+ 2"; then
        echo -e "    ${GREEN}✓ HTTP/2 supported${NC}"
    else
        echo -e "    ${YELLOW}⚠ HTTP/2 not confirmed (non-critical)${NC}"
    fi

    # Reachability — must return 2xx or 3xx (mandatory)
    set +e
    local http_code
    http_code=$(curl -4 -o /dev/null -s -w "%{http_code}" \
        --connect-timeout 10 "https://${site}" 2>/dev/null)
    set -e
    http_code="${http_code:-000}"
    if [[ "$http_code" =~ ^[23] ]]; then
        echo -e "    ${GREEN}✓ Reachable (HTTP ${http_code})${NC}"
        reach_ok=true
    else
        echo -e "    ${RED}✗ Not reachable (HTTP ${http_code}) — site cannot be used${NC}"
    fi

    $tls13_ok && $reach_ok
}

# ── Interactive dest site selection loop ────────────────────────────────────
DEST_SITE=""
while [[ -z "$DEST_SITE" ]]; do
    echo ""
    echo -e "${BOLD}Choose a dest site for Reality masking:${NC}"
    local_idx=1
    for s in "${PRESET_SITES[@]}"; do
        echo "  ${local_idx}) ${s}"
        (( local_idx++ )) || true
    done
    echo "  ${local_idx}) Enter a custom site"
    echo ""

    CHOICE=""
    read -rp "Your choice [1–${local_idx}]: " CHOICE

    CANDIDATE=""
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE < local_idx )); then
        CANDIDATE="${PRESET_SITES[$((CHOICE - 1))]}"
    elif [[ "$CHOICE" == "$local_idx" ]]; then
        read -rp "Enter site hostname (e.g. www.example.com): " RAW_SITE
        CANDIDATE="${RAW_SITE#https://}"
        CANDIDATE="${CANDIDATE#http://}"
        CANDIDATE="${CANDIDATE%%/*}"
        CANDIDATE="${CANDIDATE%%\?*}"
        CANDIDATE="${CANDIDATE%%:*}"   # strip port — Reality dest always uses 443
    else
        warn "Invalid choice, please enter a number between 1 and ${local_idx}."
        continue
    fi

    if [[ -z "$CANDIDATE" ]]; then
        warn "Empty hostname, please try again."
        continue
    fi

    if check_site "$CANDIDATE"; then
        DEST_SITE="$CANDIDATE"
        ok "Dest site selected: ${DEST_SITE}"
    else
        warn "Site '${CANDIDATE}' did not pass the required checks. Please choose again."
    fi
done

# =============================================================================
# STEP 9/10 — Create Xray server configuration
# =============================================================================
step "Step 9/10 — Writing Xray server configuration"

# Backup existing config if present
if [[ -f "$XRAY_CONFIG" ]]; then
    local_bak="${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$XRAY_CONFIG" "$local_bak"
    info "Existing config backed up to ${local_bak}"
fi

install -d -m 755 "$(dirname "$XRAY_CONFIG")"

cat > "$XRAY_CONFIG" << XRAY_CONFIG_EOF
{
  "log": {
    "loglevel": "info",
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log"
  },
  "inbounds": [
    {
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision",
            "level": 0
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${DEST_SITE}:443",
          "serverNames": [
            "${DEST_SITE}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "minClientVer": "",
          "maxClientVer": "",
          "maxTimeDiff": 0,
          "shortIds": [
            "${SHORT_ID}"
          ],
          "fingerprint": "chrome"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "AsIs"
      }
    }
  ],
  "dns": {
    "servers": ["8.8.8.8", "8.8.4.4", "1.1.1.1"],
    "queryStrategy": "UseIPv4"
  }
}
XRAY_CONFIG_EOF

# 640: root owns, xray service (nobody:nogroup) can read, world cannot
chown root:nogroup "$XRAY_CONFIG" 2>/dev/null || chown root "$XRAY_CONFIG"
chmod 640 "$XRAY_CONFIG"
ok "Config written: ${XRAY_CONFIG}"

# =============================================================================
# STEP 10/10 — Validate config, start service
# =============================================================================
step "Step 10/10 — Validating config and starting Xray service"

# JSON syntax check (fast, precise error messages)
jq empty "$XRAY_CONFIG" || die "JSON syntax error in config — check ${XRAY_CONFIG}"
ok "JSON syntax valid"

# Xray semantic check
set +e
VALIDATE_OUT=$(xray run -test -config "$XRAY_CONFIG" 2>&1)
VALIDATE_RC=$?
set -e

if [[ $VALIDATE_RC -eq 0 ]]; then
    ok "Xray config validation passed"
else
    echo -e "${RED}${VALIDATE_OUT}${NC}"
    die "Xray rejected the config — check ${XRAY_CONFIG}"
fi

# Start service
systemctl daemon-reload
systemctl enable xray
systemctl restart xray

sleep 2

set +e
ACTIVE=$(systemctl is-active xray 2>/dev/null)
set -e

if [[ "$ACTIVE" == "active" ]]; then
    ok "xray.service is running"
else
    systemctl status xray --no-pager || true
    die "Xray failed to start — run: journalctl -u xray -n 50"
fi

# Verify port is listening
set +e
PORT_OPEN=$(ss -tlnp | grep ":${VLESS_PORT} " | head -1)
set -e
if [[ -n "$PORT_OPEN" ]]; then
    ok "Port ${VLESS_PORT} is listening"
else
    warn "Port ${VLESS_PORT} not yet in ss output — may need a moment"
fi

# =============================================================================
# FINAL — Client link, file, QR code
# =============================================================================
step "Generating client configuration"

VLESS_URI="vless://${UUID}@${SERVER_ADDRESS_URI}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SITE}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#MyVPN"

# Save to file (chmod 600 — root only)
cat > "$CLIENT_OUTPUT" << EOF
Server:      ${SERVER_ADDRESS}
Port:        ${VLESS_PORT}
UUID:        ${UUID}
Public key:  ${PUBLIC_KEY}
Short ID:    ${SHORT_ID}
Dest site:   ${DEST_SITE}
Fingerprint: chrome

${VLESS_URI}
EOF
chmod 600 "$CLIENT_OUTPUT"
ok "Client config saved to ${CLIENT_OUTPUT} (chmod 600)"

# ── Final output ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                    Setup Complete!                       ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

echo ""
echo -e "${BOLD}── Server Parameters ─────────────────────────────────────────${NC}"
echo -e "  Server      : ${CYAN}${SERVER_ADDRESS}${NC}"
echo -e "  Port        : ${CYAN}${VLESS_PORT}${NC}"
echo -e "  UUID        : ${CYAN}${UUID}${NC}"
echo -e "  Public Key  : ${CYAN}${PUBLIC_KEY}${NC}"
echo -e "  Short ID    : ${CYAN}${SHORT_ID}${NC}"
echo -e "  Dest site   : ${CYAN}${DEST_SITE}${NC}"
echo -e "  Fingerprint : ${CYAN}chrome${NC}"

echo ""
echo -e "${BOLD}── VLESS Connection Link ──────────────────────────────────────${NC}"
echo -e "${YELLOW}${VLESS_URI}${NC}"

echo ""
echo -e "${BOLD}── QR Code (scan with mobile client) ─────────────────────────${NC}"
qrencode -t ansiutf8 "$VLESS_URI"

echo ""
echo -e "${BOLD}── Useful Commands ───────────────────────────────────────────${NC}"
echo -e "  Status  : ${CYAN}systemctl status xray${NC}"
echo -e "  Logs    : ${CYAN}journalctl -u xray -f${NC}"
echo -e "  Restart : ${CYAN}systemctl restart xray${NC}"
echo -e "  Config  : ${CYAN}${XRAY_CONFIG}${NC}"
echo -e "  Saved   : ${CYAN}${CLIENT_OUTPUT}${NC}"

echo ""
echo -e "${BOLD}── Recommended Clients ───────────────────────────────────────${NC}"
echo "  Android : v2rayNG, Hiddify"
echo "  iOS     : Hiddify, Shadowrocket"
echo "  Windows : v2rayN"
echo "  macOS   : V2Box, Hiddify"
echo "  Linux   : Nekoray, Hiddify"
echo ""
