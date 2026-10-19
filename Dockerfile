FROM alpine:3.22

RUN apk add --no-cache \
      bash \
      ca-certificates \
      iproute2 \
      openvpn \
      socat \
    && mkdir -p /config /run-auth /vpn

COPY catalog.awk /usr/local/lib/vpn-db-proxy/catalog.awk
COPY web-catalog.awk /usr/local/lib/vpn-db-proxy/web-catalog.awk
COPY container-entrypoint.sh /usr/local/bin/container-entrypoint
COPY container-healthcheck.sh /usr/local/bin/container-healthcheck

RUN chmod 0755 \
      /usr/local/bin/container-entrypoint \
      /usr/local/bin/container-healthcheck

HEALTHCHECK --interval=10s --timeout=3s --start-period=30s --retries=3 \
  CMD ["/usr/local/bin/container-healthcheck"]

ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
