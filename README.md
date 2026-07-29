# VPN database proxy

This project runs the client VPN inside an isolated Docker network namespace
and publishes selected database connections only on `127.0.0.1`. The VPN may
replace routes inside its container, but it cannot replace the host's default
route or DNS configuration.

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
name,hostname,remote_ip,remote_port,local_port,database,enabled
sgd,rdbsgd.spensiones.cl,10.1.7.13,REMOTE_PORT,15433,sgd,true
```

Replace `REMOTE_PORT` with the port supplied by the client. `remote_ip` is used
for the actual connection, so private DNS is not required. `hostname` and
`database` document what each listener is for. Every enabled row needs a unique
local port. CSV quoting, spaces, and commas inside values are intentionally not
supported.

Validate and start:

```bash
./vpn-proxy validate
./vpn-proxy start
```

On start, the launcher prompts for the VPN username, static password, and OTP.
It sends the password immediately followed by the OTP, using a mode-`0600`
temporary auth file that is removed when Docker exits. Keep the command in the
foreground and press Ctrl-C to disconnect.

The image is built automatically on first start. It can also be built explicitly
with `./vpn-proxy build`.

## Connecting

Use the row's localhost port while retaining that database's own name and
database credentials. For PostgreSQL, for example:

```bash
psql "host=127.0.0.1 port=15433 dbname=sgd user=YOUR_DB_USER"
```

The proxy never needs or stores database usernames and passwords. If a client
requires TLS hostname verification, configure the database client with its
original server name while directing its socket to the corresponding localhost
port, using the client's supported host/hostaddr mechanism.

## Security properties

- Published ports bind only to IPv4 loopback.
- The container is not privileged and does not use host networking.
- All Linux capabilities are dropped except `NET_ADMIN` and `DAC_READ_SEARCH`;
  the latter lets container root read the mode-`0600`, host-owned bind mounts
  without weakening their host permissions. Only `/dev/net/tun` is passed
  through.
- The root filesystem is read-only; runtime state lives in small temporary
  filesystems.
- The profile, destination catalog, and secrets directory are excluded from the
  image build. The local profile and catalog are ignored by Git.
- Database credentials remain in the calling application or database client.

## Troubleshooting

- `cannot access the Docker daemon`: start Docker and configure access for the
  current user. The launcher deliberately does not call `sudo`.
- `/dev/net/tun ... unavailable`: load or enable the host TUN device before
  starting the proxy.
- `VPN authentication failed`: retry with a fresh OTP and verify that this VPN
  expects `password` followed immediately by `OTP`.
- A local port accepts connections but the database is unreachable: verify that
  the row has the client-provided remote IP and port and that the VPN grants a
  route to that subnet.
