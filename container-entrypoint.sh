#!/usr/bin/env bash
set -Eeuo pipefail

readonly profile=/vpn/client.ovpn
readonly auth_file=/run-auth/auth.txt
readonly catalog=/config/destinations.csv
readonly catalog_validator=/usr/local/lib/vpn-db-proxy/catalog.awk
readonly web_catalog=/config/web-hosts.csv
readonly web_catalog_validator=/usr/local/lib/vpn-db-proxy/web-catalog.awk
readonly runtime_profile=/run/client.ovpn
readonly openvpn_log=/run/openvpn.log
readonly openvpn_pid_file=/run/openvpn.pid
readonly proxy_pid_file=/run/proxy.pids

openvpn_pid=""
log_pid=""
declare -a proxy_pids=()

cleanup() {
    local pid
    trap - EXIT INT TERM

    for pid in "${proxy_pids[@]:-}"; do
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    done
    if [[ -n "$openvpn_pid" ]]; then
        kill "$openvpn_pid" 2>/dev/null || true
    fi
    if [[ -n "$log_pid" ]]; then
        kill "$log_pid" 2>/dev/null || true
    fi
    wait 2>/dev/null || true
}
trap cleanup EXIT INT TERM

[[ -c /dev/net/tun ]] || { echo "fatal: /dev/net/tun is unavailable" >&2; exit 1; }
[[ -r "$profile" ]] || { echo "fatal: VPN profile is not readable" >&2; exit 1; }
[[ -r "$auth_file" ]] || { echo "fatal: temporary VPN auth file is not readable" >&2; exit 1; }
[[ -r "$catalog" ]] || { echo "fatal: destinations catalog is not readable" >&2; exit 1; }
[[ -r "$web_catalog" ]] || { echo "fatal: web hosts catalog is not readable" >&2; exit 1; }

awk -v mode=summary -v require_enabled=1 -f "$catalog_validator" "$catalog"
reserved_ports=$(awk -v mode=records -v require_enabled=1 -f "$catalog_validator" "$catalog" | awk -F, '
    { printf "%s%s", separator, $5; separator = " " }
')
awk -v mode=summary -v require_enabled=0 -v reserved_ports="$reserved_ports" \
    -f "$web_catalog_validator" "$web_catalog"

# Replace the interactive directive in a runtime-only copy. The source profile,
# including its embedded client key, remains read-only.
awk -v auth="$auth_file" '
    /^[[:space:]]*auth-user-pass([[:space:]].*)?$/ { print "auth-user-pass " auth; next }
    { print }
' "$profile" > "$runtime_profile"
chmod 0600 "$runtime_profile"

: > "$openvpn_log"
tail -n +1 -F "$openvpn_log" &
log_pid=$!

echo "Starting isolated OpenVPN tunnel..."
openvpn \
    --config "$runtime_profile" \
    --data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC \
    --data-ciphers-fallback AES-256-CBC \
    --auth-nocache \
    --log-append "$openvpn_log" &
openvpn_pid=$!
printf '%s\n' "$openvpn_pid" > "$openvpn_pid_file"

deadline=$((SECONDS + 120))
while ! grep -q "Initialization Sequence Completed" "$openvpn_log"; do
    if ! kill -0 "$openvpn_pid" 2>/dev/null; then
        wait "$openvpn_pid" || true
        echo "fatal: OpenVPN exited before the tunnel became ready" >&2
        exit 1
    fi
    if grep -q "AUTH_FAILED" "$openvpn_log"; then
        echo "fatal: VPN authentication failed" >&2
        exit 1
    fi
    if (( SECONDS >= deadline )); then
        echo "fatal: timed out waiting for the VPN tunnel" >&2
        exit 1
    fi
    sleep 1
done

echo "VPN tunnel is ready. Starting database forwards:"
: > "$proxy_pid_file"
while IFS=, read -r name hostname remote_ip remote_port local_port database credentials_file enabled; do
    socat \
        "TCP-LISTEN:${local_port},fork,reuseaddr,keepalive" \
        "TCP:${remote_ip}:${remote_port},connect-timeout=10" &
    proxy_pid=$!
    proxy_pids+=("$proxy_pid")
    printf '%s\n' "$proxy_pid" >> "$proxy_pid_file"
    printf '  %-20s 127.0.0.1:%s -> %s:%s (host=%s db=%s)\n' \
        "$name" "$local_port" "$remote_ip" "$remote_port" "$hostname" "$database"
done < <(awk -v mode=records -v require_enabled=1 -f "$catalog_validator" "$catalog")

echo "Starting web host forwards:"
while IFS=, read -r name hostname remote_ip local_ip http_proxy_port https_proxy_port enabled; do
    socat \
        "TCP-LISTEN:${http_proxy_port},fork,reuseaddr,keepalive" \
        "TCP:${remote_ip}:80,connect-timeout=10" &
    proxy_pid=$!
    proxy_pids+=("$proxy_pid")
    printf '%s\n' "$proxy_pid" >> "$proxy_pid_file"

    socat \
        "TCP-LISTEN:${https_proxy_port},fork,reuseaddr,keepalive" \
        "TCP:${remote_ip}:443,connect-timeout=10" &
    proxy_pid=$!
    proxy_pids+=("$proxy_pid")
    printf '%s\n' "$proxy_pid" >> "$proxy_pid_file"

    printf '  %-20s %s:80/443 -> %s:80/443 (host=%s)\n' \
        "$name" "$local_ip" "$remote_ip" "$hostname"
done < <(awk -v mode=records -v require_enabled=0 -v reserved_ports="$reserved_ports" \
    -f "$web_catalog_validator" "$web_catalog")

echo "Proxy is running. Press Ctrl-C to disconnect."
while true; do
    if ! kill -0 "$openvpn_pid" 2>/dev/null; then
        echo "fatal: OpenVPN process stopped" >&2
        exit 1
    fi
    for proxy_pid in "${proxy_pids[@]}"; do
        if ! kill -0 "$proxy_pid" 2>/dev/null; then
            echo "fatal: a TCP forward stopped" >&2
            exit 1
        fi
    done
    sleep 2
done
