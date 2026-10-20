# Design: server2 foundation (stack, platform, observability, auth)

Date: 2026-10-19, rewritten 2026-10-20 after the redesign.
Status: decided in conversation, section by section. Code shape, transactions
and durability live in `~/shopnexus/server2/ARCHITECTURE.md`; this spec covers
scope, contracts, flows, security and testing, and points there for the rest.

## Goal

`~/shopnexus/server2` is a new Go backend that will replace `server`. This
first phase builds everything that has no business rules in it: the project
skeleton, the platform packages, observability, durable workflows, and
authentication with phone OTP, email OTP, password login and Google sign-in.
Listings, deals, orders and the other business modules come in later phases.

`server` is not reused as a whole. server2 takes the top-to-bottom use cases of
its `origin/microservice-ready` branch, and the hand-written SQL, idempotent
inserts and Restate workflows of its `origin/cleancode` branch. It drops fx,
the five-package hexagonal layout, sqlc and the parallel event buses.

## Working mode

The user decides the design, one question at a time, with a check question at
choices that touch security or data. Claude writes the spec, `ARCHITECTURE.md`
and the plans, then implements an approved plan without stopping to ask.
Decisions are recorded in the repository's markdown files.

## Scope

In this phase:

- repository, Go toolchain, Docker Compose stacks, Makefile
- platform packages: config, telemetry, postgres, httpx, apperr, authn, contact, pgtest
- providers: SMS and email senders that write to the log
- module `account`: profile, status, suspension
- module `auth`: credentials (identities and password), OTP challenges, quotas, sessions, Google
- Restate workflows for OTP send and sign-in
- OpenAPI spec for every endpoint, with conformance tests
- an observability exercise (an N+1 query and a missing index found through traces)

Later phases:

- business modules (listing, deal, order, chat, kyc, notification)
- a real SMS and email vendor
- events between modules (`restate.ServiceSend` to each listener)
- recovery of an account whose phone number a carrier gave to someone else
- Play Integrity checks on OTP requests
- CI, production deployment, the `server2` submodule in the umbrella repository

## Stack

| Concern | Choice |
|---|---|
| Language | Go 1.27.2, installed in `~/.local/opt/go` without root |
| Database | PostgreSQL 19 (release candidate until GA) |
| Durable workflows | Restate server 1.8.0, Go SDK `github.com/restatedev/sdk-go` v1.1.0 |
| API description | OpenAPI 3.2 |
| HTTP, JSON, logging, config, migrations | standard library |
| Postgres driver | `github.com/jackc/pgx/v5` |
| Request validation and conformance | `github.com/getkin/kin-openapi` |
| JWT | `github.com/golang-jwt/jwt/v5` |
| Google ID token verification | `github.com/coreos/go-oidc/v3` |
| Password hashing | `golang.org/x/crypto/argon2` |
| Traces, metrics, log export | OpenTelemetry Go SDK and the `otelslog` bridge |
| IDs | UUIDv7, chosen by the caller before insert |

SQL is written by hand in Go files. There is no sqlc, ORM, query builder or
code generation. Request shape is validated against the OpenAPI spec instead of `go-playground/validator`.

The user wants the newest release of every component. Development and test
run `postgres:19rc1` and move to `postgres:19` on its release (2026-11-19);
production runs a released major version only. Library versions are the newest
on the day they are added, pinned in `go.mod`.

## Repository layout

```
server2/
  ARCHITECTURE.md             architecture rules; overrides this spec on code shape
  CLAUDE.md                   working rules and commands
  api/
    openapi.yaml              root: info, servers, security, $refs
    paths/, schemas/, responses/
  cmd/
    server/main.go            HTTP API and Restate endpoint
    migrate/main.go           applies migrations
    keygen/main.go            prints fresh OTP and JWT keys
  migrations/                 one directory, numbered globally
  internal/
    app/                      wiring by hand
    platform/
      config/ telemetry/ postgres/ httpx/ apperr/ authn/ contact/ pgtest/
    provider/
      sms/ email/             Sender ports and log senders
    account/
    auth/
  e2e/                        boots the server in-process, calls it over HTTP
  docker-compose.yml
  docker-compose.test.yml
  Makefile
  .env.example
```

`server2` is its own git repository. It joins the umbrella repository as a
submodule after it runs.

## Architecture

`ARCHITECTURE.md` holds the rules for use cases, ports and adapters,
transactions and `write_id`, aggregates, Restate workflows, idempotency, the
module layout and testing; the module boundaries follow here.

`account` owns who a person is: display name, status, suspension. It knows
nothing about sign-in.

`auth` owns how a person proves it: credentials (identities and later the
password), OTP challenges and quotas, sessions, Google sign-in, and the rule
that an account keeps at least one identity.

`auth` calls `account` through ports that `auth` declares; `account` provides
an adapter that implements them. `account` never imports `auth`. Business
modules learn who is calling from `platform/authn`, which the auth middleware
fills, and never import `auth`. `platform` never imports a module.

## API contract

The API is OpenAPI first. `api/openapi.yaml` is written before the code, and
the code has to satisfy it. Four tests hold the code to the spec:

1. The spec loads and validates with kin-openapi, `$ref`s included.
2. Routes registered through `httpx` equal the operations in the spec, in both
   directions.
3. The E2E HTTP client validates every response (status, headers, body)
   against the operation it called.
4. Every status code an operation declares is observed in at least one E2E
   test.

The `mock` Compose profile runs Prism on the spec, so app2 can call a fake
server2 before the real one exists.

### Endpoints in this phase

| Operation | Purpose |
|---|---|
| `POST /v1/auth/otp` | send a code (purposes `login`, `add_identity`, `reset_password`) |
| `POST /v1/auth/otp/verify` | sign in or sign up with a code |
| `POST /v1/auth/password/login` | sign in with phone or email and password |
| `POST /v1/auth/password/reset` | set a new password with a reset code |
| `PUT /v1/auth/password` | set or change the password while signed in |
| `POST /v1/auth/google/nonce` | get a nonce for Google sign-in |
| `POST /v1/auth/google` | sign in with a Google ID token |
| `POST /v1/auth/refresh` | rotate the refresh token |
| `POST /v1/auth/logout` | revoke the current session |
| `POST /v1/auth/logout-all` | revoke every session of the account |
| `GET /v1/auth/sessions` | list signed-in devices |
| `DELETE /v1/auth/sessions/{id}` | sign one device out |
| `GET /v1/auth/identities` | list sign-in methods, masked |
| `POST /v1/auth/identities` | add a phone or email with a code |
| `POST /v1/auth/identities/google` | link Google |
| `DELETE /v1/auth/identities/{id}` | remove a sign-in method |
| `GET /v1/accounts/me` | read the caller's account |
| `PATCH /v1/accounts/me` | update the display name |
| `GET /healthz`, `GET /readyz` | liveness, readiness (Postgres and Restate) |

## HTTP layer

`http.ServeMux` with method and path patterns. Every API route starts with
`/v1`; a breaking change adds `/v2` beside it, because app installs stay on old
versions for months.

Middleware order from the outside in: trace span, recover, access log, request
validation, route, then the sign-in requirement on routes that need it.

An endpoint that starts a workflow requires an `Idempotency-Key` header (a
UUID). A request that repeats a key gets the first run's result instead of a second run.

### Request validation

A kin-openapi middleware validates each request against its operation before
the handler runs. Validation errors map to the shared error format with one
entry per field in `fields`. Shape rules live only in the spec; business rules
live in entities. The body is capped at 1 MB, unknown fields are rejected, and
JSON uses `snake_case`.

### Errors

```json
{
  "error": {
    "code": "invalid_code",
    "message": "the code does not match",
    "fields": { "code": "pattern" },
    "details": { "attempts_left": 3 },
    "trace_id": "4bf92f3577b34da6"
  }
}
```

`code` is stable and machine-readable; app2 maps it to Vietnamese text.
`message` is English for developers. `details` carries values a client acts
on, such as `attempts_left` and `retry_after`. Entities and use cases return
errors with a kind and a code; only `httpx` maps a kind to an HTTP status. An
unexpected error returns 500 with a generic message, and the real error goes
to the log with the same `trace_id`, so raw database errors, which name tables and constraints, never reach a client.

A resource the caller may not see returns 404, never 403. Every read or write
by ID checks ownership. An E2E test per resource checks that account B gets
404 for account A's resource.

### Pagination and server lifecycle

Lists use a cursor: `?cursor=...&limit=20` returns `{items, next_cursor}`.
UUIDv7 sorts by creation time, so `id` is the cursor.

The server sets read-header 5 s, read 15 s, write 30 s and idle 60 s timeouts.
On SIGTERM it stops accepting requests and waits up to 15 s for the ones in
flight.

## Configuration

Configuration comes from environment variables, read once at start into a
struct in `platform/config`. Missing or invalid variables stop the process,
and the message lists all of them at once. In development a `.env` file (git
ignored) fills variables the environment does not set; `.env.example` lists
every variable. `make keys` appends fresh `OTP_KEY`, `JWT_KEY_ID` and
`JWT_PRIVATE_KEY` to `.env`. Business code never calls `os.Getenv`.

Variables beyond the basics: `TRUSTED_PROXIES` (CIDRs whose
`X-Forwarded-For` is believed), `JWT_ISSUER`, `JWT_AUDIENCE`,
`JWT_PREVIOUS_KEY_ID` and `JWT_PREVIOUS_PUBLIC_KEY` (during a key change),
`RESTATE_INGRESS_URL`, `RESTATE_ADMIN_URL`, `RESTATE_LISTEN_ADDR`,
`RESTATE_ENDPOINT_URL`.

## Database and migrations

PostgreSQL 19. Primary keys are UUIDv7. The caller chooses the ID before the
insert (`restate.UUID(ctx)` in a workflow, `uuid.NewV7()` elsewhere), and
`uuidv7()` stays as the column default. UUIDs keep data merges free of key
collisions and do not reveal row counts; they do not replace ownership checks.

Migrations are plain SQL files in `migrations/`, embedded and run by a small
runner in `platform/postgres`: a `schema_migrations` table, an advisory lock so
two processes never migrate at once, one transaction per file, and a SHA-256
checksum that stops the run when an applied file changed. Migrations only go
up. The server does not migrate; `make migrate` does, and the server refuses to
start while migrations are pending. The redesign squashes the plan 1
migrations once, before anything is deployed.

## Observability

Development runs one `grafana/otel-lgtm` container under the `obs` Compose
profile.

Logs: `slog` writes text in development and JSON in production. A wrapping
handler adds `trace_id` and `span_id`, and logs are also exported over OTLP.
Passwords, OTP codes, tokens and refresh tokens are never logged. Phones and
emails are logged through `contact.Address`, which masks them
(`+8490****567`). The development SMS and email senders are the one exception.

Traces: OTLP/HTTP. An HTTP middleware opens a span named by the route pattern;
a pgx `QueryTracer` opens a span per query. Restate exports its own spans for
invocations and journal steps to the same collector. Development samples
every request.

Metrics, labelled by route pattern and never by raw path:

- HTTP request count and duration by `route`, `method`, `status`
- pgx pool: acquired, idle, total, acquire wait time
- auth: `otp_sent_total`, `login_total{method,result}`, `refresh_reuse_total`, `dormant_phone_login_total`

## Auth data model

```
accounts (module account)
  id, display_name, status, suspended_until, suspend_reason
  write_id, created_at, updated_at

credentials (module auth, aggregate root)
  account_id        uuid PK REFERENCES accounts
  password_hash     text NULL          -- PHC string, argon2id
  write_id, updated_at

identities (module auth, children of credentials)
  id                uuid PK
  account_id        uuid NOT NULL REFERENCES credentials
  kind              text NOT NULL      -- phone | email | google
  value             text NOT NULL      -- E.164 phone, lower-case email, Google sub
  last_used_at, created_at
  UNIQUE (kind, value)

sessions (module auth)
  id                uuid PK            -- the sid claim
  account_id        uuid NOT NULL REFERENCES accounts
  refresh_hash      bytea NOT NULL UNIQUE
  prev_refresh_hash bytea NULL
  device_name       text NULL
  auth_time         timestamptz NOT NULL  -- refresh copies it into each access token
  created_at, last_used_at, expires_at, revoked_at
  write_id

otp_challenges (module auth)
  id                uuid PK
  purpose           text NOT NULL      -- login | add_identity | reset_password
  kind, destination                    -- normalised
  account_id        uuid NULL          -- set for add_identity
  code_hash         bytea NOT NULL     -- HMAC-SHA256(OTP_KEY, kind:destination:code)
  attempts          int NOT NULL DEFAULT 0
  ip                inet NOT NULL
  expires_at, created_at, consumed_at
  write_id

otp_quotas (module auth)
  key               text PK            -- "dest:+84901234567", "ip:1.2.3.4"
  sent_at           timestamptz[]      -- sends inside the longest window
  write_id

auth_throttle (module auth, plan 3)
  key, window_start, count             -- failed password attempts
```

Every identity row is verified; a value waiting for verification is an OTP
challenge. Values are normalised by `platform/contact` before every insert and
lookup. Foreign keys go from `auth` tables to `accounts` and never the other
way.

### Hashing

| Value | Possibilities | Stored as |
|---|---|---|
| refresh token, 32 random bytes | 2^256 | SHA-256 |
| OTP, 6 digits | 10^6 | HMAC-SHA256 with `OTP_KEY` from config |
| password, chosen by a person | small in practice | argon2id |

A leaked database with SHA-256 OTP hashes gives up every pending code in under
a second; the HMAC key is not in the database. A test in the `otp` package hashes all 10^6 codes and logs how long it took.

## Tokens

### Access token

JWT signed with EdDSA (Ed25519). Verification accepts only EdDSA, which closes
`alg: none` and algorithm-swap attacks. The header carries `kid`; config holds
the current key and the previous one, so a key change signs nobody out.

Claims: `iss`, `aud`, `sub` (account ID), `sid` (session ID), `auth_time`,
`iat`, `exp` (15 minutes). Clock skew allowance is 30 s. No phone, email or
name goes into the token.

The middleware checks signature and expiry and puts
`Principal{AccountID, SessionID, AuthTime}` in the context without a database
read. There is no revocation list. A suspended person keeps read access until
the access token expires; write use cases load the account and call
`a.CanWrite(now)`.

Tokens never pass through Restate, whose journal and outputs are readable
through its admin API. A workflow returns IDs; the HTTP handler issues tokens.

### Refresh token

32 random bytes, base64url, prefix `rt_`, stored as SHA-256. Sessions expire
60 days after creation or 30 days after last use.

`POST /v1/auth/refresh`:

1. Find the session by the token's hash. When a session has it only as its
   previous hash, the token was replayed: revoke that session, return
   `session_revoked`, log a security event and raise `refresh_reuse_total`.
   When nothing matches, return `invalid_refresh_token`.
2. Reject revoked and expired sessions.
3. Read the account status. A suspended account gets its session revoked and
   `account_suspended`.
4. Rotate and `Save`. A conflict means a concurrent refresh with the same
   token won; treat it as a replay.
5. Return a new access token and refresh token.

### Logout and devices

`POST /v1/auth/logout` revokes the session in `sid`; the access token stays
valid for at most 15 minutes. `POST /v1/auth/logout-all` revokes every
session. `GET /v1/auth/sessions` lists devices, and
`DELETE /v1/auth/sessions/{id}` signs one out.

### Recent sign-in

Removing an identity, setting the first password and `logout-all` require
`auth_time` within the last 15 minutes. Otherwise they return
`reauth_required` (428) and the app asks for an OTP or the password again.

## Auth flows

No flow reveals whether an account exists to someone who has not proved
ownership of the phone, email or Google account in question.

### OTP send

`POST /v1/auth/otp` with `{kind, destination, purpose}` runs workflow
`OTPSend` (see `ARCHITECTURE.md`):

1. Normalise the destination; phones must be `+84` in this phase.
2. Admit the request against quotas `dest:<destination>` and `ip:<address>`:
   one code per destination per 45 s, five per destination per hour, twenty
   per client address per hour. The client address comes from
   `X-Forwarded-For` only behind a proxy listed in `TRUSTED_PROXIES`.
3. Generate six digits with `crypto/rand`, store the challenge with its HMAC,
   expiring in 5 minutes.
4. Send the SMS or email, unless the challenge has expired by then.
5. Return `{challenge_id, resend_after: 45}` whether or not an account exists.

### OTP sign-in and sign-up

`POST /v1/auth/otp/verify` with `{challenge_id, code, device_name}` runs
workflow `SignIn`:

1. Load the challenge; it must be the newest for its destination and purpose.
   `c.Verify(code, now)` and `Save`. A wrong code is saved and returns
   `invalid_code` with `attempts_left`; expiry, replacement or reuse returns
   `code_expired`; five wrong codes return `code_locked`. A write conflict
   returns the same reply whether the guess was right or wrong.
2. Find the identity.
   - It exists: check the account status (`account_suspended` is safe to
     return now), apply the dormant check, mark the identity used.
   - It does not exist: create the `Account`, then the `Credentials` with the
     identity, compensating by deleting the account if the second step fails.
3. The handler issues a session and returns tokens and
   `{account: {id, is_new}}`. `is_new` sends app2 to "Hoàn thiện hồ sơ".

### Dormant phone accounts

Carriers reassign numbers that sit unused. An OTP sign-in by phone to an
account whose phone identity was last used more than 6 months ago:

- When the account has another identity or a password, the verify step
  returns `step_up_required` with the other methods masked in `details`.
- When the phone is the only method, sign-in proceeds in this phase, logs a
  security event and raises `dormant_phone_login_total`. This is an accepted
  risk until the later phase that asks "is this your account?".

### Password

argon2id with OWASP's minimum parameters (19 MiB, 2 iterations, 1 thread),
stored as a PHC string in `credentials.password_hash`. A sign-in that matches
with older parameters rehashes. A semaphore allows 8 hashes at once.

Passwords are 8 to 128 characters, follow no composition rules, and must not
appear in the embedded list of the 10,000 most common passwords.

`POST /v1/auth/password/login` with `{identifier, password, device_name}`:
detect phone or email, find the credentials, hash a dummy value when either the
identity or the password is missing so the response time matches a wrong
password, check the status after the password matches, then issue a session.

Throttling uses `auth_throttle`: five failures per identifier in 15 minutes
start an increasing wait, with a wider limit per IP. Accounts are never locked, because a lock lets anyone shut a victim out by typing wrong passwords.

Reset: `POST /v1/auth/otp` with `purpose: "reset_password"` returns the same
reply whether or not an account exists and sends nothing when none does.
`POST /v1/auth/password/reset` verifies the code, sets the password, revokes
every session and issues a new one. `PUT /v1/auth/password` changes the
password with the current one, or sets a first password under the recent
sign-in rule; both revoke the other sessions.

### Google

1. `POST /v1/auth/google/nonce` returns `HMAC(NONCE_KEY, expiry || random)`,
   valid 5 minutes, stored nowhere.
2. `POST /v1/auth/google` with `{id_token, nonce, device_name}`. go-oidc checks
   signature, `iss`, `aud` and `exp`; the use case checks the nonce.
3. Identity `(google, sub)` exists: use its account. Otherwise, when
   `email_verified` is true and identity `(email, email)` exists, link Google
   to that account. Otherwise create an account with the Google identity, plus
   an email identity when Google verified the address and nobody holds it.
4. Issue a session.

Linking only to existing, verified identities stops the pre-account takeover.
Two parallel first sign-ins hit `UNIQUE (kind, value)`; the losing workflow
compensates and retries once.

### Identities

`GET /v1/auth/identities` lists methods masked, plus whether a password is
set. `POST /v1/auth/identities` adds a phone or email after an `add_identity`
code; a value held by another account returns `identity_taken`.
`POST /v1/auth/identities/google` links Google with the same checks as
sign-in. `DELETE /v1/auth/identities/{id}` refuses to remove the last
identity; the `Credentials` aggregate holds that rule.

## Requirements on app2

- Refresh as a single flight: the first 401 starts a refresh, other requests
  wait and retry with the new token. Parallel refreshes with one token look like
  a replay and revoke the session.
- Refresh when the access token has less than a minute left.
- Store the refresh token in EncryptedDataStore with a Keystore key.
- Send an `Idempotency-Key` (a new UUID per user action, reused on retry) to
  `POST /v1/auth/otp` and `POST /v1/auth/otp/verify`.
- Map error `code` values to Vietnamese text; send `device_name` at sign-in.

## Testing

| Layer | What | Runs with |
|---|---|---|
| unit | entities, use cases | fakes |
| contract | each port's suite | the fake and the Postgres adapter |
| workflow | Restate workflows, including a commit-then-fail retry per workflow | Restate and Postgres from the test stack |
| E2E | package `e2e/`, the whole server in-process | Restate and Postgres from the test stack, fake senders |

No build tags. `pgtest.New(t)` skips under `-short` and fails when
`TEST_DATABASE_URL` is unset; it clones a migrated template database per test
and refuses any DSN outside the test stack.

Named attack tests: pre-account takeover, 50 parallel OTP guesses, 1,000
parallel OTP sends from one address, refresh token replay, parallel refresh, a
Google token with another `aud`, identical OTP-send replies for known and
unknown destinations, account B reading account A's sessions.

Google verification is tested against an `httptest.Server` that serves a
generated JWKS. Tests that cost money run only with `SMOKE_SMS=1`.

`make test-unit` runs the short suite with `-race`, `make test-int` the
integration tests, `make test-e2e` the E2E suite, `make test` all three.

## Development environment

The server runs on the host with `go run ./cmd/server`, and Docker runs the services below.

| Service | Image | Profile | Ports (dev / test) |
|---|---|---|---|
| postgres | `postgres:19rc1` | none | 56432 / 56433 |
| restate | `restatedev/restate:1.8.0` | none | ingress 56580 / 56581, admin 56570 / 56571 |
| otel-lgtm | `grafana/otel-lgtm` | `obs` | Grafana 56300, OTLP 56317, 56318 |
| prism | `stoplight/prism:5.15.10` with `-m false` | `mock` | 56400 |

The test stack is a separate Compose project, so `down -v` on one never
touches the other. Its Postgres keeps data on a 1 GB tmpfs and every service
has a `mem_limit`. Restate reaches the host's endpoint through
`host.docker.internal`.

## Build order

| Step | Work | Status |
|---|---|---|
| 0 to 6 | toolchain, config, telemetry, Postgres, OpenAPI and HTTP layer, `account`, jobs | done in plan 1 |
| 7 | redesign: remove jobs and NATS, add Restate, squash migrations, `write_id`, rewrite `account` | plan 2 |
| 8 | `auth`: contact, OTP send and sign-in workflows, quotas, sessions, refresh, logout, devices, `/v1/accounts/me` | plan 2 |
| 9 | `auth`: passwords, throttling, reset, change | plan 3 |
| 10 | `auth`: Google, identities, dormant check | plan 3 |
| 11 | observability exercise | plan 3 |

## Decision record

| Question | Decision | Reason given |
|---|---|---|
| Who writes the code | Claude, after the user approves the design and plan | the user decides; AI makes refactoring cheap |
| Libraries | standard library first; pgx, go-oidc, kin-openapi, jwt, argon2, OTel, Restate SDK | Go needs few libraries |
| SQL | hand-written | easier to control performance with AI help |
| Use case shape | a plain function taking ports and parameters | reads top to bottom like `microservice-ready` |
| Transactions | inside adapters, one per aggregate; nothing in business code | a transaction is a database concept |
| Concurrency | optimistic, one `write_id` column per aggregate | detects conflicts and makes retries idempotent with one key |
| Aggregates | `Account`, `Credentials`, `Session`, `Challenge`, `Quota` | rules that must hold at commit share an aggregate |
| Durability | Restate workflows for OTP send and sign-in; plain calls elsewhere | durable sagas without hand-written outbox, relay and broker |
| Workflow IDs | client `Idempotency-Key` | a retried tap must not run twice |
| Tokens and Restate | tokens never enter the journal | the journal is readable through the admin API |
| Sessions | JWT access 15 min plus refresh tokens in Postgres, no revocation list | write use cases check status; reads may lag 15 min |
| IDs | UUIDv7 chosen by the caller | idempotent inserts under retry; bigint keys collided during past migrations |
| SMS vendor | log sender now, vendor later | |
| Google linking | automatic, to verified identities, when `email_verified` | |
| Dormant phone accounts | step-up when another method exists; the single-method case later | |
| API | OpenAPI first, validated at runtime by kin-openapi | the spec is the single source of request shape |
| Versions | the newest release of every component | the user's standing preference |
| Observability | slog, OTel, otel-lgtm | traces check the hand-written SQL |
