#!/bin/bash
#
# TailGuard installer
# ===================
# Keeps Tailscale reachable when a VPN mangles your Mac's routing/DNS by
# pinning Tailscale's control-plane + DERP traffic to your physical uplink.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/scrm77/tailguard/main/install.sh | sudo bash
#   sudo ./install.sh            # install (default)
#   sudo ./install.sh status     # show daemon + route state
#   sudo ./install.sh uninstall  # remove everything
#
# macOS only. Requires root (it edits the routing table).

set -euo pipefail

LABEL="com.tailguard.monitor"
INSTALL_DIR="/Library/Application Support/tailguard"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
LOG="/var/log/tailguard.log"
FIX="${INSTALL_DIR}/fix-routes.sh"
MON="${INSTALL_DIR}/route-monitor.sh"

c_green=$'\033[0;32m'; c_yellow=$'\033[0;33m'; c_red=$'\033[0;31m'; c_dim=$'\033[2m'; c_off=$'\033[0m'
say()  { echo "${c_green}==>${c_off} $*"; }
warn() { echo "${c_yellow}==>${c_off} $*"; }
die()  { echo "${c_red}error:${c_off} $*" >&2; exit 1; }

[ "$(uname)" = "Darwin" ] || die "TailGuard is macOS only."
if [ "$(id -u)" != "0" ]; then
    exec sudo "$0" "$@"
fi

write_fix_script() {
    cat > "$FIX" <<'EOF_FIX'
#!/bin/bash
# fix-routes.sh (TailGuard) — pin Tailscale control-plane + DERP traffic to the
# physical default gateway so Tailscale survives a VPN that mangles routing/DNS.
# Idempotent: silent no-op when nothing needs changing. Must run as root.

LOG="/var/log/tailguard.log"
STATE="/Library/Application Support/tailguard/pinned.txt"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"; }

# Resolve default gateway + interface (wait up to 15s for the network to settle)
GATEWAY=""; IFACE=""
for _ in 1 2 3 4 5; do
    line=$(route -n get default 2>/dev/null)
    GATEWAY=$(echo "$line" | awk '/gateway:/{print $2}')
    IFACE=$(echo "$line"  | awk '/interface:/{print $2}')
    [ -n "$GATEWAY" ] && break
    sleep 3
done
[ -z "$GATEWAY" ] && { log "ERROR: no default gateway after 15s"; exit 1; }

# Safety: if the default route is itself a tunnel we cannot pin to a physical
# uplink — bail rather than break routing. (Covers full-tunnel VPNs.)
case "$IFACE" in
    utun*|ipsec*|ppp*|gif*|stf*|"")
        log "default on '$IFACE' (tunnel) — skipping; need a physical uplink as default"
        exit 0 ;;
esac

# --- Evict stale landmines FIRST ---
# Any host route WE previously pinned (tracked in $STATE) that now points to a
# gateway other than the current one is a leftover from a previous network and
# black-holes traffic. Remove it before anything else — this runs even when the
# DERP fetch below fails, so a network change never strands old DERP pins.
evicted=0
if [ -f "$STATE" ]; then
    while read -r dest gw; do
        [ "$gw" = "$GATEWAY" ] && continue
        case "$dest" in [0-9]*) ;; *) continue ;; esac
        if grep -qxF "$dest" "$STATE" 2>/dev/null; then
            route -n delete -host "$dest" >/dev/null 2>&1
            evicted=$((evicted + 1))
        fi
    done < <(netstat -rn -f inet 2>/dev/null | awk '$1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print $1" "$2}')
fi

# 1) DERP relays — live map (no python dependency; parse JSON with grep).
# Retry while the network settles: right after a network change the link and
# gateway are up but internet/DNS isn't ready yet, so a single fetch returns
# nothing. Without retrying, the run pins no DERP and never re-runs (no further
# route event), stranding Tailscale until a manual toggle.
LIVE_IPS=""
for _ in 1 2 3 4 5 6 7 8; do
    LIVE_IPS=$(curl -s --connect-timeout 5 https://controlplane.tailscale.com/derpmap/default 2>/dev/null \
        | grep -oE '"IPv4"[[:space:]]*:[[:space:]]*"[0-9.]+"' \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+')
    [ -n "$LIVE_IPS" ] && break
    sleep 10
done

if [ -n "$LIVE_IPS" ]; then
    derp_source="live ($(echo "$LIVE_IPS" | grep -c .) IPs)"
    BYPASS_HOSTS=($LIVE_IPS)
else
    derp_source="offline"
    BYPASS_HOSTS=()
fi

# 2) Control-plane subnets — resolve dynamically + known Tailscale /24 baseline
#    (192.200.0.0/24 is owned by Tailscale Inc., NetName TAILS)
CONTROL_PREFIXES=("192.200.0.0/24")
for host in controlplane.tailscale.com login.tailscale.com; do
    for ip in $(dig +short "$host" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'); do
        CONTROL_PREFIXES+=("${ip%.*}.0/24")
    done
done
CONTROL_PREFIXES=($(printf '%s\n' "${CONTROL_PREFIXES[@]}" | sort -u))

added=0; skipped=0; stale_count=0

# Pin DERP host routes via the physical gateway
for ip in "${BYPASS_HOSTS[@]}"; do
    if route -n get "$ip" 2>/dev/null | grep -q "gateway: $GATEWAY"; then
        skipped=$((skipped + 1))
    else
        route -n delete -host "$ip" >/dev/null 2>&1
        route -n add    -host "$ip" "$GATEWAY" >/dev/null 2>&1
        added=$((added + 1))
    fi
done

# Record everything we pin so a future run can evict it if it goes stale
# (accumulate + dedupe; cap to keep the file bounded)
if [ "${#BYPASS_HOSTS[@]}" -gt 0 ]; then
    { cat "$STATE" 2>/dev/null; printf '%s\n' "${BYPASS_HOSTS[@]}"; } \
        | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u | tail -1000 > "$STATE.tmp" \
        && mv "$STATE.tmp" "$STATE"
fi

# Pin control-plane subnets; clear any stale /32s a VPN injected inside them
for prefix in "${CONTROL_PREFIXES[@]}"; do
    net="${prefix%/*}"; three="${net%.*}"; esc="${three//./\\.}"
    prefix_stale=0
    stale=$(netstat -rn 2>/dev/null | awk '/^'"$esc"'\.[0-9]/ && $2 != "'"$GATEWAY"'" {print $1}')
    if [ -n "$stale" ]; then
        for s in $stale; do
            route -n delete -host "$s" >/dev/null 2>&1
            prefix_stale=$((prefix_stale + 1))
        done
    fi
    stale_count=$((stale_count + prefix_stale))
    cur=$(route -n get -net "$prefix" 2>/dev/null | awk '/gateway:/{print $2}')
    if [ "$cur" != "$GATEWAY" ] || [ "$prefix_stale" -gt 0 ]; then
        route -n delete -net "$prefix" >/dev/null 2>&1
        route -n add    -net "$prefix" "$GATEWAY" >/dev/null 2>&1
        added=$((added + 1))
    fi
done

# Log only when something actually changed
if [ "$added" -gt 0 ] || [ "$stale_count" -gt 0 ] || [ "$evicted" -gt 0 ]; then
    log "iface=$IFACE gw=$GATEWAY derp=$derp_source control=${#CONTROL_PREFIXES[@]} | added=$added skipped=$skipped stale=$stale_count evicted=$evicted"
fi
EOF_FIX
    chmod 755 "$FIX"
}

write_monitor_script() {
    cat > "$MON" <<'EOF_MON'
#!/bin/bash
# route-monitor.sh (TailGuard) — event-driven trigger for fix-routes.sh.
# Listens to `route -n monitor` and re-applies bypass routes only when the
# routing table changes in a relevant way. Pure bash, no dependencies.

FIX="/Library/Application Support/tailguard/fix-routes.sh"
LOG="/var/log/tailguard.log"
DEBOUNCE=2   # seconds of quiet after an event before firing
COOLDOWN=3   # minimum seconds between consecutive fix runs

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [monitor] $1" >> "$LOG"; }

last_fix=0
fire() {
    local now gap; now=$(date +%s); gap=$((now - last_fix))
    [ "$gap" -lt "$COOLDOWN" ] && sleep $((COOLDOWN - gap))
    /bin/bash "$FIX"
    last_fix=$(date +%s)
}

log "monitor starting"
/bin/bash "$FIX"            # initial apply (like RunAtLoad)
last_fix=$(date +%s)

pending=0
while true; do
    if [ "$pending" -eq 1 ]; then
        # Wait up to DEBOUNCE for the next event; timeout => storm settled, fire.
        if IFS= read -r -t "$DEBOUNCE" line; then
            :
        else
            pending=0
            fire
            continue
        fi
    else
        IFS= read -r line || { log "route monitor stream ended; exiting for restart"; exit 1; }
    fi
    case "$line" in
        *RTM_ADD*|*RTM_CHANGE*|*RTM_DELETE*|*RTM_IFINFO*|*192.200.0.*|*default*)
            pending=1 ;;
    esac
done < <(exec route -n monitor 2>/dev/null)
EOF_MON
    chmod 755 "$MON"
}

write_plist() {
    cat > "$PLIST" <<EOF_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${MON}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>StandardErrorPath</key>
    <string>/var/log/tailguard-err.log</string>
    <key>StandardOutPath</key>
    <string>/var/log/tailguard-out.log</string>
</dict>
</plist>
EOF_PLIST
    chown root:wheel "$PLIST"
    chmod 644 "$PLIST"
}

do_install() {
    command -v route >/dev/null   || die "missing 'route' (unexpected on macOS)"
    command -v netstat >/dev/null || die "missing 'netstat' (unexpected on macOS)"

    say "Installing TailGuard into ${INSTALL_DIR}"
    mkdir -p "$INSTALL_DIR"
    : > "$LOG" 2>/dev/null || true

    write_fix_script
    write_monitor_script
    write_plist

    say "Loading daemon (${LABEL})"
    launchctl bootout system "$PLIST" 2>/dev/null || true
    launchctl bootstrap system "$PLIST"

    sleep 2
    if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
        say "${c_green}Installed.${c_off} Daemon is running and watching the routing table."
        echo "${c_dim}  logs:      tail -f ${LOG}${c_off}"
        echo "${c_dim}  status:    sudo $0 status${c_off}"
        echo "${c_dim}  uninstall: sudo $0 uninstall${c_off}"
    else
        die "daemon failed to load — check /var/log/tailguard-err.log"
    fi
}

do_uninstall() {
    say "Removing TailGuard"
    launchctl bootout system "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    rm -rf "$INSTALL_DIR"
    warn "Left logs in place: ${LOG} (remove manually if you want)."
    warn "Bypass routes already in the table are harmless and clear on next network change/reboot."
    say "Done."
}

do_status() {
    echo "${c_green}daemon:${c_off}"
    if launchctl print "system/${LABEL}" >/dev/null 2>&1; then
        launchctl print "system/${LABEL}" 2>/dev/null | awk '/state = |pid = /{print "  "$0}'
    else
        echo "  not loaded"
    fi
    echo "${c_green}default route:${c_off}"
    route -n get default 2>/dev/null | awk '/gateway:|interface:/{print "  "$0}'
    echo "${c_green}control-plane (192.200.0.0/24) route:${c_off}"
    route -n get -net 192.200.0.0/24 2>/dev/null | awk '/gateway:|interface:/{print "  "$0}'
    echo "${c_green}recent log:${c_off}"
    tail -n 8 "$LOG" 2>/dev/null | sed 's/^/  /' || echo "  (no log yet)"
}

case "${1:-install}" in
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    do_status ;;
    *) die "unknown command '${1}'. Use: install | status | uninstall" ;;
esac
