# VPN database and web proxy

This project runs the client VPN inside an isolated Docker network namespace.
It publishes selected database connections on `127.0.0.1` and can publish web
hosts on dedicated loopback addresses. The VPN may replace routes inside its
container, but it cannot replace the host's default route or edit host DNS
configuration. Web hostname entries are configured once, manually, in
`/etc/hosts`.

## Initial setup

Docker must be running, the current user must be able to run `docker info`, and
the host must provide `/dev/net/tun`.

```bash
cd /home/bmacias/work/arkho/sp/vpn-db-proxy
./vpn-proxy install-profile
```

`install-profile` copies the v2 profile from `~/Downloads` by default and saves
it with mode `0600`. A different source can be provided as its first argument.
The embedded private key is never copied into the image.

Edit `destinations.csv`, adding one row for every database:

```csv
name,hostname,remote_ip,remote_port,local_port,database,credentials_file,enabled
sgd,rdbsgd.spensiones.cl,10.1.7.13,REMOTE_PORT,15433,sgd,credentials,true
```

Replace `REMOTE_PORT` with the port supplied by the client. `remote_ip` is used
for the actual connection, so private DNS is not required. `hostname` and
`database` document what each listener is for. Every enabled row needs a unique
local port. `credentials_file` is a filename relative to `secrets/`; path
components are not allowed. It identifies that destination's database
credentials, so different destinations may name different files. CSV quoting,
spaces, and commas inside values are intentionally not supported.

Edit `web-hosts.csv` to expose private HTTP/HTTPS hosts with their original
names:

```csv
name,hostname,remote_ip,local_ip,enabled
papplara8,papplara8.spensiones.cl,10.1.1.219,127.0.0.2,true
qapplara8,qapplara8.spensiones.cl,10.2.4.219,127.0.0.3,true
```

Each enabled web host needs a unique address in `127/8`, excluding
`127.0.0.1`. The launcher publishes ports 80 and 443 on that address and sends
the raw TCP connections to the same ports on `remote_ip` through the VPN. This
preserves HTTP host headers, HTTPS SNI, and end-server TLS certificates. The
private `10.x` addresses are deliberately not written to the host's
`/etc/hosts`, because the host has no route into the container's VPN namespace.

Add the corresponding loopback mappings once with `sudoedit /etc/hosts`:

```text
127.0.0.2 papplara8.spensiones.cl
127.0.0.3 qapplara8.spensiones.cl
```

These entries can remain in place when the proxy is stopped; connections then
fail locally instead of leaking to another DNS result. The launcher never calls
`sudo` or modifies `/etc/hosts`.

Create the credentials file as one `username,password` record. For example:

```text
YOUR_DATABASE_USERNAME,YOUR_DATABASE_PASSWORD
```

Keep this file private. Catalog validation fails if an enabled destination's
credentials file is missing, unreadable, or malformed. Disabled destinations
do not require their credentials files to be present.

Store the VPN username and static password separately in
`secrets/vpn_credentials`, using the same one-record format:

```text
YOUR_VPN_USERNAME,YOUR_STATIC_VPN_PASSWORD
```

Validate and start:

```bash
./vpn-proxy validate
./vpn-proxy start
```

On start, the launcher validates both catalogs, reads the VPN username and
static password from
`secrets/vpn_credentials` and prompts only for the OTP. It sends the VPN
password immediately followed by the OTP, using a mode-`0600` temporary auth
file that is removed when Docker exits. Keep the command in the foreground and
press Ctrl-C to disconnect. Set `VPN_CREDENTIALS_FILE` to use a different
filename within `secrets/`; path components are not allowed.

The image is built automatically on first start. It can also be built explicitly
with `./vpn-proxy build`.

## Connecting

Use the row's localhost port while retaining that database's own name and the
username/password from its declared credentials file. For PostgreSQL, for
example:

```bash
IFS=, read -r PGUSER PGPASSWORD < secrets/credentials
export PGUSER PGPASSWORD
psql "host=127.0.0.1 port=15433 dbname=sgd"
unset PGUSER PGPASSWORD
```

The proxy validates the declared database credentials file but cannot apply the
credentials to a connection: it forwards raw TCP and database authentication is
performed by the calling client. If a client requires TLS hostname verification,
configure it with the original server name while directing its socket to the
corresponding localhost port, using the client's supported host/hostaddr
mechanism.

For the configured web hosts, use their original URLs while the proxy is
running:

```text
http://papplara8.spensiones.cl
https://papplara8.spensiones.cl
http://qapplara8.spensiones.cl
https://qapplara8.spensiones.cl
```

## Security properties

- Published ports bind only to IPv4 loopback.
- The container is not privileged and does not use host networking.
- All Linux capabilities are dropped except `NET_ADMIN` and `DAC_READ_SEARCH`;
  the latter lets container root read the mode-`0600`, host-owned bind mounts
  without weakening their host permissions. Only `/dev/net/tun` is passed
  through.
- The root filesystem is read-only; runtime state lives in small temporary
  filesystems.
- The profile, private catalogs, and secrets directory are excluded from the
  image build. The local profile and catalogs are ignored by Git.
- The host VPN credentials file is never mounted into the container. Its values
  are copied only into a temporary mode-`0600` auth file that is removed when
  Docker exits. Database credentials remain in the calling application or
  database client and are never mounted into the proxy container.

## Troubleshooting

- `Docker daemon is unavailable ...`: start Docker and configure access for the
  current user. The preflight fails after 10 seconds instead of waiting
  indefinitely, and the launcher never uses `sudo`.
- `/dev/net/tun ... unavailable`: load or enable the host TUN device before
  starting the proxy.
- `VPN authentication failed`: retry with a fresh OTP and verify that this VPN
  expects `password` followed immediately by `OTP`.
- A local port accepts connections but the database is unreachable: verify that
  the row has the client-provided remote IP and port and that the VPN grants a
  route to that subnet.
- A web host fails to publish: check for a host-wide service already listening
  on port 80 or 443. A listener bound to `0.0.0.0` conflicts with the dedicated
  loopback addresses too.
- A web URL resolves locally but is unreachable: verify that the remote server
  listens on port 80 or 443, that the VPN grants a route to its subnet, and that
  `/etc/hosts` maps it to the loopback address declared in `web-hosts.csv`.
