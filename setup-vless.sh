#!/bin/bash
# =============================================================================
#  VLESS + XTLS-Reality VPN Server Setup
#  Ubuntu/Debian | Port 443 | Sections 2.3 and 3 of C1-vpn-theory-and-setup.md
# =============================================================================

set -uo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Constants ─────────────────────────────────────────────────────────────────
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_LOG_DIR="/var/log/xray"
VLESS_PORT=443
PRESET_SITES=(
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

# ── Pre-flight checks ─────────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && die "Run as root: sudo bash $0"

if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    [[ "$ID" != "ubuntu" && "$ID" != "debian" ]] && die "Requires Ubuntu or Debian (detected: $ID)"
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

# =============================================================================
# STEP 1 — System Update
# =============================================================================
step "Step 1/11 — System update"

apt-get update -y
apt-get upgrade -y
apt-get autoremove -y

ok "System packages updated"

# =============================================================================
# STEP 2 — Install utilities
# =============================================================================
step "Step 2/11 — Installing required utilities"

PACKAGES=(
    curl wget git vim nano htop net-tools
    netcat-openbsd iputils-ping telnet
    openssl ufw qrencode
)

apt-get install -y "${PACKAGES[@]}"

ok "Utilities installed: ${PACKAGES[*]}"

# =============================================================================
# STEP 3 — Firewall (UFW)
# =============================================================================
step "Step 3/11 — Configuring UFW firewall"

ufw allow 22/tcp    comment "SSH"
ufw allow 443/tcp   comment "VLESS/Reality"
ufw allow 443/udp   comment "VLESS/Reality UDP"
ufw --force enable

ufw status verbose
ok "Firewall active: SSH (22/tcp) and VLESS (443/tcp,udp) open"

# =============================================================================
# STEP 4 — Enable BBR
# =============================================================================
step "Step 4/11 — Enabling BBR TCP congestion control"

# Remove stale entries to avoid duplication on re-runs
sed -i '/^net\.core\.default_qdisc/d'           /etc/sysctl.conf
sed -i '/^net\.ipv4\.tcp_congestion_control/d'  /etc/sysctl.conf

{
    echo "net.core.default_qdisc=fq"
    echo "net.ipv4.tcp_congestion_control=bbr"
} >> /etc/sysctl.conf

sysctl -p > /dev/null 2>&1

BBR_ACTIVE=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
if [[ "$BBR_ACTIVE" == "bbr" ]]; then
    ok "BBR enabled (tcp_congestion_control=bbr)"
else
    warn "BBR may not be active (current: $BBR_ACTIVE). The kernel might need a reboot."
fi

# =============================================================================
# STEP 5 — Kernel network optimization
# =============================================================================
step "Step 5/11 — Optimizing kernel network parameters"

# Remove previous block if re-running the script
sed -i '/# >>> VPN Network Optimization >>>/,/# <<< VPN Network Optimization <<</d' /etc/sysctl.conf

cat >> /etc/sysctl.conf << 'SYSCTL'

# >>> VPN Network Optimization >>>
net.ipv4.tcp_rmem           = 4096 87380 67108864
net.ipv4.tcp_wmem           = 4096 65536 67108864
net.core.rmem_max           = 67108864
net.core.wmem_max           = 67108864
net.ipv4.tcp_max_syn_backlog = 4096
net.core.netdev_max_backlog  = 4096
net.ipv4.tcp_tw_reuse       = 1
net.core.somaxconn           = 4096
net.ipv4.ip_local_port_range = 1024 65535
# <<< VPN Network Optimization <<<
SYSCTL

sysctl -p > /dev/null 2>&1
ok "Kernel TCP buffers and connection limits optimized"

# =============================================================================
# STEP 6 — Install Xray-core
# =============================================================================
step "Step 6/11 — Installing Xray-core"

bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install \
    || die "Xray installation script failed"

XRAY_VERSION=$(xray -version 2>&1 | head -1) || die "xray binary not found after installation"
ok "$XRAY_VERSION"

mkdir -p "$XRAY_LOG_DIR"
# Xray installer creates user 'nobody'; log dir must be writable by it
chown nobody:nogroup "$XRAY_LOG_DIR" 2>/dev/null \
    || chown nobody "$XRAY_LOG_DIR" 2>/dev/null \
    || true

ok "Log directory: $XRAY_LOG_DIR"

# =============================================================================
# STEP 7 — Generate UUID, keypair, Short ID
# =============================================================================
step "Step 7/11 — Generating keys and UUID"

UUID=$(xray uuid) || die "Failed to generate UUID"
ok "UUID:       $UUID"

KEY_OUTPUT=$(xray x25519) || die "Failed to generate x25519 keypair"
PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk '/[Pp]rivate key/{print $NF}')
PUBLIC_KEY=$(echo "$KEY_OUTPUT"  | awk '/[Pp]ublic key/{print $NF}')

[[ -z "$PRIVATE_KEY" ]] && die "Could not parse private key from xray x25519 output"
[[ -z "$PUBLIC_KEY"  ]] && die "Could not parse public key from xray x25519 output"

ok "Public key: $PUBLIC_KEY"
info "Private key stored only in server config (not shown here)"

SHORT_ID=$(openssl rand -hex 8) || die "Failed to generate Short ID"
ok "Short ID:   $SHORT_ID"

# =============================================================================
# STEP 8 — Select dest site for Reality
# =============================================================================
step "Step 8/11 — Selecting dest site for Reality masking"

# ── Site compatibility checker ─────────────────────────────────────────────
check_site() {
    local site="$1"
    local tls13_ok=false
    local reach_ok=false

    info "Checking $site …"

    # TLS 1.3 (mandatory)
    local tls_out
    set +e
    tls_out=$(echo "" | timeout 10 openssl s_client -tls1_3 -connect "${site}:443" 2>/dev/null)
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
    h2_hdr=$(curl -sI --http2 "https://${site}" --connect-timeout 10 2>/dev/null | head -1)
    set -e
    if echo "$h2_hdr" | grep -qiE "HTTP/2|^HTTP/[0-9.]+ 2"; then
        echo -e "    ${GREEN}✓ HTTP/2 supported${NC}"
    else
        echo -e "    ${YELLOW}⚠ HTTP/2 not confirmed (non-critical)${NC}"
    fi

    # Reachability — must return 2xx or 3xx (mandatory)
    set +e
    local http_code
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --connect-timeout 10 "https://${site}" 2>/dev/null)
    set -e
    http_code="${http_code:-000}"
    if [[ "$http_code" =~ ^[23] ]]; then
        echo -e "    ${GREEN}✓ Reachable (HTTP $http_code)${NC}"
        reach_ok=true
    else
        echo -e "    ${RED}✗ Not reachable (HTTP $http_code) — site cannot be used${NC}"
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
        echo "  $local_idx) $s"
        (( local_idx++ ))
    done
    echo "  $local_idx) Enter a custom site"
    echo ""

    CHOICE=""
    read -rp "Your choice [1–${local_idx}]: " CHOICE

    CANDIDATE=""
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE < local_idx )); then
        CANDIDATE="${PRESET_SITES[$((CHOICE - 1))]}"
    elif [[ "$CHOICE" == "$local_idx" ]]; then
        read -rp "Enter site hostname (e.g. www.example.com): " RAW_SITE
        # Strip protocol and path
        CANDIDATE="${RAW_SITE#https://}"
        CANDIDATE="${CANDIDATE#http://}"
        CANDIDATE="${CANDIDATE%%/*}"
        CANDIDATE="${CANDIDATE%:*}"   # strip port if present
    else
        warn "Invalid choice, please enter a number between 1 and ${local_idx}."
        continue
    fi

    if check_site "$CANDIDATE"; then
        DEST_SITE="$CANDIDATE"
        ok "Dest site selected: $DEST_SITE"
    else
        warn "Site '${CANDIDATE}' did not pass the required checks."
        warn "Please choose a different site."
    fi
done

# =============================================================================
# STEP 9 — Create Xray server configuration
# =============================================================================
step "Step 9/11 — Writing Xray server configuration"

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
    },
    {
      "protocol": "blackhole",
      "tag": "block",
      "settings": {
        "response": {
          "type": "http"
        }
      }
    }
  ],
  "dns": {
    "servers": ["8.8.8.8", "8.8.4.4", "1.1.1.1"],
    "queryStrategy": "UseIPv4"
  }
}
XRAY_CONFIG_EOF

ok "Config written: $XRAY_CONFIG"

# =============================================================================
# STEP 10 — Validate configuration
# =============================================================================
step "Step 10/11 — Validating Xray configuration"

set +e
VALIDATE_OUT=$(xray run -test -config "$XRAY_CONFIG" 2>&1)
VALIDATE_RC=$?
set -e

if [[ $VALIDATE_RC -eq 0 ]]; then
    ok "Configuration passed validation"
else
    echo -e "${RED}Validation output:${NC}"
    echo "$VALIDATE_OUT"
    die "Config validation failed — check $XRAY_CONFIG"
fi

# =============================================================================
# STEP 11 — Start service and enable autostart
# =============================================================================
step "Step 11/11 — Starting Xray service"

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
    echo ""
    systemctl status xray --no-pager || true
    die "Xray service failed to start. Run: journalctl -u xray -n 50"
fi

# Also verify port is listening
set +e
PORT_OPEN=$(ss -tlnp | grep ":${VLESS_PORT} " | head -1)
set -e
if [[ -n "$PORT_OPEN" ]]; then
    ok "Port ${VLESS_PORT} is listening"
else
    warn "Port ${VLESS_PORT} not yet visible in ss output — may need a moment"
fi

# =============================================================================
# FINAL — Generate client link and QR code
# =============================================================================
step "Generating client configuration link and QR code"

# Resolve public IP
SERVER_IP=""
for SVC in "https://ifconfig.me" "https://api.ipify.org" "https://ipv4.icanhazip.com"; do
    set +e
    SERVER_IP=$(curl -s --max-time 8 "$SVC" 2>/dev/null | tr -d '[:space:]')
    set -e
    [[ "$SERVER_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    SERVER_IP=""
done

if [[ -z "$SERVER_IP" ]]; then
    warn "Could not auto-detect public IP. Falling back to hostname -I."
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

VLESS_URI="vless://${UUID}@${SERVER_IP}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DEST_SITE}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#MyVPN"

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║                    Setup Complete!                       ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"

echo ""
echo -e "${BOLD}── Server Parameters ─────────────────────────────────────────${NC}"
echo -e "  Server IP   : ${CYAN}${SERVER_IP}${NC}"
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
echo -e "${BOLD}── Useful Server Commands ────────────────────────────────────${NC}"
echo -e "  Status  : ${CYAN}systemctl status xray${NC}"
echo -e "  Logs    : ${CYAN}journalctl -u xray -f${NC}"
echo -e "  Restart : ${CYAN}systemctl restart xray${NC}"
echo -e "  Config  : ${CYAN}${XRAY_CONFIG}${NC}"

echo ""
echo -e "${BOLD}── Recommended Clients ───────────────────────────────────────${NC}"
echo "  Android : v2rayNG, Hiddify"
echo "  iOS     : Hiddify, Shadowrocket"
echo "  Windows : v2rayN"
echo "  macOS   : V2Box, Hiddify"
echo "  Linux   : Nekoray, Hiddify"
echo ""
