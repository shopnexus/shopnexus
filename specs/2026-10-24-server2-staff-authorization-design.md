# Design: server2 staff accounts and authorization

Date: 2026-10-24.
Status: decided in conversation, question by question and section by section.
Code shape follows `~/shopnexus/server2/ARCHITECTURE.md`; the decisions below
go there under "Staff and authorization" when the work lands.

## Goal

Moderators and admins run the marketplace from a web console: they find a
customer account, suspend it or lift the suspension, and admins manage the
moderators and read what every staff member did. Before this, a suspension
could only be written in SQL.

Customers' own rights are out of scope. Who may edit a listing or act in a
deal is an ownership check in that module's use cases, and seller plans and
eKYC are features of their own modules.

## Decisions

| # | Question | Decision |
|---|---|---|
| 1 | Scope | Two staff roles, `moderator` and `admin`. An admin can do everything a moderator can. |
| 2 | Staff identity | Separate staff accounts with email and password, never a customer account with a role. SMS OTP does not open staff access. A moderator who forgets the password asks an admin to reset it. |
| 3 | Where staff work | A separate web console. This work builds the API, tokens and CORS; the console's frontend is a separate project. |
| 4 | Token transport | The refresh token lives in an `HttpOnly; Secure; SameSite=Strict` cookie; the access token lives in the console's memory. A staff session lasts at most 8 hours. |
| 5 | Revocation | Every staff request reads the staff member and the session from Postgres, so a role change, a disable or a sign-out applies to the next request. Disabling a member also revokes all their sessions. |
| 6 | First admin | A CLI with database access creates, disables and resets admins. The API manages moderators only and has no path to the admin role. |
| 7 | Second factor | TOTP is required for every staff member from the first sign-in. A lost device is reset by an admin (moderators) or the CLI (admins). There are no recovery codes. |
| 8 | Audit | Every staff write, and every sign-in event, is recorded in `staff_actions` in the same transaction as the change. |
| 9 | Business scope | Moderators search customer accounts, read one with its suspension history, suspend and unsuspend. Admins also read the audit log. |
| 10 | Shape | A new module `staff`. It shares the refresh-token helpers and the JWT signing key with auth and nothing else of the customer session. |

## API

Every path is under `/v1/staff`, in `api/paths/staff.yaml` with schemas in
`api/schemas/staff.yaml`. A new security scheme, `staffAuth`, is a Bearer JWT
with audience `shopnexus-staff`. Write actions are named by a verb segment,
and the verb matches the audit action name (`/suspend` writes
`account.suspend`).

### Sign-in

Sign-in takes up to four calls. The first returns a ticket, a JWT with
audience `shopnexus-staff-login` that lives 5 minutes and is accepted only by
the next sign-in calls. Each call returns `next`, which tells the console
what to show.

| Endpoint | Body | Response |
|---|---|---|
| `POST /v1/staff/login` | `email`, `password` | `LoginStep{ticket, next, ticket_expires_at}` |
| `POST /v1/staff/login/password` | `ticket`, `new_password` | `LoginStep`; for `next = change_password` |
| `POST /v1/staff/login/totp-enrollment` | `ticket` | `{secret, otpauth_uri}`; for `next = enroll_totp` |
| `POST /v1/staff/login/totp` | `ticket`, `code` | `StaffSignIn{access_token, access_token_expires_at, token_type, staff: Me}` and `Set-Cookie: staff_refresh` |

`next` is `change_password`, `enroll_totp` or `totp`. A first sign-in goes
through all three, and its first correct code confirms the enrollment.

### Session

| Endpoint | Auth | Response |
|---|---|---|
| `POST /v1/staff/session/refresh` | cookie `staff_refresh` and the required header `X-Requested-With: shopnexus-console` | `{access_token, access_token_expires_at, token_type}` and a new cookie |
| `POST /v1/staff/session/logout` | `staffAuth` | 204; the cookie is cleared |
| `GET /v1/staff/me` | `staffAuth` | `Me{id, email, display_name, role}` |
| `PUT /v1/staff/me/password` | `staffAuth` | body `current_password`, `new_password`; 204. The member's other sessions are revoked. |

The cookie is `staff_refresh=<token>; HttpOnly; Secure; SameSite=Strict;
Path=/v1/staff/session; Max-Age=<seconds left in the session>`.

### Moderator management (admin)

| Endpoint | Response |
|---|---|
| `GET /v1/staff/members` with `Cursor`, `Limit` | `Page[Member]` |
| `POST /v1/staff/members` `{email, display_name}` | 201 `{member, temporary_password}`; the role is always `moderator` |
| `POST /v1/staff/members/{id}/disable` | `Member`; revokes the member's sessions |
| `POST /v1/staff/members/{id}/enable` | `Member` |
| `POST /v1/staff/members/{id}/unlock` | `Member`; clears the sign-in lock on the member's email |
| `POST /v1/staff/members/{id}/reset-password` | `{temporary_password}`; revokes the member's sessions |
| `POST /v1/staff/members/{id}/reset-totp` | `Member`; revokes the member's sessions |

`Member` is `id, email, display_name, role, status, totp_enrolled,
locked_until (when locked), created_at`. Any call whose target is an admin
returns 403 `admin_managed_by_cli`.

### Customer accounts (moderator and admin)

| Endpoint | Response |
|---|---|
| `GET /v1/staff/accounts?q=` with `Cursor`, `Limit` | `Page[StaffAccount]`; `q` matches an account ID, a normalised phone number or an email exactly |
| `GET /v1/staff/accounts/{id}` | `StaffAccountDetail`: the account, its identities, and the 20 latest staff actions on it |
| `POST /v1/staff/accounts/{id}/suspend` `{reason, until (optional)}` | `StaffAccount` |
| `POST /v1/staff/accounts/{id}/unsuspend` | `StaffAccount` |

`StaffAccount` is `id, display_name, status, suspended_until,
suspend_reason, created_at`. `StaffAccountDetail` adds `identities: [{kind,
value}]` and `actions: [Action]`.

### Audit (admin)

`GET /v1/staff/actions?staff_id=&action=&target_id=&since=&until=` with
`Cursor`, `Limit` returns `Page[Action]`. An `Action` is `id, at,
actor{kind, staff_id, display_name}, ip, action, target{kind, id}, diff`;
`staff_id` and `display_name` are absent when the CLI acted.

### Errors

| Code | Status | When |
|---|---|---|
| `invalid_credentials` | 401 | an unknown email, a wrong password, or a disabled member, all alike |
| `login_locked` | 429 | five failed attempts on the email; `details.retry_after` in seconds |
| `invalid_login_ticket` | 401 | a ticket that is expired or malformed, carries an old credentials version, or is used for another step |
| `invalid_totp_code` | 401 | a wrong or reused code |
| `password_too_weak` | 422 | shorter than 12 characters, longer than 128, equal to the email, or equal to the current password |
| `staff_email_taken` | 409 | creating a member with an email in use |
| `staff_forbidden` | 403 | the member's role is below the route's |
| `admin_managed_by_cli` | 403 | the API was asked to act on an admin |

Refresh and the middleware reuse `invalid_refresh_token`, `session_revoked`,
`session_expired` and `invalid_token`. Failed attempts count toward the lock
whether the email exists or not, so `login_locked` reveals nothing either.

## Data

Migration `0003_staff.sql` creates four tables.

`staff_members`, aggregate `staff/member.Member`:

| Column | Notes |
|---|---|
| `id uuid PRIMARY KEY` | UUIDv7 |
| `email text NOT NULL` | unique on `lower(email)`; the sign-in name, never mailed |
| `display_name text NOT NULL` | shown in the audit log and the console |
| `role text NOT NULL` | `moderator` or `admin` |
| `status text NOT NULL` | `active` or `disabled` |
| `password_hash text NOT NULL` | argon2id in PHC string form |
| `must_change_password bool NOT NULL` | true after creation and after a reset |
| `credentials_version int NOT NULL` | raised by every password change, password reset and TOTP reset; a ticket carries the version it was issued at |
| `totp_secret bytea` | AES-256-GCM; NULL until enrolled |
| `totp_pending_secret bytea` | AES-256-GCM; the secret being enrolled, cleared on confirmation |
| `totp_last_step bigint NOT NULL DEFAULT 0` | the time step of the last accepted code |
| `created_at`, `updated_at`, `write_id` | as on every aggregate |

`staff_sessions`, aggregate `staff/session.Session`: `id`, `staff_id
REFERENCES staff_members`, `refresh_hash` (unique), `prev_refresh_hash`,
`ip inet`, `user_agent`, `created_at`, `last_used_at`, `expires_at`
(`created_at` plus 8 hours), `revoked_at`, `write_id`. There is no idle
limit.

`staff_login_quotas`: `key bytea PRIMARY KEY` (HMAC of the lower-cased
email, so the table is no list of addresses people typed), `failures int`,
`locked_until timestamptz`, `updated_at`, `write_id`. The planned data
cleanup job deletes rows untouched for a day.

`staff_actions`, written through `platform/audit`: `id uuid PRIMARY KEY`
(UUIDv7, also the page cursor), `actor_kind` (`staff` or `cli`), `staff_id`
(NULL for the CLI), `session_id`, `ip inet`, `action text`, `target_kind`,
`target_id uuid`, `diff jsonb`, `at`. Indexes on `(staff_id, id)`,
`(action, id)` and `(target_id, id)` serve the audit filters, and no code
updates or deletes a row.

## Sign-in flow

1. `POST /v1/staff/login` normalises the email, loads its quota row and
   refuses with `login_locked` while `locked_until` is ahead. It loads the
   member; when there is none it still verifies the password against a fixed
   dummy hash, so the response time does not reveal which emails exist. A
   wrong password, an unknown email or a disabled member counts a failure
   and returns `invalid_credentials`. The fifth failure sets `locked_until`
   to now plus 15 minutes and resets the count. A correct password resets
   the count and returns a ticket.
2. Every later call verifies the ticket (signature, audience, expiry),
   loads the member, and checks that the member is active and that the
   ticket's credentials version equals the member's. The step is computed
   from the member, never read from the ticket: `must_change_password`
   gives `change_password`, a NULL `totp_secret` gives `enroll_totp`, and
   anything else gives `totp`. A call for another step is refused with
   `invalid_login_ticket`.
3. `login/password` checks the policy, stores the new hash, clears
   `must_change_password`, raises `credentials_version`, and returns a
   ticket at the new version.
4. `login/totp-enrollment` stores a fresh 20-byte secret in
   `totp_pending_secret`, replacing one from an earlier call, and returns it
   with an `otpauth://` URI (issuer `shopnexus staff`, label the email).
5. `login/totp` checks the code against `totp_secret`, or against
   `totp_pending_secret` during enrollment, which it then moves to
   `totp_secret`. A wrong code counts a failure on the email's quota. A code
   whose time step is not above `totp_last_step` is refused. Success starts
   a session, records `staff.login` in the same transaction, sets the
   cookie, and returns the access token.

Passwords: argon2id with 64 MiB, 3 passes and 4 lanes; 12 to 128 characters;
not the email; no composition rules (NIST SP 800-63B). A temporary password
is 16 random characters, shown once in the response or the CLI output and
stored only as a hash.

TOTP follows RFC 6238 with HMAC-SHA1, 6 digits and 30-second steps, and
accepts one step on either side. It is written on the standard library and
tested against the RFC's vectors.

## Sessions and tokens

- Access tokens are EdDSA JWTs signed with the existing `JWT_PRIVATE_KEY`,
  audience `shopnexus-staff`, lifetime 5 minutes, carrying `sub` (staff ID)
  and `sid`. The role is never in a token. The customer verifier already
  checks the audience, so a staff token fails on the customer API and a
  customer token fails on the staff API.
- Refresh rotates the token on every call. Presenting the previous token
  revokes the session and records `staff.refresh_reuse`.
- The session package in auth exports `NewRefreshToken` and `HashRefresh`;
  staff uses them. The JWT signing in `auth/session` is split so it signs
  given claims (subject, session ID, audience, lifetime) for both modules.

## Authorization

`staff.Require(d, keys, role)` wraps each staff route in `staff/mount.go`.
It checks the Bearer token, then runs one query joining `staff_sessions`
and `staff_members` on the token's `sid` and `sub`: the session must be
unrevoked and unexpired, the member active, and the member's role at or
above `role` (`moderator` below `admin`). It returns 401 for a token,
session or member problem and 403 `staff_forbidden` for a low role. It puts
`authn.Staff{StaffID, SessionID, Role, IP}` in the context, which handlers
read with `httpx.StaffCaller`. `authn.Staff` is a different type from
`authn.Principal`, so neither kind of handler can receive the other kind of
caller.

Rules that depend on the target live in `Member`:
`target.ManageableBy(actor)` refuses an admin target unless the actor is the
CLI.

CORS applies to `/v1/staff/` only: the origin must equal
`STAFF_CONSOLE_ORIGIN`, credentials are allowed so the refresh cookie
travels, and the allowed headers are `Authorization`, `Content-Type` and
`X-Requested-With`; responses on the customer API carry no CORS headers.

## Module boundaries

Module `staff` owns the staff tables and the `/v1/staff` handlers. The
account screens need data from two modules, so staff declares two ports:

- `AccountPort` (`Get`, `Suspend`, `Unsuspend`), implemented by
  `account.Client`.
- `IdentityPort` (`FindAccount(q)`, `Identities(accountID)`), implemented by
  a new read-only `auth.Client`.

Neither account nor auth learns about staff HTTP. `auth.Mount` returns
`auth.Mounted{Services, Client}`, and `app.mountModules` becomes:

```go
protect := auth.Protect(d, cfg.Auth)
accounts := account.Mount(d, protect)
authm := auth.Mount(d, authSettings, accounts)
staff.Mount(d, staffSettings, accounts, authm.Client)
return authm.Services
```

## Audit

`platform/audit` holds `Entry{Actor, Action, Target, Diff, At}`,
`ByStaff(authn.Staff)`, `ByCLI(osUser)`, `Diff(before, after)` (the changed
keys of two JSON values), `Insert(ctx, tx, entry)` for adapters, and a
`Store` with `List(ctx, Filter, page.Request)`. It sits in platform because
the account store writes audit rows, and an account import of staff would
tie the two modules together.

A store that staff changes gets a method that writes the audit row in its
own transaction: `account.Store.SaveAudited(ctx, a, writeID, entry)`, the
member store's `CreateAudited` and `SaveAudited`, and the login quota's
`SaveAudited`. The customer flows keep `Save`. A `write_id` conflict rolls
back the change and the audit row together, and the client gets
`try_again`.

`Diff` takes view structs (`account.View`, the API's `Member`), never
entities, so a password hash or a TOTP secret cannot reach `staff_actions`.
A password reset is recorded as `{"password": "reset"}`.

Actions: `account.suspend`, `account.unsuspend`, `staff.create`,
`staff.disable`, `staff.enable`, `staff.unlock`, `staff.reset_password`,
`staff.reset_totp`, `staff.password_change`, `staff.totp_enroll`,
`staff.login`, `staff.login_failed`, `staff.login_locked`,
`staff.refresh_reuse`.

## CLI

`cmd/staff` runs the same use cases as the API with `audit.ByCLI($USER)`:

```
go run ./cmd/staff create-admin --email <email> --name <name>
go run ./cmd/staff disable --email <email>
go run ./cmd/staff enable --email <email>
go run ./cmd/staff reset-password --email <email>
go run ./cmd/staff reset-totp --email <email>
```

`create-admin` and `reset-password` print the temporary password. The CLI
reads `DATABASE_URL` and `STAFF_KEY` and stops with the name of a missing
one.

## Configuration

Both variables are required, as every variable is.

- `STAFF_KEY`: base64 of 32 bytes; `make run` generates it as it does
  `OTP_KEY`. HKDF (`crypto/hkdf`) derives two subkeys from it: the AES-GCM
  key for TOTP secrets and the HMAC key for login quota keys.
- `STAFF_CONSOLE_ORIGIN`: the console's origin, `http://localhost:5173` in
  development.

`.env.example` and `.env.test` gain both.

## Testing

| Level | Covers |
|---|---|
| Entities | the password policy; TOTP against RFC 6238 vectors, the step window and replay; the next-step rule; `ManageableBy`; the 5-failure, 15-minute lock |
| Stores on Postgres | a `SaveAudited` that conflicts leaves no audit row; `CreateAudited`; quota keys are HMACs |
| Use cases on Postgres | the three-step first sign-in; an unknown email locks exactly as a real one; a ticket stops working after a reset; an admin cannot act on an admin |
| Middleware | a disabled member's next request gets 401; a low role gets 403; a customer token fails on the staff API and a staff token on the customer API |
| E2E | sign-in, then refresh by cookie with `X-Requested-With`; a CORS preflight; a suspension that then appears in the audit log; the coverage check reaches every new operation |

## Order of work

1. The OpenAPI spec for every endpoint above.
2. `platform/audit` and migration `0003_staff.sql`.
3. `staff/member` and `staff/session` with their stores.
4. Sign-in: password, ticket, TOTP, lock.
5. `staff.Require` and `httpx.StaffCaller`.
6. Moderator management.
7. Customer account screens, with `AccountPort` and `IdentityPort`.
8. The audit log endpoint.
9. `cmd/staff`.
10. CORS and the e2e tests.

## Out of scope

The console frontend, passkeys, recovery codes, more roles or a permission
table, audit of staff reads, and the cleanup job for expired rows, which is
its own piece of core work.
