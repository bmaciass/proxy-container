#!/usr/bin/env bash
set -Eeuo pipefail

readonly project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly validator="$project_dir/catalog.awk"
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/vpn-db-proxy-tests.XXXXXX")
trap 'rm -rf -- "$test_dir"' EXIT

pass_count=0

expect_success() {
    local name="$1" file="$2" require_enabled="${3:-0}"
    if awk -v mode=summary -v require_enabled="$require_enabled" -f "$validator" "$file" >/dev/null 2>&1; then
        printf 'PASS %s\n' "$name"
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL %s (expected success)\n' "$name" >&2
        exit 1
    fi
}

expect_failure() {
    local name="$1" file="$2" require_enabled="${3:-0}"
    if awk -v mode=summary -v require_enabled="$require_enabled" -f "$validator" "$file" >/dev/null 2>&1; then
        printf 'FAIL %s (expected failure)\n' "$name" >&2
        exit 1
    else
        printf 'PASS %s\n' "$name"
        pass_count=$((pass_count + 1))
    fi
}

cat > "$test_dir/valid.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,enabled
sgd,rdbsgd.example.test,10.1.7.13,5433,15433,sgd,true
second,other.example.test,10.1.7.14,5432,15434,other,false
EOF
expect_success valid "$test_dir/valid.csv" 1

cat > "$test_dir/duplicate-port.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,enabled
one,one.example.test,10.0.0.1,5432,15433,one,true
two,two.example.test,10.0.0.2,5432,15433,two,true
EOF
expect_failure duplicate-port "$test_dir/duplicate-port.csv" 1

cat > "$test_dir/invalid-ip.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,enabled
one,one.example.test,10.0.999.1,5432,15433,one,true
EOF
expect_failure invalid-ip "$test_dir/invalid-ip.csv" 1

cat > "$test_dir/unsafe-value.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,enabled
$(id),one.example.test,10.0.0.1,5432,15433,one,true
EOF
expect_failure unsafe-value "$test_dir/unsafe-value.csv" 1

cat > "$test_dir/none-enabled.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,enabled
one,one.example.test,10.0.0.1,5432,15433,one,false
EOF
expect_failure require-enabled "$test_dir/none-enabled.csv" 1

printf 'All %s catalog tests passed.\n' "$pass_count"

