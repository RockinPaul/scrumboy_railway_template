#!/bin/sh
set -eu

DATA_DIR="${DATA_DIR:-/data}"
LISTEN_PORT="${PORT:-8080}"
BOOT_PORT="${SCRUMBOY_BOOTSTRAP_PORT:-9931}"
OWNER_EMAIL="${SCRUMBOY_OWNER_EMAIL:-admin@example.com}"
OWNER_NAME="${SCRUMBOY_OWNER_NAME:-Owner}"

# ---------------------------------------------------------------------------
# Fail closed on a missing owner password
# ---------------------------------------------------------------------------
# Scrumboy's Owner is "the first user on an empty instance", and upstream is
# explicit that there is no supported path to promote anyone to Owner
# afterwards. Until that first user exists the API answers anonymous reads AND
# writes -- measured: GET /api/projects 200 and POST /api/projects 201 before
# bootstrap, both 401 after. So the owner account is not a convenience here, it
# is the only thing standing between a public URL and a stranger owning the
# instance. Refuse to start without a password to give it.
if [ -z "${SCRUMBOY_OWNER_PASSWORD:-}" ]; then
    echo "FATAL: SCRUMBOY_OWNER_PASSWORD is empty." >&2
    echo "  It is the password for the Owner account, which this container" >&2
    echo "  creates before opening the public port. Without it the first" >&2
    echo "  visitor to this URL would become the owner of this instance." >&2
    echo "  The template generates one; read it from the service variables." >&2
    exit 1
fi
if [ "$(printf '%s' "${SCRUMBOY_OWNER_PASSWORD}" | wc -c)" -lt 12 ]; then
    echo "FATAL: SCRUMBOY_OWNER_PASSWORD is shorter than 12 characters." >&2
    echo "  The sign-in endpoint is reachable from the public domain. The" >&2
    echo "  template generates a 24-character value." >&2
    exit 1
fi

mkdir -p "${DATA_DIR}"

# ---------------------------------------------------------------------------
# Encryption key, generated once and kept on the volume
# ---------------------------------------------------------------------------
# Protects TOTP secrets, password-reset material and encrypted calendar feed
# URLs. It must be base64 of exactly 32 bytes, which Railway's ${{secret()}}
# cannot express, and upstream's own launchers generate and persist it the same
# way. It belongs to the same backup unit as app.db: once encrypted data
# exists, a missing or changed key stops the server from starting.
KEY_FILE="${DATA_DIR}/encryption.key"
if [ -z "${SCRUMBOY_ENCRYPTION_KEY:-}" ]; then
    if [ ! -s "${KEY_FILE}" ]; then
        umask 077
        head -c 32 /dev/urandom | base64 > "${KEY_FILE}"
        echo "scrumboy: generated a new encryption key at ${KEY_FILE}"
    fi
    SCRUMBOY_ENCRYPTION_KEY="$(cat "${KEY_FILE}")"
    export SCRUMBOY_ENCRYPTION_KEY
fi

# ---------------------------------------------------------------------------
# Claim the Owner account before the public listener exists
# ---------------------------------------------------------------------------
# A background job racing the real server is not a security control: Railway
# starts routing the moment the healthcheck passes, which is the moment the
# server listens. So the account is claimed against a listener bound to
# loopback only -- unreachable from outside the container, verified -- and that
# instance is stopped before the public one starts.
#
# The call is idempotent by design: 201 means we just claimed it, 409
# "already bootstrapped" means a previous boot did. Anything else is a failure
# and the container exits rather than opening a port on an unclaimed instance.
bootstrap_owner() {
    BIND_ADDR="127.0.0.1:${BOOT_PORT}" /scrumboy &
    boot_pid=$!

    i=0
    while [ "$i" -lt 60 ]; do
        if curl -fsS -o /dev/null -m 2 "http://127.0.0.1:${BOOT_PORT}/healthz" 2>/dev/null; then
            break
        fi
        if ! kill -0 "$boot_pid" 2>/dev/null; then
            echo "FATAL: the setup instance exited before it became ready." >&2
            return 1
        fi
        i=$((i + 1))
        sleep 1
    done
    if [ "$i" -ge 60 ]; then
        echo "FATAL: the setup instance did not become ready within 60s." >&2
        kill -TERM "$boot_pid" 2>/dev/null || true
        return 1
    fi

    # The body goes in on stdin, so the password never appears in the process
    # table. jq is not in this image; the payload is small and the values are
    # controlled, so it is assembled with printf and the password is JSON-escaped
    # for backslashes and double quotes.
    esc_pw=$(printf '%s' "${SCRUMBOY_OWNER_PASSWORD}" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    code=$(printf '{"email":"%s","password":"%s","name":"%s"}' \
               "${OWNER_EMAIL}" "${esc_pw}" "${OWNER_NAME}" \
           | curl -s -o /tmp/bootstrap.out -w '%{http_code}' -m 20 \
                  -X POST "http://127.0.0.1:${BOOT_PORT}/api/auth/bootstrap" \
                  -H 'Content-Type: application/json' \
                  -H 'X-Scrumboy: 1' \
                  --data-binary @-)
    unset esc_pw

    kill -TERM "$boot_pid" 2>/dev/null || true
    wait "$boot_pid" 2>/dev/null || true

    case "$code" in
        201) echo "scrumboy: owner account created for ${OWNER_EMAIL}" ;;
        409) echo "scrumboy: owner account already exists, leaving it alone" ;;
        *)
            echo "FATAL: bootstrap returned HTTP ${code}." >&2
            sed -e 's/"password":"[^"]*"/"password":"<redacted>"/g' /tmp/bootstrap.out >&2 2>/dev/null || true
            echo >&2
            return 1
            ;;
    esac
    rm -f /tmp/bootstrap.out
    return 0
}

if ! bootstrap_owner; then
    echo "FATAL: refusing to open the public port on an unclaimed instance." >&2
    exit 1
fi

echo "scrumboy: data at ${DATA_DIR}, serving on :${LISTEN_PORT}"
echo "scrumboy: sign in as '${OWNER_EMAIL}' with SCRUMBOY_OWNER_PASSWORD from the service variables"

# `:PORT` is a dual-stack listener on Go's runtime -- measured, one socket in
# tcp6 with no separate v4 listener and both 127.0.0.1 and [::1] answering --
# which serves Railway's edge and the IPv6-only private network from one
# socket, with no relay in front.
export BIND_ADDR=":${LISTEN_PORT}"
exec /scrumboy "$@"
