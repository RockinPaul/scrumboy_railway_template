# Scrumboy on Railway

[Scrumboy](https://github.com/markrai/scrumboy) — self-hosted project management with customizable
boards, cross-project analytics, calendar-aware planning, a sticky-note wall and an MCP automation
layer — running on Railway with its SQLite database on a volume, behind an Owner account created
before the public port ever opens.

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/scrumboy)

## Service

| Service | Base | Public | Role |
|---|---|---|---|
| `scrumboy` | `ghcr.io/markrai/scrumboy:3.34.0` | **yes** | The whole app: boards, analytics, calendar, wall, REST API, MCP server. |

One service, one volume, no database container. Upstream ships a static cgo-free Go binary and
stores everything in SQLite, so the finished image is 44 MB and boots in about two seconds.

## Variables

| Variable | Default | Purpose |
|---|---|---|
| `SCRUMBOY_OWNER_PASSWORD` | generated, 24 chars | Password for the Owner account. Read it from the service variables after deploying. |
| `SCRUMBOY_OWNER_EMAIL` | `admin@example.com` | The Owner's sign-in address. Change it before deploying if you like; it is only an identifier. |
| `PORT` | `8080` | The port Railway's healthcheck probes and the domain targets. Leave it alone. |
| `SCRUMBOY_PUBLIC_BASE_URL` | your Railway domain | Canonical public origin, used for password-reset links and OAuth discovery. |
| `SCRUMBOY_TRUST_PROXY` | `1` | Baked. Railway's edge terminates TLS and is the only client path. |
| `SCRUMBOY_MODE` | `full` | Baked. Upstream's default, with authentication on. `anonymous` disables auth entirely. |
| `SCRUMBOY_ENCRYPTION_KEY` | generated on first boot | Not a form field. Written to `/data/encryption.key` and reused; see below. |

The deploy form asks for nothing you have to invent.

## First run

1. Copy `SCRUMBOY_OWNER_PASSWORD` from the service's **Variables** tab.
2. Open the public domain and sign in as **`admin@example.com`**.
3. Create a board.

The Owner account already exists when the deploy finishes. You are not racing anyone for it — see
below.

## Security

**The Owner account is the whole point of this wrapper.** Scrumboy's Owner is whoever calls
`/api/auth/bootstrap` first on an empty database, and upstream is explicit that there is no
supported path to promote anyone to Owner afterwards. Until that call lands, the API answers
anonymous requests — and not only reads. Measured on the stock image before bootstrap:

| Request | Before bootstrap | After bootstrap |
|---|---|---|
| `GET /api/projects` | **200** | 401 |
| `POST /api/projects` | **201** | 401 |
| `POST /api/auth/bootstrap` | 201 (claims the instance) | 409 |

On a public URL that is a land grab, so this template claims the account **before the public
listener exists**. The entrypoint starts Scrumboy bound to `127.0.0.1` on a setup port, posts the
bootstrap with the generated password, stops it, and only then starts the real server on `$PORT`.
A background job racing the real server would not do: Railway starts routing the moment the
healthcheck passes, which is the moment the server listens.

Proven rather than asserted. During rehearsal an attacker loop hammered the public port with
bootstrap attempts from the instant the container started. Across 400 attempts it saw 82
connection-refused and 318 `409 already bootstrapped` — and **not one 201**.

The rest, also measured:

- The container refuses to start without `SCRUMBOY_OWNER_PASSWORD`, or with one shorter than 12
  characters, so there is no path to an unclaimed instance.
- Sign-in returns **401** on a wrong password and **200** on the right one, setting an
  `HttpOnly; Secure; SameSite=Lax` session cookie.
- The password is passed to the bootstrap call on **stdin**, so it never enters the process table.
  It appears in neither `ps` output nor the logs.
- Upstream enforces its own password policy at bootstrap: a short value is rejected with
  `VALIDATION_ERROR: password too short` before any account is created.

## What persists

The volume at `/data` holds `app.db` (SQLite plus its WAL sidecars), uploaded wallpapers, and
`encryption.key`. Verified by replacing the container: a board created before the swap was still
there afterwards, the sign-in still worked, and the encryption key was unchanged.

**The encryption key** protects two-factor secrets, password-reset material and encrypted calendar
feed URLs. It must be base64 of exactly 32 bytes, which Railway's `${{secret()}}` cannot express, so
the entrypoint generates it on first boot and keeps it on the volume — the same thing upstream's own
launchers do. It belongs to the same backup unit as `app.db`: once encrypted data exists, a missing
or changed key stops the server from starting. Set `SCRUMBOY_ENCRYPTION_KEY` yourself only if you
are restoring a backup.

## Why it is shaped this way

- **Upstream's image, unmodified.** It is a static binary that already writes everything under
  `/data` and runs as root without a privilege drop, so there is no `HOME` or passwd trap to work
  around. The wrapper adds `curl` and `tini`, the environment, and the bootstrap.
- **`:PORT` with no relay.** Go binds dual-stack — measured, one socket in `tcp6` with no separate
  v4 listener, and both `127.0.0.1` and `[::1]` answer — so unlike the Python services in this
  portfolio, no `socat` is needed.
- **`PORT` is a real variable.** Railway's healthcheck probes the port named by `PORT`, so the
  entrypoint turns it into `BIND_ADDR`, which is what the server actually reads.
- **Healthcheck on `/healthz`.** Handled before any auth middleware and it genuinely pings the
  store, returning 503 when the database is unhappy rather than a static 200. It answers 200 with
  Railway's `Host: healthcheck.railway.app`.
- **`restartPolicyType: ALWAYS`.** A clean `SIGTERM` exits `0`, which `ON_FAILURE` would not
  restart.

## Optional configuration

Add these as service variables; none are required.

- **Email** (`SCRUMBOY_SMTP_HOST`, `SCRUMBOY_SMTP_FROM`, and friends) enables password-reset and
  notification mail. It needs `SCRUMBOY_PUBLIC_BASE_URL`, which this template already sets.
- **Single sign-on** needs all four of `SCRUMBOY_OIDC_ISSUER`, `SCRUMBOY_OIDC_CLIENT_ID`,
  `SCRUMBOY_OIDC_CLIENT_SECRET` and `SCRUMBOY_OIDC_REDIRECT_URL`.
- **Web push** needs a VAPID keypair.
- **Markdown and Mermaid notes** are off by default: `SCRUMBOY_MARKDOWN_NOTES_ENABLED=1`, then
  `SCRUMBOY_MERMAID_NOTES_ENABLED=1`.

Full list: [environment-variables.md](https://github.com/markrai/scrumboy/blob/main/docs/environment-variables.md).

## Break-glass

Upstream ships a `recover-owner` command that resets the Owner's password against a stopped
database. It reads the password from stdin and refuses it in `argv`. It needs the service stopped,
so on Railway it is a local operation against a downloaded volume backup rather than something you
run in place.

## Upgrading

Bump `SCRUMBOY_VERSION` in the `Dockerfile` and push. Upstream releases several times a week, so pin
deliberately rather than tracking `latest`. Image tags are semver **without** a `v` prefix.

## Licences

Scrumboy is [AGPL-3.0](https://github.com/markrai/scrumboy/blob/main/LICENSE). The glue in this
repository is MIT.
