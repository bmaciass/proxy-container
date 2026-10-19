# Local secrets

Run `../vpn-proxy install-profile` to install the v2 OpenVPN profile here with
mode `0600`. The profile and all other files in this directory are ignored by
Git and excluded from the Docker build context.

Database credential files referenced by `destinations.csv` contain exactly one
`username,password` record. A typical filename is `credentials`.

`vpn_credentials` uses the same format for the VPN username and static password.
The launcher reads it before prompting for the OTP. `VPN_CREDENTIALS_FILE` may
select a different filename in this directory; it does not accept a path.
