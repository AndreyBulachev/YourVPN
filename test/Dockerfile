FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Install all packages the setup script needs
RUN apt-get update -y && \
    apt-get install -y \
        ca-certificates curl wget unzip \
        net-tools netcat-openbsd iputils-ping \
        openssl jq ufw qrencode \
        openssh-server \
    && rm -rf /var/lib/apt/lists/*

# Install xray directly (xray-install requires systemd, not available in Docker)
RUN ARCH=$(uname -m); \
    case "$ARCH" in \
        aarch64) ZIP="Xray-linux-arm64-v8a.zip" ;; \
        x86_64)  ZIP="Xray-linux-64.zip" ;; \
        *) echo "Unsupported arch: $ARCH" && exit 1 ;; \
    esac && \
    curl -fsSL -o /tmp/xray.zip \
        "https://github.com/XTLS/Xray-core/releases/download/v25.4.30/${ZIP}" && \
    unzip -q /tmp/xray.zip -d /tmp/xray && \
    install /tmp/xray/xray /usr/local/bin/xray && \
    rm -rf /tmp/xray /tmp/xray.zip && \
    xray -version

# Stubs for things that don't work in Docker
COPY stubs/ /usr/local/sbin/

COPY run-test.sh /run-test.sh
RUN chmod +x /run-test.sh /usr/local/sbin/*

CMD ["/run-test.sh"]
