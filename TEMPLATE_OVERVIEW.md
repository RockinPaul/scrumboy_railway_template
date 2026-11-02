# Deploy and Host Scrumboy on Railway

[Scrumboy](https://github.com/markrai/scrumboy) is self-hosted project management: customizable
project boards, cross-project workload and flow analytics, calendar-aware planning, a sticky-note
wall, portable imports and backups, email notifications, and an MCP layer so coding agents can read
and update the same boards you do.

This template runs it on Railway with its database on a volume, behind an Owner account that is
created before the public port ever opens. One service, one volume, a public domain, and nothing to
fill in on the deploy form.

## About Hosting Scrumboy

Scrumboy is one static Go binary with SQLite underneath, so there is no database container, no
cache, and no second service. Everything it owns lives in one directory: the database and its
write-ahead log, uploaded wallpapers, and the encryption key. Putting a volume at `/data` is the
whole persistence story. The deployed image is about 44 MB and answers its first health check
roughly two seconds after the container starts.

The part this template takes seriously is the Owner account. Scrumboy's Owner is whoever creates the
first user on an empty instance, and upstream is explicit that nobody can be promoted to Owner
afterwards. Until that first account exists the API answers anonymous callers, including writes. On
a public URL that means the instance belongs to whoever finds it first. So the container creates the
Owner against a listener bound to loopback only, stops it, and then opens the public port — and it
refuses to start at all if no password was supplied to create that account with.

Everything else is optional and off by default. Email, single sign-on, web push, Markdown and
Mermaid notes each switch on when you add their variables, and the app runs perfectly well without
any of them.

## Why Deploy Scrumboy on Railway?

- **A team board that is not on someone's laptop.** Shared, always reachable, and backed by a
  volume rather than a browser.
- **One service, no assembly.** No Postgres, no Redis, no object store. SQLite on a volume.
- **Cheap to run.** A 44 MB image with a small idle footprint, not a multi-container stack.
- **Your agents can use it too.** The MCP layer exposes boards, todos and analytics as tools, so a
  coding agent can file and update work on the same board as the humans.
- **It survives redeploys.** Boards, users, uploads and the encryption key all live on the volume.

## Common Use Cases

- A small team's kanban or scrum board, self-hosted so the data stays yours.
- Cross-project workload and flow analytics over several boards at once.
- Sprint planning that understands calendars and time off.
- A shared sticky-note wall for retrospectives and loose ideas.
- Giving a coding agent a real project board to read and write through MCP.

## Dependencies for Scrumboy Hosting

- Nothing. No database, no cache, no object storage, no external accounts.
- Optional: an SMTP relay for password-reset and notification email, and an OIDC provider for single
  sign-on.

### Deployment Dependencies

- Upstream project: [markrai/scrumboy](https://github.com/markrai/scrumboy) (AGPL-3.0), image
  `ghcr.io/markrai/scrumboy:3.40.3`.
- Upstream documentation:
  [markrai/scrumboy docs](https://github.com/markrai/scrumboy/tree/main/docs).
- Template source:
  [RockinPaul/scrumboy_railway_template](https://github.com/RockinPaul/scrumboy_railway_template)
  (MIT).

### Implementation Details

**After deploying:** copy `SCRUMBOY_OWNER_PASSWORD` from the service's Variables tab, open the
public domain, and sign in as **`admin@example.com`**. Change the email before deploying if you
prefer a different one; it is only an identifier.

**How the Owner account is handled, and why.** Scrumboy hands ownership to the first caller of its
bootstrap endpoint on an empty database, and before that call lands the API serves anonymous reads
*and writes*. Measured on the stock image: `GET /api/projects` returns 200 and `POST /api/projects`
returns 201 before bootstrap, and both return 401 after. A template that simply started the server
would therefore publish an unclaimed instance and hope its owner arrived first.

So this template claims the account before the public listener exists. The entrypoint starts
Scrumboy bound to `127.0.0.1` on a setup port, posts the bootstrap with a per-deployment
`${{secret(24)}}`, stops that instance, and only then starts the real server on the public port. A
background task racing the real server would not be enough, because Railway begins routing the
moment the health check passes, which is the moment the server listens. The container exits rather
than start if the password is missing or shorter than 12 characters, so there is no path to an
unclaimed deployment.

This was proven rather than assumed. In rehearsal an attacker loop posted bootstrap attempts at the
public port from the instant the container started; across 400 attempts it saw only
connection-refused and `409 already bootstrapped`, and never a single success.

**Security.** The password is handed to the bootstrap call on standard input, so it never enters the
process table and appears in neither `ps` output nor the logs. Sign-in returns 401 on a wrong
password and sets an `HttpOnly; Secure; SameSite=Lax` cookie on the right one. Upstream enforces its
own password policy before creating any account.

**The encryption key.** It protects two-factor secrets, password-reset material and encrypted
calendar URLs, and must be base64 of exactly 32 bytes, which a generated secret cannot express. The
entrypoint creates it on first boot and keeps it on the volume, exactly as upstream's own launchers
do. Treat it as part of the same backup as the database: once encrypted data exists, a missing or
changed key stops the server from starting.

**Notes.** `PORT` is 8080 and the entrypoint turns it into the server's bind address; Railway's
health check probes that port and the domain targets it, so leave it as is. Health is `/healthz`,
which is handled before any authentication and genuinely checks the database. Upstream releases
several times a week, so `SCRUMBOY_VERSION` is pinned deliberately rather than tracking `latest`.

## Licences

Scrumboy is AGPL-3.0. The template's glue is MIT.
