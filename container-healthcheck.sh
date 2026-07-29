#!/bin/sh
set -eu

openvpn_pid=$(cat /run/openvpn.pid 2>/dev/null) || exit 1
kill -0 "$openvpn_pid" 2>/dev/null || exit 1

test -s /run/proxy.pids || exit 1
while IFS= read -r proxy_pid; do
    kill -0 "$proxy_pid" 2>/dev/null || exit 1
done < /run/proxy.pids

