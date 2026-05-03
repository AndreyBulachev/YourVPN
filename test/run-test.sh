#!/bin/bash
# Smoke-test for setup-vless.sh inside Docker (Ubuntu 24.04, no systemd).
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass() { echo -e "${GREEN}PASS${NC}  $1"; }
fail() { echo -e "${RED}FAIL${NC}  $1"; exit 1; }
info() { echo -e "${YELLOW}----${NC}  $1"; }

# ── Sanity checks ──────────────────────────────────────────────────────────────
info "xray version: $(xray -version 2>&1 | head -1)"

info "xray x25519 raw output:"
xray x25519

info "Parsing test:"
KEY_OUTPUT=$(xray x25519 2>&1)
PRIVATE_KEY=$(awk -F': ' '/[Pp]rivate key/{print $2; exit}' <<< "$KEY_OUTPUT")
PUBLIC_KEY=$(awk  -F': ' '/[Pp]ublic key/{print $2; exit}'  <<< "$KEY_OUTPUT")
[[ -n "$PRIVATE_KEY" ]] && pass "Private key parsed" || fail "Private key parse failed. Raw: $KEY_OUTPUT"
[[ -n "$PUBLIC_KEY"  ]] && pass "Public key parsed"  || fail "Public key parse failed. Raw: $KEY_OUTPUT"

# ── Patch script for Docker ────────────────────────────────────────────────────
# We apply targeted line-by-line replacements using Python (more reliable than
# chaining sed with pipes/special chars as delimiters).
python3 - /core/ubuntu/setup-vless.sh > /tmp/setup-patched.sh << 'PYEOF'
import sys, re

replacements = [
    # Skip apt (already done in Dockerfile)
    (r'DEBIAN_FRONTEND=noninteractive apt-get update.*',
     'echo "[stub] apt update skipped"'),
    (r'DEBIAN_FRONTEND=noninteractive apt-get upgrade.*',
     'echo "[stub] apt upgrade skipped"'),
    (r'DEBIAN_FRONTEND=noninteractive apt-get autoremove.*',
     'echo "[stub] apt autoremove skipped"'),
    (r'DEBIAN_FRONTEND=noninteractive apt-get install.*',
     'echo "[stub] apt install skipped"'),
    # Skip xray reinstall (already installed in Dockerfile)
    (r'.*Xray-install.*',
     'echo "[stub] xray already installed"'),
    (r'.*die "Xray installation script failed".*',
     'true'),
    # Skip sysctl (not available in Docker)
    (r'sysctl --system.*',
     'echo "[stub] sysctl skipped"'),
    # check_site always passes in Docker (no real internet TLS test needed)
    (r'if check_site "\$CANDIDATE"; then',
     'if true; then  # stub: site check skipped in Docker'),
    # Make ss show the port as listening
    (r'PORT_OPEN=\$\(ss -tlnp.*\)',
     'PORT_OPEN=":443 stub"'),
]

with open(sys.argv[1]) as f:
    lines = f.readlines()

for i, line in enumerate(lines):
    for pattern, replacement in replacements:
        if re.search(pattern, line):
            indent = len(line) - len(line.lstrip())
            lines[i] = ' ' * indent + replacement + '\n'
            break

sys.stdout.writelines(lines)
PYEOF

chmod +x /tmp/setup-patched.sh

echo ""
info "Running setup-vless.sh (stubbed)..."
echo ""

# Interactive answers fed via stdin:
#   "y"       — confirm installation
#   "1.2.3.4" — server address
#   "1"       — first preset dest site (www.microsoft.com)
printf 'y\n1.2.3.4\n1\n' | bash /tmp/setup-patched.sh

echo ""
pass "setup-vless.sh completed without errors"

# ── Post-run checks ────────────────────────────────────────────────────────────
echo ""
info "Post-run checks:"

CONFIG="/usr/local/etc/xray/config.json"
[[ -f "$CONFIG" ]] && pass "Config file exists" || fail "Config file missing: $CONFIG"

PERMS=$(stat -c '%a' "$CONFIG")
[[ "$PERMS" == "640" ]] && pass "Config permissions: 640" \
                         || fail "Config permissions wrong: $PERMS (expected 640)"

OWNER=$(stat -c '%U:%G' "$CONFIG")
[[ "$OWNER" == "root:nogroup" || "$OWNER" == "root:root" ]] \
    && pass "Config owner: $OWNER" \
    || fail "Config owner unexpected: $OWNER"

jq empty "$CONFIG" && pass "Config is valid JSON" || fail "Config JSON invalid"

CLIENT="/root/xray-client.txt"
[[ -f "$CLIENT" ]] && pass "Client config saved" || fail "Client config missing: $CLIENT"

CPERMS=$(stat -c '%a' "$CLIENT")
[[ "$CPERMS" == "600" ]] && pass "Client file permissions: 600" \
                           || fail "Client file permissions wrong: $CPERMS (expected 600)"

echo ""
info "Client config contents:"
cat "$CLIENT"
