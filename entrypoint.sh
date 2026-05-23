#!/bin/bash
set -e

# Create /dev/disk/by-id to silence AceStream disk lookup warnings
mkdir -p /dev/disk/by-id

get_external_ip() {
    local response

    if response=$(curl -4fsS --max-time 5 "https://ifconfig.co/json" 2>/dev/null); then
        EXTERNAL_IP=$(printf '%s' "$response" | sed -n 's/.*"ip"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        EXTERNAL_ASN_ORG=$(printf '%s' "$response" | sed -n 's/.*"asn_org"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        EXTERNAL_COUNTRY=$(printf '%s' "$response" | sed -n 's/.*"country"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        EXTERNAL_CITY=$(printf '%s' "$response" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
        if [ -n "$EXTERNAL_IP" ]; then
            printf '%s|%s|%s|%s\n' "$EXTERNAL_IP" "$EXTERNAL_ASN_ORG" "$EXTERNAL_COUNTRY" "$EXTERNAL_CITY"
            return 0
        fi
    fi

    for response in \
        "$(curl -4fsS --max-time 5 "https://ifconfig.me/ip" 2>/dev/null || true)" \
        "$(curl -4fsS --max-time 5 "https://api.ipify.org" 2>/dev/null || true)" \
        "$(curl -4fsS --max-time 5 "https://icanhazip.com" 2>/dev/null || true)"
    do
        EXTERNAL_IP=$(printf '%s' "$response" | tr -d '\r\n')
        if [ -n "$EXTERNAL_IP" ]; then
            printf '%s\n' "$EXTERNAL_IP"
            return 0
        fi
    done

    return 1
}

# Start OpenVPN in the background if config exists
if [ -f /etc/openvpn/pia.ovpn ]; then
    echo "[entrypoint] Starting OpenVPN..."

    # Generate credentials file from env vars if not already baked in
    if [ ! -f /etc/openvpn/credentials.txt ]; then
        if [ -n "$PIA_USER" ] && [ -n "$PIA_PASS" ]; then
            echo "[entrypoint] Creating credentials from PIA_USER/PIA_PASS env vars."
            printf '%s\n%s\n' "$PIA_USER" "$PIA_PASS" > /etc/openvpn/credentials.txt
            chmod 600 /etc/openvpn/credentials.txt
        else
            echo "[entrypoint] ERROR: No credentials found."
            echo "[entrypoint] Either bake credentials.txt or set PIA_USER and PIA_PASS env vars."
            exit 1
        fi
    fi

    # Resolve the VPN server IP before we lock down the firewall
    VPN_SERVER=$(grep -oP '(?<=^remote\s)[^\s]+' /etc/openvpn/pia.ovpn)
    VPN_PORT=$(grep -oP '(?<=^remote\s)[^\s]+\s+\K[0-9]+' /etc/openvpn/pia.ovpn)
    VPN_PROTO=$(grep -oP '(?<=^proto\s)\w+' /etc/openvpn/pia.ovpn)
    echo "[entrypoint] VPN server: $VPN_SERVER:$VPN_PORT ($VPN_PROTO)"

    # Start OpenVPN in the background
    openvpn --config /etc/openvpn/pia.ovpn \
            --auth-user-pass /etc/openvpn/credentials.txt \
            --log /var/log/openvpn.log \
            --daemon

    # Wait for the tun interface to come up (max 30 seconds)
    echo "[entrypoint] Waiting for VPN connection..."
    for i in $(seq 1 30); do
        if ip addr show tun0 > /dev/null 2>&1; then
            echo "[entrypoint] VPN connected! (tun0 is up)"
            VPN_IP=$(ip -4 addr show tun0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
            echo "[entrypoint] VPN IP: $VPN_IP"

            # Update DNS to PIA's DNS servers
            echo "[entrypoint] Updating DNS to PIA DNS servers..."
            printf 'nameserver 10.0.0.241\nnameserver 1.1.1.1\n' > /etc/resolv.conf

            if EXTERNAL_INFO=$(get_external_ip); then
                IFS='|' read -r EXTERNAL_IP EXTERNAL_ASN_ORG EXTERNAL_COUNTRY EXTERNAL_CITY <<EOF
$EXTERNAL_INFO
EOF
                echo "[entrypoint] VPN external IP: $EXTERNAL_IP"
                if [ -n "$EXTERNAL_ASN_ORG" ]; then
                    echo "[entrypoint] VPN external ASN org: $EXTERNAL_ASN_ORG"
                fi
                if [ -n "$EXTERNAL_COUNTRY" ] || [ -n "$EXTERNAL_CITY" ]; then
                    echo "[entrypoint] VPN external location: ${EXTERNAL_CITY:-unknown city}, ${EXTERNAL_COUNTRY:-unknown country}"
                fi
            else
                echo "[entrypoint] WARNING: Could not determine VPN external IP."
            fi

            break
        fi
        sleep 1
    done

    if ! ip addr show tun0 > /dev/null 2>&1; then
        echo "[entrypoint] WARNING: VPN did not connect within 30 seconds!"
        echo "[entrypoint] OpenVPN log:"
        cat /var/log/openvpn.log
        if [ "${VPN_REQUIRED:-true}" = "true" ]; then
            echo "[entrypoint] Exiting because VPN_REQUIRED=true (default)"
            exit 1
        fi
        echo "[entrypoint] Continuing without VPN because VPN_REQUIRED=false"
    fi

    # ── Kill switch: block all traffic that doesn't go through tun0 ──
    # This ensures that if VPN drops, there is ZERO network fallback to eth0.
    echo "[entrypoint] Setting up iptables kill switch..."

    # Allow loopback
    iptables -A INPUT  -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT

    # Allow traffic on the VPN tunnel
    iptables -A INPUT  -i tun0 -j ACCEPT
    iptables -A OUTPUT -o tun0 -j ACCEPT

    # Allow the OpenVPN connection itself to the server (over eth0)
    iptables -A OUTPUT -o eth0 -p "$VPN_PROTO" -d "$VPN_SERVER" --dport "$VPN_PORT" -j ACCEPT
    iptables -A INPUT  -i eth0 -p "$VPN_PROTO" -s "$VPN_SERVER" --sport "$VPN_PORT" -j ACCEPT

    # Allow Docker network / local access (so host can reach port 6878)
    DOCKER_NETWORK=$(ip -4 addr show eth0 | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+/\d+')
    iptables -A INPUT  -i eth0 -s "$DOCKER_NETWORK" -j ACCEPT
    iptables -A OUTPUT -o eth0 -d "$DOCKER_NETWORK" -j ACCEPT

    # Block everything else
    iptables -A INPUT   -j DROP
    iptables -A OUTPUT  -j DROP
    iptables -A FORWARD -j DROP

    echo "[entrypoint] Kill switch active. All non-VPN traffic is blocked."
else
    echo "[entrypoint] No VPN config found at /etc/openvpn/pia.ovpn, skipping VPN."
fi

# VPN watchdog: monitor the tunnel and kill ALL processes if it drops.
vpn_watchdog() {
    local check_interval="${VPN_CHECK_INTERVAL:-10}"
    echo "[watchdog] Monitoring VPN connection every ${check_interval}s..."
    while true; do
        sleep "$check_interval"
        if ! ip addr show tun0 > /dev/null 2>&1; then
            echo "[watchdog] VPN connection lost! (tun0 is down)"
            echo "[watchdog] Killing all processes to stop the container."
            kill -SIGTERM -- -1 2>/dev/null  # Kill all processes in the container
            sleep 2
            kill -SIGKILL -- -1 2>/dev/null  # Force kill if still alive
            exit 1
        fi
    done
}

# Start the watchdog if VPN is active
if ip addr show tun0 > /dev/null 2>&1; then
    vpn_watchdog &
fi

echo "[entrypoint] Starting AceStream engine..."
exec /opt/acestream/start-engine @/opt/acestream/acestream.conf
