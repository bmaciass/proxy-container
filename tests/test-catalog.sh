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
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
sgd,rdbsgd.example.test,10.1.7.13,5433,15433,sgd,credentials,true
second,other.example.test,10.1.7.14,5432,15434,other,credentials,false
EOF
expect_success valid "$test_dir/valid.csv" 1

cat > "$test_dir/duplicate-port.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
one,one.example.test,10.0.0.1,5432,15433,one,credentials,true
two,two.example.test,10.0.0.2,5432,15433,two,credentials,true
EOF
expect_failure duplicate-port "$test_dir/duplicate-port.csv" 1

cat > "$test_dir/invalid-ip.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
one,one.example.test,10.0.999.1,5432,15433,one,credentials,true
EOF
expect_failure invalid-ip "$test_dir/invalid-ip.csv" 1

cat > "$test_dir/unsafe-value.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
$(id),one.example.test,10.0.0.1,5432,15433,one,credentials,true
EOF
expect_failure unsafe-value "$test_dir/unsafe-value.csv" 1

cat > "$test_dir/none-enabled.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
one,one.example.test,10.0.0.1,5432,15433,one,credentials,false
EOF
expect_failure require-enabled "$test_dir/none-enabled.csv" 1

cat > "$test_dir/unsafe-credentials-file.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
one,one.example.test,10.0.0.1,5432,15433,one,../credentials,true
EOF
expect_failure unsafe-credentials-file "$test_dir/unsafe-credentials-file.csv" 1

cat > "$test_dir/missing-disabled-credentials-file.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
one,one.example.test,10.0.0.1,5432,15433,one,credentials-that-does-not-exist,false
EOF
if output=$(VPN_PROXY_CATALOG="$test_dir/missing-disabled-credentials-file.csv" "$project_dir/vpn-proxy" validate 2>&1); then
    printf 'PASS missing-disabled-credentials-file\n'
    pass_count=$((pass_count + 1))
else
    printf 'FAIL missing-disabled-credentials-file (unexpected error: %s)\n' "$output" >&2
    exit 1
fi

cat > "$test_dir/missing-enabled-credentials-file.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
one,one.example.test,10.0.0.1,5432,15433,one,credentials-that-does-not-exist,true
EOF
if output=$(VPN_PROXY_CATALOG="$test_dir/missing-enabled-credentials-file.csv" "$project_dir/vpn-proxy" validate 2>&1); then
    printf 'FAIL missing-enabled-credentials-file (expected failure)\n' >&2
    exit 1
elif [[ "$output" != *"fatal: credentials file not found: $project_dir/secrets/credentials-that-does-not-exist"* ]]; then
    printf 'FAIL missing-enabled-credentials-file (unexpected error: %s)\n' "$output" >&2
    exit 1
else
    printf 'PASS missing-enabled-credentials-file\n'
    pass_count=$((pass_count + 1))
fi

launcher_dir="$test_dir/launcher"
mkdir -p "$launcher_dir/secrets"
cp "$project_dir/vpn-proxy" "$project_dir/catalog.awk" "$project_dir/web-catalog.awk" "$launcher_dir/"
cat > "$launcher_dir/destinations.csv" <<'EOF'
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
one,one.example.test,10.0.0.1,5432,15433,one,database_credentials,true
EOF
cat > "$launcher_dir/web-hosts.csv" <<'EOF'
name,hostname,remote_ip,local_ip,enabled
web,web.example.test,10.0.0.20,127.0.0.2,true
EOF
printf '%s\n' 'database-user,database-password' > "$launcher_dir/secrets/database_credentials"
printf '%s' 'vpn-user,vpn-password' > "$launcher_dir/secrets/vpn_credentials"
printf '%s\n' 'client' > "$launcher_dir/secrets/client.ovpn"
chmod 0600 "$launcher_dir/secrets/client.ovpn"

if output=$(
    VPN_CREDENTIALS_FILE=vpn_credentials bash -c '
        launcher=$1
        set -- help
        source "$launcher" >/dev/null
        check_docker() { :; }
        check_tun() { :; }
        docker() { printf "docker-arg:%s\n" "$@"; }
        start_proxy
    ' _ "$launcher_dir/vpn-proxy" <<< '123456' 2>&1
); then
    if [[ "$output" == *"Starting arkho-vpn-db-proxy"* \
        && "$output" == *"docker-arg:127.0.0.2:80:60000/tcp"* \
        && "$output" == *"docker-arg:127.0.0.2:443:60001/tcp"* \
        && "$output" == *"docker-arg:type=bind,src=$launcher_dir/web-hosts.csv,dst=/config/web-hosts.csv,readonly"* ]]; then
        printf 'PASS vpn-credentials-without-final-newline\n'
        pass_count=$((pass_count + 1))
    else
        printf 'FAIL vpn-credentials-without-final-newline (launcher did not start: %s)\n' "$output" >&2
        exit 1
    fi
else
    printf 'FAIL vpn-credentials-without-final-newline (unexpected error: %s)\n' "$output" >&2
    exit 1
fi

if output=$(
    VPN_CREDENTIALS_FILE=../vpn_credentials bash -c '
        launcher=$1
        set -- help
        source "$launcher" >/dev/null
        start_proxy
    ' _ "$launcher_dir/vpn-proxy" 2>&1
); then
    printf 'FAIL unsafe-vpn-credentials-filename (expected failure)\n' >&2
    exit 1
elif [[ "$output" == *"fatal: VPN_CREDENTIALS_FILE must be a filename within $launcher_dir/secrets"* ]]; then
    printf 'PASS unsafe-vpn-credentials-filename\n'
    pass_count=$((pass_count + 1))
else
    printf 'FAIL unsafe-vpn-credentials-filename (unexpected error: %s)\n' "$output" >&2
    exit 1
fi

printf 'All %s tests passed.\n' "$pass_count"
