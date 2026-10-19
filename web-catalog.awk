BEGIN {
    FS = ","
    expected_header = "name,hostname,remote_ip,local_ip,enabled"
    proxy_port_base = 60000
    header_seen = 0
    enabled_count = 0
    errors = 0

    reserved_count = split(reserved_ports, reserved_values, " ")
    for (i = 1; i <= reserved_count; i++) {
        if (reserved_values[i] != "") reserved[reserved_values[i]] = 1
    }
}

function fail(message) {
    print "web catalog error at line " FNR ": " message > "/dev/stderr"
    errors++
}

function valid_ipv4(value, parts, count, i) {
    count = split(value, parts, ".")
    if (count != 4) return 0
    for (i = 1; i <= 4; i++) {
        if (parts[i] !~ /^[0-9]+$/) return 0
        if ((parts[i] + 0) < 0 || (parts[i] + 0) > 255) return 0
        if (parts[i] != (parts[i] + 0) "" && parts[i] != "0") return 0
    }
    return 1
}

{
    sub(/\r$/, "")

    if ($0 ~ /^[[:space:]]*$/ || $0 ~ /^[[:space:]]*#/) next

    if (!header_seen) {
        if ($0 != expected_header) {
            fail("expected header: " expected_header)
        }
        header_seen = 1
        next
    }

    if (NF != 5) {
        fail("expected exactly 5 comma-separated fields")
        next
    }

    name = $1
    hostname = $2
    remote_ip = $3
    local_ip = $4
    enabled = $5
    normalized_hostname = tolower(hostname)
    row_valid = 1

    if (name !~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/) {
        fail("name must contain only letters, digits, underscores, and hyphens")
        row_valid = 0
    }
    if (hostname !~ /^[A-Za-z0-9][A-Za-z0-9.-]*$/ || hostname !~ /\./) {
        fail("hostname must be a fully qualified name containing only letters, digits, dots, and hyphens")
        row_valid = 0
    }
    if (!valid_ipv4(remote_ip)) {
        fail("remote_ip must be a valid IPv4 address")
        row_valid = 0
    }
    if (!valid_ipv4(local_ip) || local_ip !~ /^127\./ || local_ip == "127.0.0.1") {
        fail("local_ip must be a dedicated IPv4 loopback address in 127/8 other than 127.0.0.1")
        row_valid = 0
    }
    if (enabled != "true" && enabled != "false") {
        fail("enabled must be true or false")
        row_valid = 0
    }

    if (name in seen_names) {
        fail("duplicate name: " name)
        row_valid = 0
    }
    seen_names[name] = 1

    if (normalized_hostname in seen_hostnames) {
        fail("duplicate hostname: " hostname)
        row_valid = 0
    }
    seen_hostnames[normalized_hostname] = 1

    if (enabled == "true") {
        http_proxy_port = proxy_port_base + (enabled_count * 2)
        https_proxy_port = http_proxy_port + 1
        enabled_count++

        if (local_ip in seen_enabled_local_ips) {
            fail("duplicate enabled local_ip: " local_ip)
            row_valid = 0
        }
        seen_enabled_local_ips[local_ip] = 1

        if (https_proxy_port > 65535) {
            fail("too many enabled web hosts for the internal proxy port range")
            row_valid = 0
        }
        if (http_proxy_port in reserved || https_proxy_port in reserved) {
            fail("derived internal proxy port conflicts with an enabled database local_port")
            row_valid = 0
        }
    }

    if (row_valid && enabled == "true" && mode == "records") {
        print name "," hostname "," remote_ip "," local_ip "," http_proxy_port "," https_proxy_port "," enabled
    }
}

END {
    if (!header_seen) {
        print "web catalog error: missing header" > "/dev/stderr"
        errors++
    }
    if (require_enabled == 1 && enabled_count == 0) {
        print "web catalog error: at least one web host must be enabled" > "/dev/stderr"
        errors++
    }
    if (errors > 0) exit 1
    if (mode == "summary") {
        print "Web catalog is valid (" enabled_count " enabled host(s))."
    }
}
