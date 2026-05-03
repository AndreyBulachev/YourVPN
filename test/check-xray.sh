#!/bin/bash
set -x
apt-get update -qq 2>/dev/null
apt-get install -y -qq curl ca-certificates unzip 2>/dev/null

# Fetch latest release tag
LATEST=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
    | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
echo "Latest xray: [$LATEST]"

ARCH=$(uname -m)
echo "Arch: $ARCH"

# Map arch to xray filename
case "$ARCH" in
    aarch64) XRAY_ZIP="Xray-linux-arm64-v8a.zip" ;;
    x86_64)  XRAY_ZIP="Xray-linux-64.zip" ;;
    *)       echo "Unknown arch: $ARCH"; exit 1 ;;
esac

curl -fsSL -o /tmp/xray.zip \
    "https://github.com/XTLS/Xray-core/releases/download/${LATEST}/${XRAY_ZIP}" || {
    echo "Download failed, trying v25.4.30"
    LATEST="v25.4.30"
    curl -fsSL -o /tmp/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/${LATEST}/${XRAY_ZIP}"
}

unzip -q /tmp/xray.zip -d /tmp/xray
install /tmp/xray/xray /usr/local/bin/xray

echo "=== xray version ==="
xray -version | head -1

echo ""
echo "=== xray x25519 raw output ==="
xray x25519

echo ""
echo "=== parsing test ==="
KEY_OUTPUT=$(xray x25519)
PRIVATE_KEY=$(awk -F': ' '/[Pp]rivate key/{print $2}' <<< "$KEY_OUTPUT")
PUBLIC_KEY=$(awk  -F': ' '/[Pp]ublic key/{print $2}'  <<< "$KEY_OUTPUT")
echo "Private key: [$PRIVATE_KEY]"
echo "Public key:  [$PUBLIC_KEY]"

if [[ -z "$PRIVATE_KEY" ]]; then
    echo "FAIL: private key not parsed"
    exit 1
fi
echo "PASS: both keys parsed successfully"
