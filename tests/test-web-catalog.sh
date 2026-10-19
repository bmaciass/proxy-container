#!/usr/bin/env bash
set -Eeuo pipefail

readonly repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly web_validator_path="$repo_dir/web-catalog.awk"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/vpn-db-proxy-web-tests.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

pass_count=0

expect_success() {
    local name="$1" file="$2" reserved_ports="${3:-}"
    if awk -v mode=summary -v require_enabled=0 -v reserved_ports="$reserved_ports" \
        -f "$web_validator_path" "$file" >/dev/null 2>&1; then
        printf 'PASS %s\n' "$name"
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL %s (expected success)\n' "$name" >&2
        exit 1
    fi
}

expect_failure() {
    local name="$1" file="$2" reserved_ports="${3:-}"
    if awk -v mode=summary -v require_enabled=0 -v reserved_ports="$reserved_ports" \
        -f "$web_validator_path" "$file" >/dev/null 2>&1; then
        printf 'FAIL %s (expected failure)\n' "$name" >&2
        exit 1
    else
        printf 'PASS %s\n' "$name"
        pass_count=$((pass_count + 1))
    fi
}

cat > "$test_dir/valid.csv" <<'EOF'
name,hostname,remote_ip,local_ip,enabled
one,one.example.test,10.0.0.20,127.0.0.2,true
two,two.example.test,10.0.0.21,127.0.0.3,true
disabled,disabled.example.test,10.0.0.22,127.0.0.4,false
EOF
expect_success valid "$test_dir/valid.csv" "15433 15434"

records=$(awk -v mode=records -v require_enabled=0 -v reserved_ports="15433 15434" \
    -f "$web_validator_path" "$test_dir/valid.csv")
expected_records=$'one,one.example.test,10.0.0.20,127.0.0.2,60000,60001,true\ntwo,two.example.test,10.0.0.21,127.0.0.3,60002,60003,true'
if [[ "$records" == "$expected_records" ]]; then
    printf 'PASS derived-proxy-ports\n'
    pass_count=$((pass_count + 1))
else
    printf 'FAIL derived-proxy-ports (unexpected records: %s)\n' "$records" >&2
    exit 1
fi

cat > "$test_dir/invalid-remote.csv" <<'EOF'
name,hostname,remote_ip,local_ip,enabled
one,one.example.test,10.0.999.20,127.0.0.2,true
EOF
expect_failure invalid-remote "$test_dir/invalid-remote.csv"

cat > "$test_dir/non-loopback.csv" <<'EOF'
name,hostname,remote_ip,local_ip,enabled
one,one.example.test,10.0.0.20,192.168.1.2,true
EOF
expect_failure non-loopback "$test_dir/non-loopback.csv"

cat > "$test_dir/shared-localhost.csv" <<'EOF'
name,hostname,remote_ip,local_ip,enabled
one,one.example.test,10.0.0.20,127.0.0.1,true
EOF
expect_failure shared-localhost "$test_dir/shared-localhost.csv"

cat > "$test_dir/duplicate-hostname.csv" <<'EOF'
name,hostname,remote_ip,local_ip,enabled
one,App.example.test,10.0.0.20,127.0.0.2,true
two,app.example.test,10.0.0.21,127.0.0.3,true
EOF
expect_failure duplicate-hostname "$test_dir/duplicate-hostname.csv"

cat > "$test_dir/duplicate-local-ip.csv" <<'EOF'
name,hostname,remote_ip,local_ip,enabled
one,one.example.test,10.0.0.20,127.0.0.2,true
two,two.example.test,10.0.0.21,127.0.0.2,true
EOF
expect_failure duplicate-local-ip "$test_dir/duplicate-local-ip.csv"

cat > "$test_dir/no-enabled.csv" <<'EOF'
name,hostname,remote_ip,local_ip,enabled
one,one.example.test,10.0.0.20,127.0.0.2,false
EOF
expect_success no-enabled "$test_dir/no-enabled.csv"

expect_failure reserved-port-collision "$test_dir/valid.csv" "60000"

{
    printf '%s\n' 'name,hostname,remote_ip,local_ip,enabled'
    for ((i = 2; i <= 2770; i++)); do
        printf 'host%s,host%s.example.test,10.0.0.20,127.0.%s.%s,true\n' \
            "$i" "$i" "$((i / 256))" "$((i % 256))"
    done
} > "$test_dir/excessive.csv"
expect_failure excessive-enabled-hosts "$test_dir/excessive.csv"

printf 'All %s web catalog tests passed.\n' "$pass_count"
