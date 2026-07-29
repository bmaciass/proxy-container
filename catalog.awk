BEGIN {
    FS = ","
    expected_header = "name,hostname,remote_ip,remote_port,local_port,database,enabled"
    header_seen = 0
    enabled_count = 0
    errors = 0
}

function fail(message) {
    print "catalog error at line " FNR ": " message > "/dev/stderr"
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

    if (NF != 7) {
        fail("expected exactly 7 comma-separated fields")
        next
    }

    name = $1
    hostname = $2
    remote_ip = $3
    remote_port = $4
    local_port = $5
    database = $6
    enabled = $7

    row_valid = 1

    if (name !~ /^[A-Za-z0-9][A-Za-z0-9_-]*$/) {
        fail("name must contain only letters, digits, underscores, and hyphens")
        row_valid = 0
    }
    if (hostname !~ /^[A-Za-z0-9][A-Za-z0-9.-]*$/) {
        fail("hostname contains unsupported characters")
        row_valid = 0
    }
    if (!valid_ipv4(remote_ip)) {
        fail("remote_ip must be a valid IPv4 address")
        row_valid = 0
    }
    if (remote_port !~ /^[0-9]+$/ || remote_port < 1 || remote_port > 65535) {
        fail("remote_port must be between 1 and 65535")
        row_valid = 0
    }
    if (local_port !~ /^[0-9]+$/ || local_port < 1024 || local_port > 65535) {
        fail("local_port must be between 1024 and 65535")
        row_valid = 0
    }
    if (database !~ /^[A-Za-z0-9][A-Za-z0-9_.-]*$/) {
        fail("database contains unsupported characters")
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

    if (enabled == "true") {
        if (local_port in seen_enabled_ports) {
            fail("duplicate enabled local_port: " local_port)
            row_valid = 0
        }
        seen_enabled_ports[local_port] = 1
        enabled_count++
    }

    if (row_valid && enabled == "true" && mode == "records") {
        print name "," hostname "," remote_ip "," remote_port "," local_port "," database "," enabled
    }
}

END {
    if (!header_seen) {
        print "catalog error: missing header" > "/dev/stderr"
        errors++
    }
    if (require_enabled == 1 && enabled_count == 0) {
        print "catalog error: at least one destination must be enabled" > "/dev/stderr"
        errors++
    }
    if (errors > 0) exit 1
    if (mode == "summary") {
        print "Catalog is valid (" enabled_count " enabled destination(s))."
    }
}

