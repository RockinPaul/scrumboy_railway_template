# Scrumboy — self-hosted project management in one static Go binary
# https://github.com/markrai/scrumboy
#
# Upstream's image is used as-is. It is a static, cgo-free binary on Alpine
# with SQLite under /data, it already binds dual-stack on `:8080`, and it needs
# no privilege drop because it runs as root and writes nothing outside the
# volume. The wrapper adds two things upstream cannot:
#
#   1. Railway's environment (PORT -> BIND_ADDR, trusted proxy, public origin).
#   2. An owner account created BEFORE the public listener exists.
#
# (2) is the whole reason this file has an entrypoint. Scrumboy's Owner is
# whoever calls /api/auth/bootstrap first on an empty database, and until that
# call lands the API answers anonymous reads *and writes*. On a public URL that
# is a land grab. See entrypoint.sh.
ARG SCRUMBOY_VERSION=3.34.0
FROM ghcr.io/markrai/scrumboy:${SCRUMBOY_VERSION}

# curl for the loopback bootstrap (it can read a body from stdin, so the
# password never enters the process table); tini to reap and to forward
# signals to the server.
RUN apk add --no-cache curl tini

# PORT is the port Railway's healthcheck probes and the public domain targets.
# The entrypoint turns it into BIND_ADDR, which is what the server reads.
#
# SCRUMBOY_TRUST_PROXY is on because Railway's edge terminates TLS and is the
# sole client path, so X-Forwarded-* can be believed for rate-limit IPs and
# OAuth discovery. SCRUMBOY_MODE stays `full` (upstream's default) so
# authentication is on; `anonymous` would disable it entirely.
ENV PORT=8080 \
    DATA_DIR=/data \
    SQLITE_PATH=/data/app.db \
    SCRUMBOY_MODE=full \
    SCRUMBOY_TRUST_PROXY=1 \
    SCRUMBOY_OWNER_EMAIL=admin@example.com \
    SCRUMBOY_OWNER_NAME=Owner \
    SCRUMBOY_BOOTSTRAP_PORT=9931

COPY --chmod=755 entrypoint.sh /usr/local/bin/railway-entrypoint

EXPOSE 8080

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/railway-entrypoint"]
