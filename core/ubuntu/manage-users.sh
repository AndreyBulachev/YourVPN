#!/bin/bash
# =============================================================================
#  Xray VLESS User Management
#  Add, list, inspect and delete users in an existing VLESS + XTLS-Reality setup
# =============================================================================

set -Eeuo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ── Constants ─────────────────────────────────────────────────────────────────
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly USERS_META="/root/xray-users-meta.json"
readonly CLIENT_OUTPUT="/root/xray-client.txt"
readonly VLESS_PORT=443

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
[[ -f "$XRAY_CONFIG" ]] || die "Xray config not found at ${XRAY_CONFIG}. Run setup-vless.sh first."
command -v jq       > /dev/null 2>&1 || die "jq not found (apt install jq)"
command -v xray     > /dev/null 2>&1 || die "xray binary not found"
command -v qrencode > /dev/null 2>&1 || die "qrencode not found (apt install qrencode)"
command -v openssl  > /dev/null 2>&1 || die "openssl not found"

# ── Config accessors ──────────────────────────────────────────────────────────

get_public_key() {
    local priv
    priv=$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' "$XRAY_CONFIG")

    # Derive public key from stored private key
    local out pub
    set +e
    out=$(xray x25519 -i "$priv" 2>&1)
    set -e
    pub=$(awk -F': ' '/PublicKey|[Pp]ublic key/{print $2; exit}' <<< "$out")

    if [[ -n "$pub" ]]; then
        echo "$pub"
        return
    fi

    # Fallback: read from saved client file
    if [[ -f "$CLIENT_OUTPUT" ]]; then
        pub=$(grep -i "public key" "$CLIENT_OUTPUT" | awk -F': ' '{print $2}' | head -1 | tr -d ' ' || true)
        [[ -n "$pub" ]] && echo "$pub" && return
    fi

    die "Could not determine public key. Check ${XRAY_CONFIG} or ${CLIENT_OUTPUT}."
}

get_dest_site() {
    jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' "$XRAY_CONFIG"
}

get_fingerprint() {
    jq -r '.inbounds[0].streamSettings.realitySettings.fingerprint // "chrome"' "$XRAY_CONFIG"
}

# ── Metadata helpers ──────────────────────────────────────────────────────────
# Sidecar file /root/xray-users-meta.json stores per-user name, short ID, and
# creation date — data that Xray config doesn't naturally carry.

meta_init() {
    if [[ ! -f "$USERS_META" ]]; then
        echo '{"server_address":"","users":{}}' > "$USERS_META"
        chmod 600 "$USERS_META"
    fi
}

meta_get_server_address() {
    [[ -f "$USERS_META" ]] && jq -r '.server_address // empty' "$USERS_META" 2>/dev/null || true
}

meta_set_server_address() {
    meta_init
    local tmp; tmp=$(mktemp)
    jq --arg v "$1" '.server_address = $v' "$USERS_META" > "$tmp"
    mv "$tmp" "$USERS_META"; chmod 600 "$USERS_META"
}

meta_get() {
    local uuid="$1" field="$2"
    [[ -f "$USERS_META" ]] && jq -r --arg u "$uuid" --arg f "$field" '.users[$u][$f] // empty' "$USERS_META" 2>/dev/null || true
}

meta_add_user() {
    local uuid="$1" name="$2" short_id="$3"
    meta_init
    local tmp; tmp=$(mktemp)
    jq --arg u "$uuid" --arg n "$name" --arg s "$short_id" --arg d "$(date +%Y-%m-%d)" \
        '.users[$u] = {"name":$n,"short_id":$s,"created":$d}' \
        "$USERS_META" > "$tmp"
    mv "$tmp" "$USERS_META"; chmod 600 "$USERS_META"
}

meta_remove_user() {
    [[ -f "$USERS_META" ]] || return 0
    local tmp; tmp=$(mktemp)
    jq --arg u "$1" 'del(.users[$u])' "$USERS_META" > "$tmp"
    mv "$tmp" "$USERS_META"
}

# ── Server address detection ──────────────────────────────────────────────────

detect_server_address() {
    local addr

    addr=$(meta_get_server_address)
    [[ -n "$addr" ]] && echo "$addr" && return

    if [[ -f "$CLIENT_OUTPUT" ]]; then
        addr=$(grep "^Server:" "$CLIENT_OUTPUT" | awk '{print $2}' || true)
        [[ -n "$addr" ]] && echo "$addr" && return
    fi

    for SVC in "https://api.ipify.org" "https://ifconfig.me" "https://ipv4.icanhazip.com"; do
        set +e
        addr=$(curl -4 -s --max-time 8 "$SVC" 2>/dev/null | tr -d '[:space:]')
        set -e
        [[ "$addr" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$addr" && return
    done

    echo ""
}

# ── VLESS URI builder ─────────────────────────────────────────────────────────

build_vless_uri() {
    local uuid="$1" name="$2" server="$3" pubkey="$4" sid="$5" dest="$6" fp="${7:-chrome}"
    local host="$server"
    [[ "$server" =~ : ]] && host="[${server}]"
    echo "vless://${uuid}@${host}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${dest}&fp=${fp}&pbk=${pubkey}&sid=${sid}&type=tcp#${name}"
}

# ── Per-user name / short_id resolution ──────────────────────────────────────

resolve_name() {
    local uuid="$1"
    local name
    name=$(meta_get "$uuid" "name")
    [[ -z "$name" ]] && name=$(jq -r --arg u "$uuid" \
        '.inbounds[0].settings.clients[] | select(.id==$u) | .email // empty' "$XRAY_CONFIG" 2>/dev/null || true)
    echo "${name:-(unnamed)}"
}

resolve_short_id() {
    local uuid="$1"
    local sid
    sid=$(meta_get "$uuid" "short_id")
    [[ -z "$sid" ]] && sid=$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' "$XRAY_CONFIG")
    echo "$sid"
}

# ── Print full user card ──────────────────────────────────────────────────────

print_user_card() {
    local uuid="$1" name="$2" sid="$3" server="$4" pubkey="$5" dest="$6" fp="$7" created="${8:-}"

    echo ""
    echo -e "${BOLD}── User: ${CYAN}${name}${NC} ────────────────────────────────────────"
    echo -e "  Name        : ${CYAN}${name}${NC}"
    echo -e "  UUID        : ${CYAN}${uuid}${NC}"
    echo -e "  Short ID    : ${CYAN}${sid}${NC}"
    [[ -n "$created" ]] && echo -e "  Created     : ${CYAN}${created}${NC}"

    local uri
    uri=$(build_vless_uri "$uuid" "$name" "$server" "$pubkey" "$sid" "$dest" "$fp")

    echo ""
    echo -e "${BOLD}── Connection Link ──────────────────────────────────────────${NC}"
    echo -e "${YELLOW}${uri}${NC}"

    echo ""
    echo -e "${BOLD}── QR Code (scan with mobile client) ────────────────────────${NC}"
    qrencode -t ansiutf8 "$uri"
}

# ── Apply config helper ───────────────────────────────────────────────────────

apply_config() {
    local tmp="$1"

    jq empty "$tmp" || die "JSON syntax error in generated config"

    local val_out val_rc
    set +e
    val_out=$(xray run -test -config "$tmp" 2>&1)
    val_rc=$?
    set -e
    if [[ $val_rc -ne 0 ]]; then
        rm -f "$tmp"
        echo -e "${RED}${val_out}${NC}"
        die "Xray config validation failed"
    fi

    local bak
    bak="${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$XRAY_CONFIG" "$bak"

    chown root:nogroup "$tmp" 2>/dev/null || chown root "$tmp" 2>/dev/null || true
    chmod 640 "$tmp"
    mv "$tmp" "$XRAY_CONFIG"

    systemctl restart xray
    sleep 1

    local active
    set +e; active=$(systemctl is-active xray 2>/dev/null); set -e
    if [[ "$active" == "active" ]]; then
        ok "Xray restarted successfully"
    else
        warn "Xray may not be running — check: systemctl status xray"
    fi

    info "Previous config backed up to: ${bak}"
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_list() {
    step "User list"

    local count
    count=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONFIG")

    if [[ "$count" -eq 0 ]]; then
        warn "No users configured"
        return
    fi

    info "${count} user(s) in config:"
    echo ""
    printf "  %-4s  %-24s  %-38s  %s\n" "#" "Name" "UUID" "Created"
    printf "  %-4s  %-24s  %-38s  %s\n" "----" "------------------------" "--------------------------------------" "----------"

    local i=0
    while IFS= read -r uuid; do
        local name created
        name=$(resolve_name "$uuid")
        created=$(meta_get "$uuid" "created")
        printf "  %-4s  %-24s  %-38s  %s\n" "$((i+1))" "$name" "$uuid" "$created"
        (( i++ )) || true
    done < <(jq -r '.inbounds[0].settings.clients[].id' "$XRAY_CONFIG")

    echo ""
}

cmd_info() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        cmd_list
        read -rp "  Enter user number or UUID: " target
        [[ -z "$target" ]] && return
    fi

    local uuid
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        local idx=$(( target - 1 ))
        uuid=$(jq -r --argjson i "$idx" '.inbounds[0].settings.clients[$i].id // empty' "$XRAY_CONFIG")
        [[ -z "$uuid" ]] && die "User #${target} not found"
    else
        uuid="$target"
        local exists
        exists=$(jq -r --arg u "$uuid" \
            '.inbounds[0].settings.clients[] | select(.id==$u) | .id' "$XRAY_CONFIG" || true)
        [[ -z "$exists" ]] && die "User '${uuid}' not found in config"
    fi

    local name sid created server pubkey dest fp
    name=$(resolve_name "$uuid")
    sid=$(resolve_short_id "$uuid")
    created=$(meta_get "$uuid" "created")

    server=$(detect_server_address)
    if [[ -z "$server" ]]; then
        warn "Could not auto-detect server address"
        read -rp "  Enter server IP/domain: " server
        meta_set_server_address "$server"
    fi

    pubkey=$(get_public_key)
    dest=$(get_dest_site)
    fp=$(get_fingerprint)

    step "User info"
    print_user_card "$uuid" "$name" "$sid" "$server" "$pubkey" "$dest" "$fp" "$created"
    echo ""
}

cmd_add() {
    step "Add new user"

    local name
    read -rp "  User name: " name
    [[ -z "$name" ]] && die "Name cannot be empty"

    # Warn on duplicate name (non-fatal — UUIDs are the real identifiers)
    if [[ -f "$USERS_META" ]]; then
        local dup
        dup=$(jq -r --arg n "$name" '.users[] | select(.name==$n) | .name' "$USERS_META" 2>/dev/null || true)
        [[ -n "$dup" ]] && warn "A user named '${name}' already exists (proceeding anyway)"
    fi

    local uuid short_id
    uuid=$(xray uuid)     || die "Failed to generate UUID"
    short_id=$(openssl rand -hex 8) || die "Failed to generate Short ID"
    ok "UUID:     ${uuid}"
    ok "Short ID: ${short_id}"

    local tmp; tmp=$(mktemp)
    jq --arg uuid "$uuid" --arg name "$name" --arg sid "$short_id" \
        '.inbounds[0].settings.clients += [{"id":$uuid,"email":$name,"flow":"xtls-rprx-vision","level":0}] |
         .inbounds[0].streamSettings.realitySettings.shortIds += [$sid]' \
        "$XRAY_CONFIG" > "$tmp"

    apply_config "$tmp"
    meta_add_user "$uuid" "$name" "$short_id"

    local server
    server=$(detect_server_address)
    if [[ -z "$server" ]]; then
        warn "Could not auto-detect server address"
        read -rp "  Enter server IP/domain: " server
        meta_set_server_address "$server"
    fi

    local pubkey dest fp
    pubkey=$(get_public_key)
    dest=$(get_dest_site)
    fp=$(get_fingerprint)

    print_user_card "$uuid" "$name" "$short_id" "$server" "$pubkey" "$dest" "$fp" "$(date +%Y-%m-%d)"
    echo ""
    ok "User '${name}' added"
}

cmd_delete() {
    local target="${1:-}"

    if [[ -z "$target" ]]; then
        cmd_list
        read -rp "  Enter user number or UUID to delete: " target
        [[ -z "$target" ]] && return
    fi

    local uuid
    if [[ "$target" =~ ^[0-9]+$ ]]; then
        local idx=$(( target - 1 ))
        uuid=$(jq -r --argjson i "$idx" '.inbounds[0].settings.clients[$i].id // empty' "$XRAY_CONFIG")
        [[ -z "$uuid" ]] && die "User #${target} not found"
    else
        uuid="$target"
        local exists
        exists=$(jq -r --arg u "$uuid" \
            '.inbounds[0].settings.clients[] | select(.id==$u) | .id' "$XRAY_CONFIG" || true)
        [[ -z "$exists" ]] && die "User '${uuid}' not found in config"
    fi

    local count
    count=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONFIG")
    [[ "$count" -le 1 ]] && die "Cannot delete the last user — the server needs at least one."

    local name
    name=$(resolve_name "$uuid")

    echo ""
    warn "About to delete user: ${BOLD}${name}${NC} (${uuid})"
    local answer
    read -r -p "  Confirm deletion? [y/N]: " answer
    [[ "$answer" =~ ^[YyДд]$ ]] || { info "Deletion cancelled."; return; }

    local sid
    sid=$(meta_get "$uuid" "short_id")

    local tmp; tmp=$(mktemp)
    if [[ -n "$sid" ]]; then
        jq --arg u "$uuid" --arg s "$sid" \
            '.inbounds[0].settings.clients = [.inbounds[0].settings.clients[] | select(.id!=$u)] |
             .inbounds[0].streamSettings.realitySettings.shortIds = [.inbounds[0].streamSettings.realitySettings.shortIds[] | select(.!=$s)]' \
            "$XRAY_CONFIG" > "$tmp"

        # Ensure shortIds stays non-empty (edge case: server was set up with one shared short ID)
        local sid_count
        sid_count=$(jq '.inbounds[0].streamSettings.realitySettings.shortIds | length' "$tmp")
        if [[ "$sid_count" -eq 0 ]]; then
            warn "shortIds would become empty — keeping original short IDs"
            jq --arg u "$uuid" \
                '.inbounds[0].settings.clients = [.inbounds[0].settings.clients[] | select(.id!=$u)]' \
                "$XRAY_CONFIG" > "$tmp"
        fi
    else
        jq --arg u "$uuid" \
            '.inbounds[0].settings.clients = [.inbounds[0].settings.clients[] | select(.id!=$u)]' \
            "$XRAY_CONFIG" > "$tmp"
    fi

    apply_config "$tmp"
    meta_remove_user "$uuid"

    ok "User '${name}' deleted"
}

# ── Interactive menu ──────────────────────────────────────────────────────────

show_menu() {
    echo -e "${BOLD}${CYAN}"
    cat << 'BANNER'
╔══════════════════════════════════════════════════════╗
║      Xray VLESS — User Management                    ║
╚══════════════════════════════════════════════════════╝
BANNER
    echo -e "${NC}"

    while true; do
        local count
        count=$(jq '.inbounds[0].settings.clients | length' "$XRAY_CONFIG" 2>/dev/null || echo "?")
        info "Users in config: ${count}"
        echo ""
        echo -e "  ${BOLD}1)${NC} List users"
        echo -e "  ${BOLD}2)${NC} Show user info + connection link"
        echo -e "  ${BOLD}3)${NC} Add user"
        echo -e "  ${BOLD}4)${NC} Delete user"
        echo -e "  ${BOLD}0)${NC} Exit"
        echo ""
        local choice
        read -rp "Your choice [0–4]: " choice

        case "$choice" in
            1) cmd_list ;;
            2) cmd_info ;;
            3) cmd_add ;;
            4) cmd_delete ;;
            0) info "Goodbye!"; exit 0 ;;
            *) warn "Invalid choice — enter a number from 0 to 4" ;;
        esac
    done
}

# ── Entry point ───────────────────────────────────────────────────────────────

usage() {
    echo "Usage: sudo bash $0 [list | info [<num|uuid>] | add | delete [<num|uuid>]]"
    echo "  (no arguments) — interactive menu"
}

case "${1:-}" in
    list)         cmd_list ;;
    info)         cmd_info "${2:-}" ;;
    add)          cmd_add ;;
    delete)       cmd_delete "${2:-}" ;;
    -h|--help)    usage ;;
    "")           show_menu ;;
    *)            die "Unknown command: $1  (run with --help for usage)" ;;
esac
