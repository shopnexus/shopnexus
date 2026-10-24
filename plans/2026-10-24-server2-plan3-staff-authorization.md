# server2 Plan 3: staff accounts and authorization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Moderators and admins sign in to a web console with email, password and TOTP on staff accounts separate from customers; moderators search, read, suspend and unsuspend customer accounts; admins manage moderators and read the audit log of every staff write.

**Architecture:** A new module `internal/staff` with three aggregates (`member`, `quota`, `session`), use cases and handlers in the module root, and `staff.Mount`. Every staff request reads its session and member from Postgres (`staff.Require`). Every staff write and sign-in event is written to `staff_actions` by `platform/audit` inside the adapter transaction of the change. JWT signing moves from `auth/session` to `platform/token` so both modules share one EdDSA key with different audiences.

**Tech Stack:** Go 1.27.2, PostgreSQL 19 RC 1, pgx v5.11.0, `github.com/golang-jwt/jwt/v5` v5.3.1, `golang.org/x/crypto` v0.58.0 (argon2 only), kin-openapi v0.151.0. TOTP, HKDF and AES-GCM come from the standard library.

**Spec:** `~/shopnexus/specs/2026-10-24-server2-staff-authorization-design.md` (umbrella c926c42) and `~/shopnexus/server2/ARCHITECTURE.md`. Builds on server2 `main` at 15e2f5b.

## Scope

| Task | Delivers |
|---|---|
| 1 | The OpenAPI design of every staff endpoint, not yet wired |
| 2 | `platform/token`: EdDSA signing and refresh tokens shared by auth and staff |
| 3 | `STAFF_KEY` and `STAFF_CONSOLE_ORIGIN` in config, keygen and the Makefile |
| 4 | Migration `0003_staff.sql` and `platform/audit` |
| 5 | `account.Record`, `Store.List`, `Store.SaveAudited`, audited `Suspend` and `Reinstate` |
| 6 | `staff/member`: the entity, argon2id, TOTP, the store with sealed secrets |
| 7 | `staff/quota`: the sign-in lock per email |
| 8 | `staff/session`: staff sessions and the grant query |
| 9 | Sign-in endpoints, `staff.Mount`, app wiring, e2e |
| 10 | `staff.Require`, refresh, logout, me, password change, e2e |
| 11 | Moderator management, e2e |
| 12 | Customer account screens through `AccountPort` and `IdentityPort`, e2e |
| 13 | The audit log endpoint, e2e |
| 14 | `cmd/staff` |
| 15 | CORS, `ARCHITECTURE.md`, a run by hand |

## Global Constraints

- Module path `github.com/shopnexus/server2`; repository `~/shopnexus/server2`. Scratch files go in `tmp/`.
- SQL by hand in Go with `pgx.StrictNamedArgs`; no sqlc, ORM or query builder.
- A use case is one plain function that takes ports and parameters and reads top to bottom. Business code takes no function arguments; no closures except to `pgx.BeginFunc` inside adapters.
- One transaction per adapter method, covering one aggregate plus its audit row. `Save(ctx, *agg, writeID)` fails with the package's `ErrConflict` when the row's `write_id` is neither the one read nor `writeID`. A use case maps `ErrConflict` to `apperr.ErrTryAgain`.
- IDs are stdlib `uuid.UUID` from `uuid.NewV7()`, chosen before the insert.
- Configuration has no defaults anywhere; a missing variable stops the process with its name.
- The OpenAPI spec is the contract. Every operation in `api/openapi.yaml` has a route (`TestRoutesMatchSpec`) and every numeric status it declares is observed by an e2e test (`uncovered()` in `e2e/main_test.go`). A task wires its operations into `api/openapi.yaml` together with their routes and e2e tests.
- Audiences: `shopnexus-staff` for staff access tokens, `shopnexus-staff-login` for login tickets. Access token 5 minutes, ticket 5 minutes, session 8 hours absolute.
- Cookie: `staff_refresh=<token>; HttpOnly; Secure; SameSite=Strict; Path=/v1/staff/session; Max-Age=<seconds left>`. Refresh requires `X-Requested-With: shopnexus-console`.
- Lock: 5 failures on one email (password or TOTP, known email or not) lock it for 15 minutes.
- argon2id `m=65536, t=3, p=4` in production, 16-byte salt, 32-byte key, PHC string. TOTP: HMAC-SHA1, 6 digits, 30 s, one step either side, no reuse of a step.
- Passwords, temporary passwords, TOTP secrets and codes, tickets and tokens never reach a log line or `staff_actions.diff`.
- Comments, docs and commit messages go through `python3 ~/.claude/skills/humanizing-writing/ai-tells.py` with 0 hits. Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Decisions this plan makes beyond the spec

| Decision | Why | Cost if wrong |
|---|---|---|
| JWT signing and refresh-token helpers move to `platform/token`, and `auth/session` wraps them | staff importing `auth/session` would reach into another module's internals; the staff verifier also needs the previous key during a key change | none |
| A disable also raises `credentials_version`, and `staff_sessions` stores the version it was issued at | `staff.Require` and refresh compare versions, so a reset or a disable ends every session without writing the sessions table, and re-enabling a member does not revive old sessions | a column |
| Only a completed sign-in clears the failure count; a correct password does not | otherwise a holder of the password gets five fresh TOTP guesses after every correct password | none |
| `staff_actions.actor_kind` also takes `anonymous`, `target_id` may be NULL, and `actor_name` holds the CLI's OS user | a failed sign-in has no signed-in actor and, for an unknown email, no target; the CLI has no staff row | a column |
| `GET /v1/staff/accounts` without `q` lists every account newest first | a list that always held at most one row would not need a page | none |
| `StaffAccountDetail` nests `account`, `identities` and `actions` | three plain properties validate simply; `allOf` with `additionalProperties: false` does not | API shape, decided in Task 1 |
| The password hasher is part of `staff.Keys`, and `app.WithPasswordHasher` swaps it in tests | 64 MiB argon2 under `-race` makes the suite slow; the PHC string carries its parameters, so any hash verifies | none |
| `cmd/staff` loads the full config | it runs on a host whose environment is complete, and one loader keeps the no-defaults rule in one place | none |
| `.env.test` gains nothing | tests build `config.Config` in code | none |
| `httpx.Bind` gains a `cookie` source | the refresh handler binds its cookie like any other request value | none |
| `account.Record` is the moderator's view of an account | `account.View` lacks the suspension fields an audit diff must show | none |
| An unknown member id answers 404 `staff_member_not_found` | the spec's member operations declare 404 without naming a code | a code |

## Review Focus

- Two wrong passwords for one email at the same moment: both count and neither is lost to a `write_id` conflict. Task 9, `TestLoginCountsConcurrentFailures`.
- `" Admin@Example.COM "` signs in as `admin@example.com` and locks the same quota row. Task 9, `TestLoginNormalisesTheEmail`.
- A TOTP code accepted once is refused the second time inside its window, and a code two steps old is refused. Task 6, `TestAcceptCode`.
- A member disabled while holding a fresh access token and a refresh cookie: the next request and the next refresh get 401, and enabling the member again does not revive either. Task 10, `TestRequireEndsWithDisable` and `TestRefreshAfterDisable`.
- A moderator calling an admin endpoint, and an admin acting on another admin, get 403. Task 11, `TestStaffMemberOpsForbidden`.

## How each task runs

Each task ends with `make test` green (all packages plus `golangci-lint run ./...` at 0 issues) and one commit. Run `make test` once first; after that the test stack stays up and `go test ./internal/<pkg>/` runs one package. Fix lint by changing code, not by adding exclusions, unless the task says so.

## File map

```
api/
  openapi.yaml                      + staffAuth scheme; staff paths as each task lands
  parameters/common.yaml            + StaffCSRF, StaffRefreshCookie, StaffMemberID, StaffAccountID
  responses/common.yaml             + StaffForbidden
  paths/staff.yaml                  new: every staff operation
  schemas/staff.yaml                new: every staff schema
migrations/0003_staff.sql           new: staff_members, staff_sessions, staff_login_quotas, staff_actions
internal/platform/
  token/token.go, token_test.go     new: Signer, Verifier, Claims, NewRefresh, HashRefresh
  audit/audit.go                    new: Actor, Target, Entry, ByStaff, ByCLI, Anonymous, Diff, Insert
  audit/store.go, store_pg_test.go  new: Filter, Action, Store, NewPGStore
  authn/authn.go                    + Staff, WithStaff, StaffFrom
  httpx/caller.go                   + StaffCaller
  httpx/bind.go                     + cookie source
  httpx/cors.go, cors_test.go       new: CORS
  config/config.go, keys.go         + StaffConfig, NewStaffKey
internal/auth/session/              token.go wraps platform/token; session.go uses token.NewRefresh
internal/auth/client.go             new: Client (FindAccount, Identities), Identity
internal/auth/mount.go              Mount returns Mounted{Services, Client}
internal/account/
  account_record.go                 new: Record, recordOf, Records
  account_suspend.go                new: Suspend, Reinstate (audited)
  account_store.go, _pg.go          + List, SaveAudited
  client.go                         + Record, Records, Suspend, Reinstate
internal/staff/
  member/member.go                  Member, Role, Status, Step, rules
  member/password.go                Hasher, VerifyPassword, CheckPolicy, TemporaryPassword
  member/totp.go                    NewTOTPSecret, EncodeSecret, TOTPURI, Code, matchCode
  member/errors.go, store.go, store_pg.go
  quota/quota.go, store.go, store_pg.go
  session/session.go, store.go, store_pg.go
  keys.go                           Keys, NewKeys, audiences, TicketTTL
  errors.go                         ErrLoginLocked, ErrInvalidLoginTicket, ErrStaffForbidden
  views.go                          Me, MemberView, LoginStep, SignIn, Access
  ticket.go                         issueTicket, readTicket
  cookie.go                         setRefreshCookie, clearRefreshCookie
  login.go                          Login, fail, LoginHandler
  login_password.go                 ChangeTemporaryPassword, its handler
  login_totp.go                     EnrollTOTP, VerifyTOTP, their handlers
  member_create.go                  CreateMember, its handler
  require.go                        Require
  session_refresh.go                Refresh, revoke, its handler
  session_logout.go                 Logout, its handler
  me.go                             GetMe, ChangePassword, their handlers
  member_list.go, member_disable.go, member_unlock.go, member_reset.go
  ports.go                          AccountPort, IdentityPort
  account_list.go, account_get.go, account_suspend.go
  action_list.go
  mount.go                          Settings, Mount
internal/app/app.go                 staff keys, WithPasswordHasher, CORS, mountModules
cmd/staff/main.go                   new: the CLI
e2e/staff_helpers_test.go, staff_*_test.go
```

---

### Task 1: The staff API in OpenAPI

The design comes first (`CLAUDE.md`). This task writes every staff operation and schema. `api/openapi.yaml` gains only the security scheme; each later task adds its paths there with its routes and e2e tests, so `TestRoutesMatchSpec` and the coverage check stay green.

**Files:**
- Create: `api/paths/staff.yaml`, `api/schemas/staff.yaml`
- Modify: `api/parameters/common.yaml`, `api/responses/common.yaml`, `api/openapi.yaml`

**Interfaces:**
- Produces: path items `login`, `loginPassword`, `loginTotpEnrollment`, `loginTotp`, `sessionRefresh`, `sessionLogout`, `me`, `mePassword`, `members`, `memberDisable`, `memberEnable`, `memberUnlock`, `memberResetPassword`, `memberResetTotp`, `accounts`, `account`, `accountSuspend`, `accountUnsuspend`, `actions` in `paths/staff.yaml`. Operation IDs and declared statuses below are what Tasks 9 to 13 observe.

- [ ] **Step 1: Add the shared parameters**

Append to `api/parameters/common.yaml`:

```yaml
StaffCSRF:
  name: X-Requested-With
  in: header
  required: true
  description: Must be shopnexus-console. A form on another site cannot set it, which stops a cross-site refresh.
  schema:
    type: string
    enum: [shopnexus-console]
StaffRefreshCookie:
  name: staff_refresh
  in: cookie
  required: true
  schema:
    type: string
    minLength: 1
StaffMemberID:
  name: id
  in: path
  required: true
  schema:
    type: string
    format: uuid
StaffAccountID:
  name: id
  in: path
  required: true
  schema:
    type: string
    format: uuid
```

- [ ] **Step 2: Add the staff 403 response**

Append to `api/responses/common.yaml`:

```yaml
StaffForbidden:
  description: "The caller's role is too low (staff_forbidden), or the target is an admin (admin_managed_by_cli)."
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
```

- [ ] **Step 3: Write the schemas**

Create `api/schemas/staff.yaml`:

```yaml
LoginRequest:
  type: object
  additionalProperties: false
  required: [email, password]
  properties:
    email:
      type: string
      format: email
      maxLength: 254
    password:
      type: string
      minLength: 1
      maxLength: 1024
LoginStep:
  type: object
  additionalProperties: false
  required: [ticket, next, ticket_expires_at]
  properties:
    ticket:
      type: string
      description: Pass it to the next sign-in call within five minutes.
    next:
      type: string
      enum: [change_password, enroll_totp, totp]
    ticket_expires_at:
      type: string
      format: date-time
LoginPasswordRequest:
  type: object
  additionalProperties: false
  required: [ticket, new_password]
  properties:
    ticket:
      type: string
      minLength: 1
    new_password:
      type: string
      minLength: 1
      maxLength: 1024
      description: 12 to 128 characters, not the email and not the current password.
TicketRequest:
  type: object
  additionalProperties: false
  required: [ticket]
  properties:
    ticket:
      type: string
      minLength: 1
TOTPEnrollment:
  type: object
  additionalProperties: false
  required: [secret, otpauth_uri]
  properties:
    secret:
      type: string
      description: Base32, for typing into an authenticator by hand.
    otpauth_uri:
      type: string
      description: For a QR code.
LoginTOTPRequest:
  type: object
  additionalProperties: false
  required: [ticket, code]
  properties:
    ticket:
      type: string
      minLength: 1
    code:
      type: string
      pattern: "^[0-9]{6}$"
Me:
  type: object
  additionalProperties: false
  required: [id, email, display_name, role]
  properties:
    id:
      type: string
      format: uuid
    email:
      type: string
    display_name:
      type: string
    role:
      type: string
      enum: [moderator, admin]
StaffSignIn:
  type: object
  additionalProperties: false
  required: [access_token, access_token_expires_at, token_type, staff]
  properties:
    access_token:
      type: string
    access_token_expires_at:
      type: string
      format: date-time
    token_type:
      type: string
      enum: [Bearer]
    staff:
      $ref: "#/Me"
StaffAccess:
  type: object
  additionalProperties: false
  required: [access_token, access_token_expires_at, token_type]
  properties:
    access_token:
      type: string
    access_token_expires_at:
      type: string
      format: date-time
    token_type:
      type: string
      enum: [Bearer]
ChangePasswordRequest:
  type: object
  additionalProperties: false
  required: [current_password, new_password]
  properties:
    current_password:
      type: string
      minLength: 1
      maxLength: 1024
    new_password:
      type: string
      minLength: 1
      maxLength: 1024
Member:
  type: object
  additionalProperties: false
  required: [id, email, display_name, role, status, totp_enrolled, created_at]
  properties:
    id:
      type: string
      format: uuid
    email:
      type: string
    display_name:
      type: string
    role:
      type: string
      enum: [moderator, admin]
    status:
      type: string
      enum: [active, disabled]
    totp_enrolled:
      type: boolean
    locked_until:
      type: string
      format: date-time
      description: Present while failed sign-ins lock the member's email.
    created_at:
      type: string
      format: date-time
MemberList:
  type: object
  additionalProperties: false
  required: [items]
  properties:
    items:
      type: array
      items:
        $ref: "#/Member"
    next_cursor:
      type: string
      format: uuid
CreateMemberRequest:
  type: object
  additionalProperties: false
  required: [email, display_name]
  properties:
    email:
      type: string
      format: email
      maxLength: 254
    display_name:
      type: string
      minLength: 1
      maxLength: 100
CreatedMember:
  type: object
  additionalProperties: false
  required: [member, temporary_password]
  properties:
    member:
      $ref: "#/Member"
    temporary_password:
      type: string
      description: Shown once; the member must replace it at the first sign-in.
TemporaryPassword:
  type: object
  additionalProperties: false
  required: [temporary_password]
  properties:
    temporary_password:
      type: string
StaffAccount:
  type: object
  additionalProperties: false
  required: [id, display_name, status, created_at]
  properties:
    id:
      type: string
      format: uuid
    display_name:
      type: string
    status:
      type: string
      enum: [active, suspended]
    suspended_until:
      type: string
      format: date-time
    suspend_reason:
      type: string
    created_at:
      type: string
      format: date-time
StaffAccountList:
  type: object
  additionalProperties: false
  required: [items]
  properties:
    items:
      type: array
      items:
        $ref: "#/StaffAccount"
    next_cursor:
      type: string
      format: uuid
Identity:
  type: object
  additionalProperties: false
  required: [kind, value]
  properties:
    kind:
      type: string
      enum: [phone, email, google]
    value:
      type: string
StaffAccountDetail:
  type: object
  additionalProperties: false
  required: [account, identities, actions]
  properties:
    account:
      $ref: "#/StaffAccount"
    identities:
      type: array
      items:
        $ref: "#/Identity"
    actions:
      type: array
      description: The 20 latest staff actions on the account, newest first.
      items:
        $ref: "#/Action"
SuspendRequest:
  type: object
  additionalProperties: false
  required: [reason]
  properties:
    reason:
      type: string
      minLength: 1
      maxLength: 500
    until:
      type: string
      format: date-time
      description: Absent for a suspension without an end.
Action:
  type: object
  additionalProperties: false
  required: [id, at, actor, action, diff]
  properties:
    id:
      type: string
      format: uuid
    at:
      type: string
      format: date-time
    actor:
      type: object
      additionalProperties: false
      required: [kind]
      properties:
        kind:
          type: string
          enum: [staff, cli, anonymous]
        staff_id:
          type: string
          format: uuid
        display_name:
          type: string
          description: The staff member's name, or the OS user for the CLI.
    ip:
      type: string
    action:
      type: string
    target:
      type: object
      additionalProperties: false
      required: [kind, id]
      properties:
        kind:
          type: string
          enum: [account, staff]
        id:
          type: string
          format: uuid
    diff:
      type: object
      description: Changed fields as [before, after]; secrets appear only as "changed" or "reset".
ActionList:
  type: object
  additionalProperties: false
  required: [items]
  properties:
    items:
      type: array
      items:
        $ref: "#/Action"
    next_cursor:
      type: string
      format: uuid
```

- [ ] **Step 4: Write the operations**

Create `api/paths/staff.yaml`:

```yaml
login:
  post:
    operationId: staffLogin
    summary: Check a staff member's email and password.
    description: |
      An unknown email, a wrong password and a disabled member all get
      invalid_credentials. Five failures on one email lock it for 15 minutes,
      whether or not a member has the email.
    tags: [staff]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/staff.yaml#/LoginRequest"
    responses:
      "200":
        description: The next sign-in step and its ticket.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/LoginStep"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "429":
        $ref: "../responses/common.yaml#/TooManyRequests"
loginPassword:
  post:
    operationId: staffLoginPassword
    summary: Replace the temporary password during sign-in.
    tags: [staff]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/staff.yaml#/LoginPasswordRequest"
    responses:
      "200":
        description: The next sign-in step and a new ticket.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/LoginStep"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "422":
        $ref: "../responses/common.yaml#/Unprocessable"
loginTotpEnrollment:
  post:
    operationId: staffLoginTotpEnrollment
    summary: Start TOTP enrollment during sign-in.
    description: A second call replaces the secret of the first.
    tags: [staff]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/staff.yaml#/TicketRequest"
    responses:
      "200":
        description: The secret to load into an authenticator.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/TOTPEnrollment"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
loginTotp:
  post:
    operationId: staffLoginTotp
    summary: Finish sign-in with a TOTP code.
    description: |
      The first correct code after enrollment confirms it. A wrong code counts
      toward the email's lock. Success sets the staff_refresh cookie.
    tags: [staff]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/staff.yaml#/LoginTOTPRequest"
    responses:
      "200":
        description: Signed in.
        headers:
          Set-Cookie:
            schema:
              type: string
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/StaffSignIn"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "429":
        $ref: "../responses/common.yaml#/TooManyRequests"
sessionRefresh:
  post:
    operationId: staffSessionRefresh
    summary: Get a new access token with the refresh cookie.
    tags: [staff]
    parameters:
      - $ref: "../parameters/common.yaml#/StaffCSRF"
      - $ref: "../parameters/common.yaml#/StaffRefreshCookie"
    responses:
      "200":
        description: A new access token; the cookie is rotated.
        headers:
          Set-Cookie:
            schema:
              type: string
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/StaffAccess"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
sessionLogout:
  post:
    operationId: staffSessionLogout
    summary: Sign this session out and clear the cookie.
    tags: [staff]
    security:
      - staffAuth: []
    responses:
      "204":
        description: Signed out.
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
me:
  get:
    operationId: getStaffMe
    summary: The signed-in staff member.
    tags: [staff]
    security:
      - staffAuth: []
    responses:
      "200":
        description: The member.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/Me"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
mePassword:
  put:
    operationId: changeStaffPassword
    summary: Change the password; the member's other sessions end.
    tags: [staff]
    security:
      - staffAuth: []
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/staff.yaml#/ChangePasswordRequest"
    responses:
      "204":
        description: Changed.
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "422":
        $ref: "../responses/common.yaml#/Unprocessable"
members:
  get:
    operationId: listStaffMembers
    summary: Staff members, newest first. Admins only.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/Cursor"
      - $ref: "../parameters/common.yaml#/Limit"
    responses:
      "200":
        description: One page of members.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/MemberList"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "403":
        $ref: "../responses/common.yaml#/StaffForbidden"
  post:
    operationId: createStaffMember
    summary: Create a moderator with a temporary password. Admins only.
    tags: [staff]
    security:
      - staffAuth: []
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/staff.yaml#/CreateMemberRequest"
    responses:
      "201":
        description: Created.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/CreatedMember"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "403":
        $ref: "../responses/common.yaml#/StaffForbidden"
      "409":
        $ref: "../responses/common.yaml#/Conflict"
memberDisable:
  post:
    operationId: disableStaffMember
    summary: Disable a moderator and end their sessions. Admins only.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/StaffMemberID"
    responses:
      "200":
        description: The member.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/Member"
      "403":
        $ref: "../responses/common.yaml#/StaffForbidden"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
memberEnable:
  post:
    operationId: enableStaffMember
    summary: Enable a disabled moderator. Admins only.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/StaffMemberID"
    responses:
      "200":
        description: The member.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/Member"
      "403":
        $ref: "../responses/common.yaml#/StaffForbidden"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
memberUnlock:
  post:
    operationId: unlockStaffMember
    summary: Clear the sign-in lock on a moderator's email. Admins only.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/StaffMemberID"
    responses:
      "200":
        description: The member.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/Member"
      "403":
        $ref: "../responses/common.yaml#/StaffForbidden"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
memberResetPassword:
  post:
    operationId: resetStaffMemberPassword
    summary: Give a moderator a temporary password and end their sessions. Admins only.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/StaffMemberID"
    responses:
      "200":
        description: The temporary password, shown once.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/TemporaryPassword"
      "403":
        $ref: "../responses/common.yaml#/StaffForbidden"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
memberResetTotp:
  post:
    operationId: resetStaffMemberTotp
    summary: Remove a moderator's TOTP and end their sessions. Admins only.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/StaffMemberID"
    responses:
      "200":
        description: The member, who enrolls again at the next sign-in.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/Member"
      "403":
        $ref: "../responses/common.yaml#/StaffForbidden"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
accounts:
  get:
    operationId: listStaffAccounts
    summary: Customer accounts, newest first, or the one q names.
    description: q matches an account ID, a phone number in any common form, or an email, exactly.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - name: q
        in: query
        schema:
          type: string
          minLength: 1
          maxLength: 254
      - $ref: "../parameters/common.yaml#/Cursor"
      - $ref: "../parameters/common.yaml#/Limit"
    responses:
      "200":
        description: One page of accounts.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/StaffAccountList"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
account:
  get:
    operationId: getStaffAccount
    summary: One customer account with its identities and staff history.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/StaffAccountID"
    responses:
      "200":
        description: The account.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/StaffAccountDetail"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
accountSuspend:
  post:
    operationId: suspendStaffAccount
    summary: Suspend a customer account.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/StaffAccountID"
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/staff.yaml#/SuspendRequest"
    responses:
      "200":
        description: The account.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/StaffAccount"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
      "422":
        $ref: "../responses/common.yaml#/Unprocessable"
accountUnsuspend:
  post:
    operationId: unsuspendStaffAccount
    summary: Lift a customer account's suspension.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - $ref: "../parameters/common.yaml#/StaffAccountID"
    responses:
      "200":
        description: The account.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/StaffAccount"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
actions:
  get:
    operationId: listStaffActions
    summary: The audit log, newest first. Admins only.
    tags: [staff]
    security:
      - staffAuth: []
    parameters:
      - name: staff_id
        in: query
        schema:
          type: string
          format: uuid
      - name: action
        in: query
        schema:
          type: string
          maxLength: 64
      - name: target_id
        in: query
        schema:
          type: string
          format: uuid
      - name: since
        in: query
        schema:
          type: string
          format: date-time
      - name: until
        in: query
        schema:
          type: string
          format: date-time
      - $ref: "../parameters/common.yaml#/Cursor"
      - $ref: "../parameters/common.yaml#/Limit"
    responses:
      "200":
        description: One page of actions.
        content:
          application/json:
            schema:
              $ref: "../schemas/staff.yaml#/ActionList"
      "403":
        $ref: "../responses/common.yaml#/StaffForbidden"
```

- [ ] **Step 5: Add the security scheme**

In `api/openapi.yaml`, under `components.securitySchemes`, after `bearerAuth`:

```yaml
    staffAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
      description: A staff access token (audience shopnexus-staff). Customer tokens fail here.
```

- [ ] **Step 6: Check every staff path resolves**

Temporarily add all nineteen staff paths to `api/openapi.yaml`, run the spec test, then remove them again:

```bash
cp api/openapi.yaml tmp/openapi.yaml.bak
python3 - <<'EOF'
p='api/openapi.yaml'
s=open(p).read()
paths='''  /v1/staff/login:
    $ref: "paths/staff.yaml#/login"
  /v1/staff/login/password:
    $ref: "paths/staff.yaml#/loginPassword"
  /v1/staff/login/totp-enrollment:
    $ref: "paths/staff.yaml#/loginTotpEnrollment"
  /v1/staff/login/totp:
    $ref: "paths/staff.yaml#/loginTotp"
  /v1/staff/session/refresh:
    $ref: "paths/staff.yaml#/sessionRefresh"
  /v1/staff/session/logout:
    $ref: "paths/staff.yaml#/sessionLogout"
  /v1/staff/me:
    $ref: "paths/staff.yaml#/me"
  /v1/staff/me/password:
    $ref: "paths/staff.yaml#/mePassword"
  /v1/staff/members:
    $ref: "paths/staff.yaml#/members"
  /v1/staff/members/{id}/disable:
    $ref: "paths/staff.yaml#/memberDisable"
  /v1/staff/members/{id}/enable:
    $ref: "paths/staff.yaml#/memberEnable"
  /v1/staff/members/{id}/unlock:
    $ref: "paths/staff.yaml#/memberUnlock"
  /v1/staff/members/{id}/reset-password:
    $ref: "paths/staff.yaml#/memberResetPassword"
  /v1/staff/members/{id}/reset-totp:
    $ref: "paths/staff.yaml#/memberResetTotp"
  /v1/staff/accounts:
    $ref: "paths/staff.yaml#/accounts"
  /v1/staff/accounts/{id}:
    $ref: "paths/staff.yaml#/account"
  /v1/staff/accounts/{id}/suspend:
    $ref: "paths/staff.yaml#/accountSuspend"
  /v1/staff/accounts/{id}/unsuspend:
    $ref: "paths/staff.yaml#/accountUnsuspend"
  /v1/staff/actions:
    $ref: "paths/staff.yaml#/actions"
'''
s=s.replace('components:\n', paths+'components:\n',1)
open(p,'w').write(s)
EOF
go test ./api/ -run TestSpecValid -count=1
cp tmp/openapi.yaml.bak api/openapi.yaml && rm tmp/openapi.yaml.bak
```

Expected: `ok  github.com/shopnexus/server2/api`. A `$ref` or schema error names the file and key to fix.

- [ ] **Step 7: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add api
git commit -m "api: design the staff endpoints

paths/staff.yaml and schemas/staff.yaml hold every staff operation: the
sign-in steps, the session, moderator management, the customer account
screens and the audit log. openapi.yaml gains the staffAuth scheme; each
operation joins it with its route and e2e tests.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `platform/token`

**Files:**
- Create: `internal/platform/token/token.go`, `internal/platform/token/token_test.go`
- Modify: `internal/auth/session/token.go`, `internal/auth/session/session.go`, `internal/auth/session/token_test.go`

**Interfaces:**
- Produces:
  - `token.Claims{Subject, SessionID uuid.UUID; AuthTime time.Time; Version int; Audience string; ExpiresAt time.Time}`
  - `token.NewSigner(config.AuthConfig) token.Signer`; `(Signer).Sign(c Claims, ttl time.Duration, now time.Time) (string, time.Time, error)`
  - `token.NewVerifier(config.AuthConfig) token.Verifier`; `(Verifier).Verify(tok, audience string, now time.Time) (Claims, error)`, every failure `token.ErrInvalid` (code `invalid_token`)
  - `token.NewRefresh() (token string, hash []byte)`, `token.HashRefresh(string) []byte`
  - `session.ErrInvalidToken` is `token.ErrInvalid`; `session.NewRefreshToken` and `session.HashRefresh` keep their signatures.

- [ ] **Step 1: Write the failing tests**

Create `internal/platform/token/token_test.go`:

```go
package token

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
	"uuid"

	"github.com/golang-jwt/jwt/v5"

	"github.com/shopnexus/server2/internal/platform/config"
)

var now = time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)

func keys(kid string) config.AuthConfig {
	k := config.NewAuthKeys()
	k.JWTKeyID, k.Issuer, k.Audience = kid, "server2-test", "unused"
	return k
}

func claims() Claims {
	return Claims{Subject: uuid.NewV7(), SessionID: uuid.NewV7(), AuthTime: now.Add(-time.Hour), Version: 3, Audience: "aud-a", ExpiresAt: time.Time{}}
}

func TestSignThenVerify(t *testing.T) {
	t.Parallel()
	k := keys("current")
	c := claims()
	tok, exp, err := NewSigner(k).Sign(c, 5*time.Minute, now)
	if err != nil || !exp.Equal(now.Add(5*time.Minute)) {
		t.Fatalf("%v %v", exp, err)
	}
	got, err := NewVerifier(k).Verify(tok, "aud-a", now.Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	c.ExpiresAt = exp
	if got != c {
		t.Fatalf("got %+v, want %+v", got, c)
	}
}

func TestOptionalClaimsStayZero(t *testing.T) {
	t.Parallel()
	k := keys("current")
	sub := uuid.NewV7()
	tok, _, _ := NewSigner(k).Sign(Claims{Subject: sub, SessionID: uuid.UUID{}, AuthTime: time.Time{}, Version: 0, Audience: "aud-a", ExpiresAt: time.Time{}}, time.Minute, now)
	got, err := NewVerifier(k).Verify(tok, "aud-a", now)
	if err != nil || got.Subject != sub || got.SessionID != (uuid.UUID{}) || !got.AuthTime.IsZero() || got.Version != 0 {
		t.Fatalf("%+v %v", got, err)
	}
}

func TestVerifyRejects(t *testing.T) {
	t.Parallel()
	k := keys("current")
	signer, verifier := NewSigner(k), NewVerifier(k)
	good, _, _ := signer.Sign(claims(), 5*time.Minute, now)
	raw := jwtClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer: k.Issuer, Audience: jwt.ClaimStrings{"aud-a"}, Subject: uuid.NewV7().String(),
			IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(now.Add(5 * time.Minute)),
			NotBefore: nil, ID: "",
		},
		SessionID: uuid.NewV7().String(), AuthTime: now.Unix(), Version: 0,
	}
	none := jwt.NewWithClaims(jwt.SigningMethodNone, raw)
	none.Header["kid"] = k.JWTKeyID
	noneToken, _ := none.SignedString(jwt.UnsafeAllowNoneSignatureType)
	swap := jwt.NewWithClaims(jwt.SigningMethodHS256, raw)
	swap.Header["kid"] = k.JWTKeyID
	swapToken, _ := swap.SignedString([]byte(k.JWTKey.Public().(ed25519.PublicKey)))
	forged, _, _ := NewSigner(keys("current")).Sign(claims(), 5*time.Minute, now)
	parts := strings.Split(good, ".")
	parts[1] = base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"` + uuid.NewV7().String() + `"}`))
	wrongIss := k
	wrongIss.Issuer = "someone-else"

	cases := []struct {
		name     string
		verifier Verifier
		token    string
		audience string
		at       time.Time
	}{
		{"expired past leeway", verifier, good, "aud-a", now.Add(5*time.Minute + 31*time.Second)},
		{"alg none", verifier, noneToken, "aud-a", now},
		{"HS256 keyed with the public key", verifier, swapToken, "aud-a", now},
		{"another key with the same kid", verifier, forged, "aud-a", now},
		{"tampered payload", verifier, strings.Join(parts, "."), "aud-a", now},
		{"another audience", verifier, good, "aud-b", now},
		{"another issuer", NewVerifier(wrongIss), good, "aud-a", now},
		{"garbage", verifier, "not.a.token", "aud-a", now},
		{"empty", verifier, "", "aud-a", now},
	}
	for _, c := range cases {
		if _, err := c.verifier.Verify(c.token, c.audience, c.at); !errors.Is(err, ErrInvalid) {
			t.Errorf("%s: %v", c.name, err)
		}
	}
	if _, err := verifier.Verify(good, "aud-a", now.Add(5*time.Minute+29*time.Second)); err != nil {
		t.Errorf("inside the leeway: %v", err)
	}
}

func TestVerifierKeyRotation(t *testing.T) {
	t.Parallel()
	old, current := keys("old"), keys("new")
	current.JWTPrevKeyID, current.JWTPrevKey = old.JWTKeyID, old.JWTKey.Public().(ed25519.PublicKey)
	oldToken, _, _ := NewSigner(old).Sign(claims(), time.Minute, now)
	if _, err := NewVerifier(current).Verify(oldToken, "aud-a", now); err != nil {
		t.Fatalf("token from the previous key: %v", err)
	}
	withoutPrev := current
	withoutPrev.JWTPrevKeyID, withoutPrev.JWTPrevKey = "", nil
	if _, err := NewVerifier(withoutPrev).Verify(oldToken, "aud-a", now); !errors.Is(err, ErrInvalid) {
		t.Fatalf("previous key dropped: %v", err)
	}
}

func TestNewRefresh(t *testing.T) {
	t.Parallel()
	tok, hash := NewRefresh()
	again, _ := NewRefresh()
	if !strings.HasPrefix(tok, "rt_") || len(tok) != 3+43 || string(hash) != string(HashRefresh(tok)) || again == tok {
		t.Fatalf("%q", tok)
	}
}
```

- [ ] **Step 2: Run it to see it fail**

Run: `go test ./internal/platform/token/`
Expected: FAIL, `undefined: Claims` (the package has no code yet).

- [ ] **Step 3: Write the package**

Create `internal/platform/token/token.go`:

```go
// Package token signs and verifies the EdDSA access tokens of every module
// and makes the random refresh tokens they rotate. The caller names the
// audience on both sides, so one module's tokens fail in another's verifier.
package token

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"fmt"
	"time"
	"uuid"

	"github.com/golang-jwt/jwt/v5"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/config"
)

// ErrInvalid is every verification failure; the cause is kept for the log.
var ErrInvalid = apperr.New(apperr.KindUnauthenticated, "invalid_token", "the access token is not valid")

// Claims is what a token says. SessionID, AuthTime and Version are zero
// when a token does not carry them.
type Claims struct {
	Subject   uuid.UUID
	SessionID uuid.UUID
	AuthTime  time.Time
	Version   int // the staff credentials version a login ticket was issued at
	Audience  string
	ExpiresAt time.Time // set by Verify
}

// jwtClaims is the wire form. No phone, email or name goes in: anyone
// holding a token can read it.
type jwtClaims struct {
	jwt.RegisteredClaims

	SessionID string `json:"sid,omitempty"`
	AuthTime  int64  `json:"auth_time,omitempty"`
	Version   int    `json:"cv,omitempty"`
}

// Signer signs with the current Ed25519 key.
type Signer struct {
	kid    string
	key    ed25519.PrivateKey
	issuer string
}

func NewSigner(cfg config.AuthConfig) Signer {
	return Signer{kid: cfg.JWTKeyID, key: cfg.JWTKey, issuer: cfg.Issuer}
}

// Sign returns a token for c valid ttl from now, and its expiry.
func (s Signer) Sign(c Claims, ttl time.Duration, now time.Time) (string, time.Time, error) {
	exp := now.Add(ttl)
	wire := jwtClaims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer: s.issuer, Audience: jwt.ClaimStrings{c.Audience}, Subject: c.Subject.String(),
			IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(exp), NotBefore: nil, ID: "",
		},
		SessionID: "", AuthTime: 0, Version: c.Version,
	}
	if c.SessionID != (uuid.UUID{}) {
		wire.SessionID = c.SessionID.String()
	}
	if !c.AuthTime.IsZero() {
		wire.AuthTime = c.AuthTime.Unix()
	}
	t := jwt.NewWithClaims(jwt.SigningMethodEdDSA, wire)
	t.Header["kid"] = s.kid
	signed, err := t.SignedString(s.key)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("sign token: %w", err)
	}
	return signed, exp, nil
}

// Verifier checks tokens against the current key and, during a key change,
// the previous one.
type Verifier struct {
	keys   map[string]ed25519.PublicKey
	issuer string
}

func NewVerifier(cfg config.AuthConfig) Verifier {
	keys := map[string]ed25519.PublicKey{cfg.JWTKeyID: cfg.JWTKey.Public().(ed25519.PublicKey)} //nolint:errcheck // An ed25519.PrivateKey always returns an ed25519.PublicKey.
	if cfg.JWTPrevKeyID != "" {
		keys[cfg.JWTPrevKeyID] = cfg.JWTPrevKey
	}
	return Verifier{keys: keys, issuer: cfg.Issuer}
}

// Verify returns the claims of a token valid at now for audience. Only
// EdDSA is accepted, which closes alg:none and algorithm-swap attacks.
func (v Verifier) Verify(tok, audience string, now time.Time) (Claims, error) {
	var c jwtClaims
	_, err := jwt.ParseWithClaims(tok, &c, func(t *jwt.Token) (any, error) {
		kid, ok := t.Header["kid"].(string)
		if !ok {
			return nil, errors.New("no kid header")
		}
		key, ok := v.keys[kid]
		if !ok {
			return nil, fmt.Errorf("unknown kid %q", kid)
		}
		return key, nil
	},
		jwt.WithValidMethods([]string{jwt.SigningMethodEdDSA.Alg()}),
		jwt.WithIssuer(v.issuer),
		jwt.WithAudience(audience),
		jwt.WithLeeway(30*time.Second),
		jwt.WithTimeFunc(func() time.Time { return now }),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
	)
	if err != nil {
		return Claims{}, invalid(err)
	}
	sub, err := uuid.Parse(c.Subject)
	if err != nil {
		return Claims{}, invalid(errors.New("sub is not a UUID"))
	}
	out := Claims{Subject: sub, SessionID: uuid.UUID{}, AuthTime: time.Time{}, Version: c.Version, Audience: audience, ExpiresAt: c.ExpiresAt.Time}
	if c.SessionID != "" {
		if out.SessionID, err = uuid.Parse(c.SessionID); err != nil {
			return Claims{}, invalid(errors.New("sid is not a UUID"))
		}
	}
	if c.AuthTime != 0 {
		out.AuthTime = time.Unix(c.AuthTime, 0).UTC()
	}
	return out, nil
}

func invalid(cause error) error {
	e := *ErrInvalid
	e.Err = cause
	return &e
}

// NewRefresh returns rt_ plus 32 random bytes in base64url, and its hash.
func NewRefresh() (token string, hash []byte) {
	b := make([]byte, 32)
	rand.Read(b)
	token = "rt_" + base64.RawURLEncoding.EncodeToString(b)
	return token, HashRefresh(token)
}

// HashRefresh is plain SHA-256: the token carries 256 random bits, so a slow
// hash would add nothing.
func HashRefresh(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}
```

- [ ] **Step 4: Run the token tests**

Run: `go test ./internal/platform/token/`
Expected: `ok`.

- [ ] **Step 5: Make `auth/session` wrap the package**

Replace the body of `internal/auth/session/token.go` from `// Signer signs access tokens` to the end of the file with:

```go
// Signer signs customer access tokens.
type Signer struct {
	t        token.Signer
	audience string
}

func NewSigner(cfg config.AuthConfig) Signer {
	return Signer{t: token.NewSigner(cfg), audience: cfg.Audience}
}

// Tokens signs an access token for x and pairs it with refresh, x's current
// refresh token.
func (s Signer) Tokens(x Session, refresh string, now time.Time) (Tokens, error) {
	access, exp, err := s.Sign(x, now)
	if err != nil {
		return Tokens{}, err
	}
	return Tokens{AccessToken: access, AccessTokenExpiresAt: exp, RefreshToken: refresh, TokenType: "Bearer"}, nil
}

// Sign returns an access token for x valid AccessTTL from now, and its expiry.
func (s Signer) Sign(x Session, now time.Time) (string, time.Time, error) {
	signed, exp, err := s.t.Sign(token.Claims{
		Subject: x.accountID, SessionID: x.id, AuthTime: x.authTime, Version: 0, Audience: s.audience, ExpiresAt: time.Time{},
	}, AccessTTL, now)
	if err != nil {
		return "", time.Time{}, fmt.Errorf("sign access token: %w", err)
	}
	return signed, exp, nil
}

// Verifier checks customer access tokens.
type Verifier struct {
	t        token.Verifier
	audience string
}

func NewVerifier(cfg config.AuthConfig) Verifier {
	return Verifier{t: token.NewVerifier(cfg), audience: cfg.Audience}
}

// Verify returns the principal of a valid token at now. A customer token
// carries a session and an auth time; one without either is invalid.
func (v Verifier) Verify(tok string, now time.Time) (authn.Principal, error) {
	c, err := v.t.Verify(tok, v.audience, now)
	if err != nil {
		return authn.Principal{}, fmt.Errorf("verify access token: %w", err)
	}
	if c.SessionID == (uuid.UUID{}) || c.AuthTime.IsZero() {
		e := *ErrInvalidToken
		e.Err = errors.New("sid or auth_time missing")
		return authn.Principal{}, &e
	}
	return authn.Principal{AccountID: c.Subject, SessionID: c.SessionID, AuthTime: c.AuthTime}, nil
}
```

In the same file delete the `Claims` type and the `jwt` and `ed25519` imports, and add `"github.com/shopnexus/server2/internal/platform/token"`. In `internal/auth/session/session.go` replace the `ErrInvalidToken` line in the `var` block with:

```go
	ErrInvalidToken   = token.ErrInvalid
```

and replace `NewRefreshToken` and `HashRefresh` with:

```go
// NewRefreshToken returns a fresh refresh token and its hash.
func NewRefreshToken() (string, []byte) { return token.NewRefresh() }

// HashRefresh hashes a refresh token for lookup.
func HashRefresh(t string) []byte { return token.HashRefresh(t) }
```

`New` and `Rotate` in `session.go` name a local `token`, which now shadows the package (gocritic `importShadow`). Rename it in both:

```go
	refresh, hash := NewRefreshToken()
```

and use `refresh` where they used `token` (`New` returns it, `Rotate` returns it). Run `golangci-lint fmt -E goimports ./internal/auth/session/` to fix the imports.

- [ ] **Step 6: Move the attack tests out of `auth/session`**

In `internal/auth/session/token_test.go` delete `TestVerifyRejects` (its cases now live in `platform/token`) and add a test that the wrapper still refuses a token for another audience:

```go
func TestVerifyRefusesAnotherAudience(t *testing.T) {
	t.Parallel()
	k := keys("current")
	good, _, _ := session.NewSigner(k).Sign(anySession(), now)
	other := k
	other.Audience = "shopnexus-staff"
	if _, err := session.NewVerifier(other).Verify(good, now); !errors.Is(err, session.ErrInvalidToken) {
		t.Fatalf("a customer token passed another audience: %v", err)
	}
}
```

Remove the now unused imports (`encoding/base64`, `strings`, `jwt`) with `golangci-lint fmt -E goimports ./internal/auth/session/`.

- [ ] **Step 7: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/platform/token internal/auth/session
git commit -m "refactor: sign tokens in platform/token

auth/session signed and verified its own EdDSA access tokens and made
refresh tokens. platform/token does both for any module: the caller names
the audience on signing and verifying, and claims without a session, an
auth time or a credentials version stay out of the token. auth/session
wraps it and keeps its API; the attack tests move with the code.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 3: Staff configuration

**Files:**
- Modify: `internal/platform/config/config.go`, `internal/platform/config/keys.go`, `internal/platform/config/config_test.go`, `cmd/keygen/main.go`, `Makefile`, `.env.example`, `internal/app/app.go`, `internal/app/app_test.go`, `e2e/main_test.go`
- Local, not committed: `.env`

**Interfaces:**
- Produces: `config.StaffConfig{Key []byte; ConsoleOrigin string}` as `Config.Staff`; `config.NewStaffKey() []byte`; `go run ./cmd/keygen -staff` prints `STAFF_KEY=<base64>`.

- [ ] **Step 1: Write the failing config tests**

In `internal/platform/config/config_test.go` add a package variable next to `testKeys`:

```go
var testStaffKey = NewStaffKey()
```

add to the map in `required()`:

```go
		"STAFF_KEY":            b64(testStaffKey),
		"STAFF_CONSOLE_ORIGIN": "http://console.test",
```

add to `want` in `TestLoadAllSet`:

```go
		Staff: StaffConfig{Key: testStaffKey, ConsoleOrigin: "http://console.test"},
```

add `"STAFF_CONSOLE_ORIGIN"` to the names in `TestLoadRejectsEmptyRequired`, and add a case to `TestLoadRejectsBadKeys`:

```go
		{"short staff key", map[string]string{"STAFF_KEY": b64(make([]byte, 16))}, "STAFF_KEY"},
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/platform/config/`
Expected: FAIL, `undefined: NewStaffKey` and `unknown field Staff`.

- [ ] **Step 3: Read the staff variables**

In `internal/platform/config/config.go` add the field to `Config` after `Auth`:

```go
	Staff          StaffConfig
```

add the type after `AuthConfig`:

```go
// StaffConfig holds the staff module's key and the console's origin. The key
// is never logged.
type StaffConfig struct {
	Key           []byte // STAFF_KEY: base64, at least 32 bytes; the staff subkeys derive from it
	ConsoleOrigin string // STAFF_CONSOLE_ORIGIN: the web console's origin, the only one CORS allows
}
```

and set it in the `cfg := Config{...}` literal after `Auth`:

```go
		Staff: StaffConfig{
			Key:           decodeKey("STAFF_KEY", 32, false),
			ConsoleOrigin: need("STAFF_CONSOLE_ORIGIN"),
		},
```

In `internal/platform/config/keys.go` add:

```go
// NewStaffKey returns a fresh STAFF_KEY. `make run` adds it to .env.
func NewStaffKey() []byte {
	k := make([]byte, 32)
	rand.Read(k)
	return k
}
```

- [ ] **Step 4: Run the config tests**

Run: `go test ./internal/platform/config/`
Expected: `ok`.

- [ ] **Step 5: Generate the key in development**

In `cmd/keygen/main.go` add a flag and print the key with it. Replace `main` with:

```go
func main() {
	restatePath := flag.String("restate", "", "path of the Restate identity key, created when missing")
	staff := flag.Bool("staff", false, "print a fresh STAFF_KEY line")
	flag.Parse()
	switch {
	case *staff:
		fmt.Println("STAFF_KEY=" + base64.StdEncoding.EncodeToString(config.NewStaffKey()))
	case *restatePath != "":
		key, err := restatex.EnsureIdentity(*restatePath)
		if err != nil {
			fmt.Fprintln(os.Stderr, "keygen:", err)
			os.Exit(1)
		}
		fmt.Println("RESTATE_IDENTITY_KEY=" + key)
	default:
		fmt.Print(config.NewAuthKeys().Env())
	}
}
```

and update its package comment to: `// Command keygen prints fresh OTP and JWT keys as .env lines. With -staff it prints a STAFF_KEY line. With -restate it makes sure the Restate request identity key exists at that path, and prints its public key as a .env line.` (wrapped at 78 columns). Add `"encoding/base64"` to the imports.

In `Makefile`, in the `run` target, after the `OTP_KEY` line add:

```make
	@grep -q '^STAFF_KEY=' .env || go run ./cmd/keygen -staff >> .env
```

In `.env.example`, after `JWT_PREVIOUS_PUBLIC_KEY=` add:

```
# The staff web console's origin; CORS allows it and nothing else.
STAFF_CONSOLE_ORIGIN=http://localhost:5173
```

and change the closing comment to name `STAFF_KEY` too:

```
# make run appends OTP_KEY, JWT_KEY_ID, JWT_PRIVATE_KEY, STAFF_KEY and
# RESTATE_IDENTITY_KEY to .env on first use.
```

Add the origin to the local `.env`, which is not committed: `printf 'STAFF_CONSOLE_ORIGIN=http://localhost:5173\n' >> .env`. The next `make run` appends `STAFF_KEY`.

- [ ] **Step 6: Refuse to start without staff settings**

In `internal/app/app.go`, in `New`, after the auth key check add:

```go
	if len(cfg.Staff.Key) < 32 || cfg.Staff.ConsoleOrigin == "" {
		return nil, errors.New("staff key or console origin missing from config; run make run, which adds the key to .env")
	}
```

In `internal/app/app_test.go`, in `testConfig`, add to the returned `config.Config`:

```go
		Staff: config.StaffConfig{Key: config.NewStaffKey(), ConsoleOrigin: "http://console.test"},
```

In `e2e/main_test.go`, in `run`, add the same field to `cfg`, with the origin `"http://console.e2e"`.

- [ ] **Step 7: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/platform/config cmd/keygen Makefile .env.example internal/app e2e/main_test.go
git commit -m "build: staff key and console origin in config

STAFF_KEY (32 bytes, generated by make run) and STAFF_CONSOLE_ORIGIN are
required like every variable. app.New refuses a config without them.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Migration `0003_staff.sql` and `platform/audit`

**Files:**
- Create: `migrations/0003_staff.sql`, `internal/platform/audit/audit.go`, `internal/platform/audit/store.go`, `internal/platform/audit/audit_test.go`, `internal/platform/audit/store_pg_test.go`
- Modify: `internal/platform/authn/authn.go`

**Interfaces:**
- Consumes: `page.Request`.
- Produces:
  - `authn.Staff{StaffID, SessionID uuid.UUID; Role string; IP netip.Addr}`, `authn.WithStaff(ctx, s) context.Context`, `authn.StaffFrom(ctx) (authn.Staff, bool)`
  - `audit.ActorKind` (`ActorStaff`, `ActorCLI`, `ActorAnonymous`), `audit.Actor{Kind; StaffID, SessionID uuid.UUID; Name string; IP netip.Addr}`
  - `audit.ByStaff(authn.Staff) Actor`, `audit.BySignIn(staffID uuid.UUID, ip netip.Addr) Actor`, `audit.ByCLI(osUser string) Actor`, `audit.Anonymous(ip netip.Addr) Actor`
  - `audit.Target{Kind string; ID uuid.UUID}`, `audit.Account(id) Target`, `audit.Staff(id) Target`
  - `audit.Entry{Actor; Action string; Target; Diff map[string]any; At time.Time}`
  - `audit.Diff(before, after any) map[string]any`, `audit.Insert(ctx, pgx.Tx, Entry) error`
  - `audit.Filter{StaffID uuid.UUID; Action string; TargetID uuid.UUID; Since, Until time.Time}` with `query` tags, `audit.Action` (the API's Action schema), `audit.Store{List(ctx, Filter, page.Request) ([]Action, error)}`, `audit.NewPGStore(*pgxpool.Pool) Store`

- [ ] **Step 1: Write the migration**

Create `migrations/0003_staff.sql`:

```sql
-- Staff: the moderators and admins of the web console, their sessions, the
-- sign-in lock per email, and the audit log of what staff did. Staff never
-- share a row with customers.

CREATE TABLE staff_members (
    id                   uuid PRIMARY KEY,
    -- Stored lower-cased, so the unique index is case-insensitive.
    email                text NOT NULL CHECK (email = lower(email) AND char_length(email) <= 254),
    display_name         text NOT NULL CHECK (char_length(display_name) BETWEEN 1 AND 100),
    role                 text NOT NULL CHECK (role IN ('moderator', 'admin')),
    status               text NOT NULL CHECK (status IN ('active', 'disabled')),
    -- argon2id in PHC string form; the parameters travel with the hash.
    password_hash        text NOT NULL,
    must_change_password boolean NOT NULL,
    -- Raised by a password change or reset, a TOTP reset and a disable. A
    -- login ticket and a session carry the version they were issued at.
    credentials_version  integer NOT NULL,
    -- AES-256-GCM under a key derived from STAFF_KEY, bound to the row's id.
    totp_secret          bytea,
    totp_pending_secret  bytea,
    totp_last_step       bigint NOT NULL,
    created_at           timestamptz NOT NULL,
    updated_at           timestamptz NOT NULL,
    write_id             uuid NOT NULL
);
CREATE UNIQUE INDEX staff_members_email ON staff_members (email);

CREATE TABLE staff_sessions (
    id                  uuid PRIMARY KEY,
    staff_id            uuid NOT NULL REFERENCES staff_members,
    refresh_hash        bytea NOT NULL UNIQUE,
    prev_refresh_hash   bytea,
    credentials_version integer NOT NULL,
    ip                  inet NOT NULL,
    user_agent          text NOT NULL CHECK (char_length(user_agent) <= 500),
    created_at          timestamptz NOT NULL,
    last_used_at        timestamptz NOT NULL,
    expires_at          timestamptz NOT NULL,
    revoked_at          timestamptz,
    write_id            uuid NOT NULL
);
CREATE INDEX staff_sessions_staff_id ON staff_sessions (staff_id);
CREATE INDEX staff_sessions_prev_refresh_hash ON staff_sessions (prev_refresh_hash) WHERE prev_refresh_hash IS NOT NULL;

-- key is HMAC-SHA256 of the lower-cased email under a key derived from
-- STAFF_KEY, so the table holds no address anyone typed. Unknown emails get
-- rows too, which keeps a lock from telling which emails are staff.
CREATE TABLE staff_login_quotas (
    key          bytea PRIMARY KEY,
    failures     integer NOT NULL,
    locked_until timestamptz,
    updated_at   timestamptz NOT NULL,
    write_id     uuid NOT NULL
);

-- Append only: no code updates or deletes a row.
CREATE TABLE staff_actions (
    id          uuid PRIMARY KEY,
    actor_kind  text NOT NULL CHECK (actor_kind IN ('staff', 'cli', 'anonymous')),
    staff_id    uuid REFERENCES staff_members,
    -- The OS user for the CLI.
    actor_name  text,
    session_id  uuid REFERENCES staff_sessions,
    ip          inet,
    action      text NOT NULL,
    target_kind text CHECK (target_kind IN ('account', 'staff')),
    target_id   uuid,
    diff        jsonb NOT NULL,
    at          timestamptz NOT NULL,
    CHECK ((actor_kind = 'staff') = (staff_id IS NOT NULL)),
    CHECK ((actor_kind = 'cli') = (actor_name IS NOT NULL)),
    CHECK ((target_kind IS NULL) = (target_id IS NULL))
);
CREATE INDEX staff_actions_staff_id ON staff_actions (staff_id, id);
CREATE INDEX staff_actions_action ON staff_actions (action, id);
CREATE INDEX staff_actions_target_id ON staff_actions (target_id, id);
```

Run `sqlfluff format migrations/0003_staff.sql` and keep its output.

- [ ] **Step 2: Add the staff caller to `authn`**

Append to `internal/platform/authn/authn.go`:

```go
// Staff is the signed-in staff member. It is a different type from
// Principal, so a customer handler never receives a staff caller or the
// other way round. Role is the member's role as staff.Require read it.
type Staff struct {
	StaffID   uuid.UUID
	SessionID uuid.UUID
	Role      string
	IP        netip.Addr
}

type staffKey struct{}

// WithStaff returns ctx carrying s.
func WithStaff(ctx context.Context, s Staff) context.Context {
	return context.WithValue(ctx, staffKey{}, s)
}

// StaffFrom returns the staff caller in ctx, if any.
func StaffFrom(ctx context.Context) (Staff, bool) {
	s, ok := ctx.Value(staffKey{}).(Staff)
	return s, ok
}
```

and add `"net/netip"` to its imports.

- [ ] **Step 3: Write the failing audit tests**

Create `internal/platform/audit/audit_test.go`:

```go
package audit_test

import (
	"reflect"
	"testing"
	"time"

	"github.com/shopnexus/server2/internal/platform/audit"
)

type view struct {
	Status string     `json:"status"`
	Reason string     `json:"reason,omitempty"`
	Until  *time.Time `json:"until,omitempty"`
}

func TestDiffKeepsChangedFieldsOnly(t *testing.T) {
	t.Parallel()
	got := audit.Diff(view{Status: "active", Reason: "", Until: nil}, view{Status: "suspended", Reason: "spam", Until: nil})
	want := map[string]any{"status": []any{"active", "suspended"}, "reason": []any{nil, "spam"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}
}

func TestDiffOfACreation(t *testing.T) {
	t.Parallel()
	got := audit.Diff(nil, view{Status: "active", Reason: "", Until: nil})
	if !reflect.DeepEqual(got, map[string]any{"status": []any{nil, "active"}}) {
		t.Fatalf("got %v", got)
	}
}

func TestDiffOfNoChange(t *testing.T) {
	t.Parallel()
	v := view{Status: "active", Reason: "", Until: nil}
	if got := audit.Diff(v, v); len(got) != 0 {
		t.Fatalf("got %v", got)
	}
}
```

Create `internal/platform/audit/store_pg_test.go`:

```go
package audit_test

import (
	"context"
	"net/netip"
	"testing"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/page"
	"github.com/shopnexus/server2/internal/platform/pgtest"
)

var at = time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)

// newMember inserts a staff_members row so a staff actor can reference it.
func newMember(t *testing.T, db *pgxpool.Pool, name string) uuid.UUID {
	t.Helper()
	id := uuid.NewV7()
	_, err := db.Exec(context.Background(), `
INSERT INTO staff_members (id, email, display_name, role, status, password_hash, must_change_password,
                           credentials_version, totp_last_step, created_at, updated_at, write_id)
VALUES (@id, @email, @name, 'moderator', 'active', 'x', false, 1, 0, @at, @at, @id)`,
		pgx.StrictNamedArgs{"id": id, "email": id.String() + "@staff.test", "name": name, "at": at})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func insert(t *testing.T, db *pgxpool.Pool, e audit.Entry) {
	t.Helper()
	if err := pgx.BeginFunc(context.Background(), db, func(tx pgx.Tx) error { return audit.Insert(context.Background(), tx, e) }); err != nil {
		t.Fatal(err)
	}
}

func TestListFiltersAndPages(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	s := audit.NewPGStore(db)
	ctx := context.Background()
	mod := newMember(t, db, "Mod One")
	acc := uuid.NewV7()
	ip := netip.MustParseAddr("203.0.113.9")

	insert(t, db, audit.Entry{Actor: audit.Anonymous(ip), Action: "staff.login_failed", Target: audit.Target{Kind: "", ID: uuid.UUID{}}, Diff: nil, At: at})
	insert(t, db, audit.Entry{Actor: audit.ByCLI("root"), Action: "staff.create", Target: audit.Staff(mod), Diff: map[string]any{"role": []any{nil, "moderator"}}, At: at.Add(time.Second)})
	insert(t, db, audit.Entry{
		Actor:  audit.Actor{Kind: audit.ActorStaff, StaffID: mod, SessionID: uuid.UUID{}, Name: "", IP: ip},
		Action: "account.suspend", Target: audit.Account(acc), Diff: map[string]any{"status": []any{"active", "suspended"}}, At: at.Add(2 * time.Second),
	})

	all, err := s.List(ctx, audit.Filter{}, page.Request{Limit: 10})
	if err != nil || len(all) != 3 {
		t.Fatalf("%+v %v", all, err)
	}
	if all[0].Action != "account.suspend" || all[0].Actor.DisplayName != "Mod One" || all[0].IP != "203.0.113.9" ||
		all[0].Target == nil || all[0].Target.ID != acc || all[0].Diff["status"] == nil {
		t.Fatalf("newest first, with the member's name: %+v", all[0])
	}
	if all[1].Actor.Kind != audit.ActorCLI || all[1].Actor.DisplayName != "root" || all[1].IP != "" {
		t.Fatalf("cli row: %+v", all[1])
	}
	if all[2].Target != nil || all[2].Actor.StaffID != nil || len(all[2].Diff) != 0 {
		t.Fatalf("anonymous row: %+v", all[2])
	}

	byTarget, _ := s.List(ctx, audit.Filter{TargetID: acc}, page.Request{Limit: 10})
	byAction, _ := s.List(ctx, audit.Filter{Action: "staff.create"}, page.Request{Limit: 10})
	byStaff, _ := s.List(ctx, audit.Filter{StaffID: mod}, page.Request{Limit: 10})
	since, _ := s.List(ctx, audit.Filter{Since: at.Add(time.Second)}, page.Request{Limit: 10})
	until, _ := s.List(ctx, audit.Filter{Until: at.Add(time.Second)}, page.Request{Limit: 10})
	if len(byTarget) != 1 || len(byAction) != 1 || len(byStaff) != 1 || len(since) != 2 || len(until) != 1 {
		t.Fatalf("filters: %d %d %d %d %d", len(byTarget), len(byAction), len(byStaff), len(since), len(until))
	}

	first, _ := s.List(ctx, audit.Filter{}, page.Request{Limit: 1})
	rest, _ := s.List(ctx, audit.Filter{}, page.Request{Cursor: first[0].ID, Limit: 5})
	if len(first) != 2 || len(rest) != 2 || rest[0].ID == first[0].ID {
		t.Fatalf("pages: %d then %d", len(first), len(rest))
	}
}
```

- [ ] **Step 4: Run them to see them fail**

Run: `go test ./internal/platform/audit/`
Expected: FAIL, `undefined: audit.Diff` and the other names.

- [ ] **Step 5: Write `audit.go`**

Create `internal/platform/audit/audit.go`:

```go
// Package audit records what staff, the CLI and anonymous sign-in attempts
// did. An adapter writes an Entry with Insert inside the transaction of the
// change it records, so the change and its record commit together or not at
// all. Diff takes view structs, never entities, so no secret reaches a row.
package audit

import (
	"context"
	"encoding/json"
	"fmt"
	"net/netip"
	"reflect"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"

	"github.com/shopnexus/server2/internal/platform/authn"
)

type ActorKind string

const (
	ActorStaff     ActorKind = "staff"
	ActorCLI       ActorKind = "cli"
	ActorAnonymous ActorKind = "anonymous"
)

// Actor is who acted. StaffID is set for ActorStaff, SessionID when a staff
// session acted, Name for the CLI, and IP for everything but the CLI.
type Actor struct {
	Kind      ActorKind
	StaffID   uuid.UUID
	SessionID uuid.UUID
	Name      string
	IP        netip.Addr
}

// ByStaff is the signed-in member the middleware put in the context.
func ByStaff(s authn.Staff) Actor {
	return Actor{Kind: ActorStaff, StaffID: s.StaffID, SessionID: s.SessionID, Name: "", IP: s.IP}
}

// BySignIn is a member acting during sign-in, before a session exists.
func BySignIn(staffID uuid.UUID, ip netip.Addr) Actor {
	return Actor{Kind: ActorStaff, StaffID: staffID, SessionID: uuid.UUID{}, Name: "", IP: ip}
}

// ByCLI is cmd/staff run by osUser.
func ByCLI(osUser string) Actor {
	return Actor{Kind: ActorCLI, StaffID: uuid.UUID{}, SessionID: uuid.UUID{}, Name: osUser, IP: netip.Addr{}}
}

// Anonymous is a sign-in attempt that proved nothing.
func Anonymous(ip netip.Addr) Actor {
	return Actor{Kind: ActorAnonymous, StaffID: uuid.UUID{}, SessionID: uuid.UUID{}, Name: "", IP: ip}
}

// Target is what an action changed; the zero Target is none.
type Target struct {
	Kind string
	ID   uuid.UUID
}

func Account(id uuid.UUID) Target { return Target{Kind: "account", ID: id} }
func Staff(id uuid.UUID) Target   { return Target{Kind: "staff", ID: id} }

// Entry is one row of staff_actions.
type Entry struct {
	Actor  Actor
	Action string // "account.suspend", "staff.disable", ...
	Target Target
	Diff   map[string]any // changed fields as [before, after]
	At     time.Time
}

// Diff returns the fields whose JSON differs between before and after, each
// as [before, after]. before is nil for a creation. Both must marshal to a
// JSON object; anything else is a mistake in the caller and panics.
func Diff(before, after any) map[string]any {
	b, a := fields(before), fields(after)
	out := map[string]any{}
	for k, av := range a {
		if bv, ok := b[k]; !ok || !reflect.DeepEqual(bv, av) {
			out[k] = []any{b[k], av}
		}
	}
	for k, bv := range b {
		if _, ok := a[k]; !ok {
			out[k] = []any{bv, nil}
		}
	}
	return out
}

func fields(v any) map[string]any {
	m := map[string]any{}
	if v == nil {
		return m
	}
	raw, err := json.Marshal(v)
	if err == nil {
		err = json.Unmarshal(raw, &m)
	}
	if err != nil {
		panic(fmt.Sprintf("audit: %T is not a JSON object: %v", v, err))
	}
	return m
}

const insertAction = `
INSERT INTO staff_actions (id, actor_kind, staff_id, actor_name, session_id, ip, action, target_kind, target_id, diff, at)
VALUES (@id, @actor_kind, @staff_id, @actor_name, @session_id, @ip, @action, @target_kind, @target_id, @diff, @at)`

// Insert writes e in tx, the transaction of the change it records.
func Insert(ctx context.Context, tx pgx.Tx, e Entry) error {
	diff := e.Diff
	if diff == nil {
		diff = map[string]any{}
	}
	_, err := tx.Exec(ctx, insertAction, pgx.StrictNamedArgs{
		"id": uuid.NewV7(), "actor_kind": e.Actor.Kind, "staff_id": nullID(e.Actor.StaffID),
		"actor_name": nullText(e.Actor.Name), "session_id": nullID(e.Actor.SessionID), "ip": nullIP(e.Actor.IP),
		"action": e.Action, "target_kind": nullText(e.Target.Kind), "target_id": nullID(e.Target.ID),
		"diff": diff, "at": e.At,
	})
	if err != nil {
		return fmt.Errorf("insert staff action: %w", err)
	}
	return nil
}

func nullID(id uuid.UUID) any {
	if id == (uuid.UUID{}) {
		return nil
	}
	return id
}

func nullText(s string) any {
	if s == "" {
		return nil
	}
	return s
}

func nullIP(ip netip.Addr) any {
	if !ip.IsValid() {
		return nil
	}
	return ip
}
```

- [ ] **Step 6: Write `store.go`**

Create `internal/platform/audit/store.go`:

```go
package audit

import (
	"context"
	"fmt"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/page"
)

// Filter narrows a listing; a zero field filters nothing. A handler binds it
// from the query, embedded next to page.Request.
type Filter struct {
	StaffID  uuid.UUID `json:"-" query:"staff_id"`
	Action   string    `json:"-" query:"action"`
	TargetID uuid.UUID `json:"-" query:"target_id"`
	Since    time.Time `json:"-" query:"since"`
	Until    time.Time `json:"-" query:"until"`
}

// Action is the Action schema in api/schemas/staff.yaml.
type Action struct {
	ID     uuid.UUID      `json:"id"`
	At     time.Time      `json:"at"`
	Actor  ActionActor    `json:"actor"`
	IP     string         `json:"ip,omitempty"`
	Action string         `json:"action"`
	Target *ActionTarget  `json:"target,omitempty"`
	Diff   map[string]any `json:"diff"`
}

type ActionActor struct {
	Kind        ActorKind  `json:"kind"`
	StaffID     *uuid.UUID `json:"staff_id,omitempty"`
	DisplayName string     `json:"display_name,omitempty"`
}

type ActionTarget struct {
	Kind string    `json:"kind"`
	ID   uuid.UUID `json:"id"`
}

// Store reads the audit log.
type Store interface {
	// List returns the actions f matches with IDs below p.Before(), newest
	// first, at most p.Fetch().
	List(ctx context.Context, f Filter, p page.Request) ([]Action, error)
}

type pgStore struct{ db *pgxpool.Pool }

func NewPGStore(db *pgxpool.Pool) Store { return pgStore{db} }

const listActions = `
SELECT a.id, a.at, a.actor_kind, a.staff_id, coalesce(m.display_name, a.actor_name, ''), coalesce(host(a.ip), ''),
       a.action, coalesce(a.target_kind, ''), a.target_id, a.diff
FROM staff_actions a
LEFT JOIN staff_members m ON m.id = a.staff_id
WHERE a.id < @before
  AND (@staff_id::uuid IS NULL OR a.staff_id = @staff_id)
  AND (@action::text IS NULL OR a.action = @action)
  AND (@target_id::uuid IS NULL OR a.target_id = @target_id)
  AND (@since::timestamptz IS NULL OR a.at >= @since)
  AND (@until::timestamptz IS NULL OR a.at < @until)
ORDER BY a.id DESC
LIMIT @limit`

func (s pgStore) List(ctx context.Context, f Filter, p page.Request) ([]Action, error) {
	rows, err := s.db.Query(ctx, listActions, pgx.StrictNamedArgs{
		"before": p.Before(), "limit": p.Fetch(), "staff_id": nullID(f.StaffID), "action": nullText(f.Action),
		"target_id": nullID(f.TargetID), "since": nullTime(f.Since), "until": nullTime(f.Until),
	})
	if err != nil {
		return nil, fmt.Errorf("select staff actions: %w", err)
	}
	defer rows.Close()
	var out []Action
	for rows.Next() {
		var (
			a          Action
			targetKind string
			targetID   *uuid.UUID
		)
		if err := rows.Scan(&a.ID, &a.At, &a.Actor.Kind, &a.Actor.StaffID, &a.Actor.DisplayName, &a.IP,
			&a.Action, &targetKind, &targetID, &a.Diff); err != nil {
			return nil, fmt.Errorf("read staff action: %w", err)
		}
		if targetID != nil {
			a.Target = &ActionTarget{Kind: targetKind, ID: *targetID}
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read staff actions: %w", err)
	}
	return out, nil
}

func nullTime(t time.Time) any {
	if t.IsZero() {
		return nil
	}
	return t
}
```

- [ ] **Step 7: Run the audit tests**

Run: `go test ./internal/platform/audit/`
Expected: `ok`. A `pgtest` template error means the migration has a syntax error; the message names the line.

- [ ] **Step 8: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add migrations/0003_staff.sql internal/platform/audit internal/platform/authn
git commit -m "feat: staff tables and the audit log

0003_staff.sql creates staff_members, staff_sessions, staff_login_quotas
and staff_actions. platform/audit writes an entry inside the caller's
transaction and lists the log with filters and a page. authn gains the
staff caller, a type apart from the customer principal.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Audited suspension and the staff view of accounts

**Files:**
- Create: `internal/account/account_record.go`, `internal/account/account_suspend.go`, `internal/account/account_suspend_test.go`
- Modify: `internal/account/account_store.go`, `internal/account/account_store_pg.go`, `internal/account/account_store_pg_test.go`, `internal/account/client.go`, `internal/account/client_test.go`

**Interfaces:**
- Consumes: `audit.Entry`, `audit.Insert`, `audit.Diff`, `audit.Account`, `page.Request`.
- Produces:
  - `account.Record{ID; DisplayName; Status; SuspendedUntil *time.Time; SuspendReason string; CreatedAt}` (JSON as `StaffAccount`)
  - `account.GetRecord(ctx, Store, id, now) (Record, error)`, `account.Records(ctx, Store, page.Request, now) ([]Record, error)`
  - `account.Suspend(ctx, Store, id, reason string, until *time.Time, by audit.Actor, now) (Record, error)` writes `account.suspend`; `account.Reinstate(ctx, Store, id, by, now) (Record, error)` writes `account.unsuspend`. A conflict is `apperr.ErrTryAgain`; an unknown id wraps `ErrNotFound`.
  - `Store.List(ctx, page.Request) ([]Account, error)`, `Store.SaveAudited(ctx, *Account, writeID, audit.Entry) error`
  - `account.Client` gains `Record(ctx, id)`, `Records(ctx, p)`, `Suspend(ctx, id, reason, until, by)`, `Reinstate(ctx, id, by)`.

- [ ] **Step 1: Write the failing store tests**

Append to `internal/account/account_store_pg_test.go`, and add to its imports whichever of `github.com/jackc/pgx/v5`, `github.com/shopnexus/server2/internal/platform/audit`, `github.com/shopnexus/server2/internal/platform/page` and `github.com/shopnexus/server2/internal/platform/pgtest` it lacks (`golangci-lint fmt -E goimports ./internal/account/` adds them):

```go
func TestSaveAuditedWritesBothOrNeither(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	s := account.NewPGStore(db)
	ctx := context.Background()
	id := seed(t, s)
	entry := audit.Entry{Actor: audit.ByCLI("test"), Action: "account.suspend", Target: audit.Account(id), Diff: nil, At: now}
	count := func() int {
		var n int
		if err := db.QueryRow(ctx, `SELECT count(*) FROM staff_actions WHERE target_id = @id`, pgx.StrictNamedArgs{"id": id}).Scan(&n); err != nil {
			t.Fatal(err)
		}
		return n
	}

	a, _ := s.Get(ctx, id)
	stale := a
	if err := a.Suspend("spam", nil, now); err != nil {
		t.Fatal(err)
	}
	w := uuid.NewV7()
	if err := s.SaveAudited(ctx, &a, w, entry); err != nil || a.WriteID() != w || count() != 1 {
		t.Fatalf("%v, write id %v, rows %d", err, a.WriteID(), count())
	}
	if err := s.SaveAudited(ctx, &stale, uuid.NewV7(), entry); !errors.Is(err, account.ErrConflict) || count() != 1 {
		t.Fatalf("stale save: %v, rows %d", err, count())
	}
}

func TestListNewestFirst(t *testing.T) {
	t.Parallel()
	s := account.NewPGStore(pgtest.New(t))
	ctx := context.Background()
	first, second := seed(t, s), seed(t, s)
	all, err := s.List(ctx, page.Request{Limit: 10})
	if err != nil || len(all) != 2 || all[0].ID() != second || all[1].ID() != first {
		t.Fatalf("%v %v", all, err)
	}
	rest, _ := s.List(ctx, page.Request{Cursor: second, Limit: 10})
	if len(rest) != 1 || rest[0].ID() != first {
		t.Fatalf("after the cursor: %v", rest)
	}
}
```

`seed` (in `account_create_test.go`) creates an account with `uuid.NewV7()`, so the second seed sorts after the first.

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/account/ -run 'SaveAudited|ListNewest'`
Expected: FAIL, `s.SaveAudited undefined`.

- [ ] **Step 3: Extend the port**

In `internal/account/account_store.go` add to `Store` after `Save`:

```go
	// SaveAudited is Save that writes e in the same transaction; a conflict
	// writes neither.
	SaveAudited(ctx context.Context, a *Account, writeID uuid.UUID, e audit.Entry) error
	// List is a query: accounts with IDs below p.Before(), newest first, at
	// most p.Fetch().
	List(ctx context.Context, p page.Request) ([]Account, error)
```

with imports `github.com/shopnexus/server2/internal/platform/audit` and `github.com/shopnexus/server2/internal/platform/page`.

- [ ] **Step 4: Implement them in the adapter**

In `internal/account/account_store_pg.go` replace `Save` with:

```go
// execer is a pool or a transaction.
type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func update(ctx context.Context, q execer, a *Account, writeID uuid.UUID) error {
	tag, err := q.Exec(ctx, saveAccount, pgx.StrictNamedArgs{
		"id": a.id, "read_write_id": a.writeID, "write_id": writeID,
		"display_name": a.displayName, "status": a.status, "suspended_until": a.suspendedUntil,
		"suspend_reason": a.suspendReason, "updated_at": a.updatedAt,
	})
	if err != nil {
		return fmt.Errorf("update account: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	return nil
}

func (s pgStore) Save(ctx context.Context, a *Account, writeID uuid.UUID) error {
	if err := update(ctx, s.db, a, writeID); err != nil {
		return err
	}
	a.writeID = writeID
	return nil
}

func (s pgStore) SaveAudited(ctx context.Context, a *Account, writeID uuid.UUID, e audit.Entry) error {
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if err := update(ctx, tx, a, writeID); err != nil {
			return err
		}
		return audit.Insert(ctx, tx, e)
	})
	if err != nil {
		return fmt.Errorf("save account with audit: %w", err)
	}
	a.writeID = writeID
	return nil
}

const listAccounts = `
SELECT id, coalesce(display_name, ''), status, suspended_until, coalesce(suspend_reason, ''), write_id, created_at, updated_at
FROM accounts WHERE id < @before ORDER BY id DESC LIMIT @limit`

func (s pgStore) List(ctx context.Context, p page.Request) ([]Account, error) {
	rows, err := s.db.Query(ctx, listAccounts, pgx.StrictNamedArgs{"before": p.Before(), "limit": p.Fetch()})
	if err != nil {
		return nil, fmt.Errorf("select accounts: %w", err)
	}
	defer rows.Close()
	var out []Account
	for rows.Next() {
		var a Account
		if err := rows.Scan(&a.id, &a.displayName, &a.status, &a.suspendedUntil, &a.suspendReason, &a.writeID,
			&a.createdAt, &a.updatedAt); err != nil {
			return nil, fmt.Errorf("read account: %w", err)
		}
		out = append(out, a)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read accounts: %w", err)
	}
	return out, nil
}
```

with imports `github.com/jackc/pgx/v5/pgconn`, `github.com/shopnexus/server2/internal/platform/audit`, `github.com/shopnexus/server2/internal/platform/page`.

- [ ] **Step 5: Run the store tests**

Run: `go test ./internal/account/ -run 'SaveAudited|ListNewest|PGStore'`
Expected: `ok`.

- [ ] **Step 6: Write the failing use case tests**

Create `internal/account/account_suspend_test.go`:

```go
package account_test

import (
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/pgtest"
)

func TestSuspendRecordsTheChange(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	s := account.NewPGStore(db)
	ctx := context.Background()
	id := seed(t, s)
	until := now.Add(24 * time.Hour)

	r, err := account.Suspend(ctx, s, id, "  spam  ", &until, audit.ByCLI("test"), now)
	if err != nil || r.Status != account.StatusSuspended || r.SuspendReason != "spam" || !r.SuspendedUntil.Equal(until) {
		t.Fatalf("%+v %v", r, err)
	}
	var action string
	var diff map[string]any
	if err := db.QueryRow(ctx, `SELECT action, diff FROM staff_actions WHERE target_id = @id`, pgx.StrictNamedArgs{"id": id}).
		Scan(&action, &diff); err != nil {
		t.Fatal(err)
	}
	if action != "account.suspend" || diff["status"] == nil || diff["suspend_reason"] == nil || diff["display_name"] != nil {
		t.Fatalf("%s %v", action, diff)
	}

	r, err = account.Reinstate(ctx, s, id, audit.ByCLI("test"), now)
	if err != nil || r.Status != account.StatusActive || r.SuspendReason != "" || r.SuspendedUntil != nil {
		t.Fatalf("%+v %v", r, err)
	}
}

func TestSuspendRefusals(t *testing.T) {
	t.Parallel()
	s := account.NewPGStore(pgtest.New(t))
	ctx := context.Background()
	id := seed(t, s)
	past := now.Add(-time.Hour)
	if _, err := account.Suspend(ctx, s, id, "   ", nil, audit.ByCLI("test"), now); !errors.Is(err, account.ErrSuspendReason) {
		t.Fatalf("blank reason: %v", err)
	}
	if _, err := account.Suspend(ctx, s, id, "spam", &past, audit.ByCLI("test"), now); !errors.Is(err, account.ErrSuspendUntil) {
		t.Fatalf("end in the past: %v", err)
	}
	if _, err := account.Suspend(ctx, s, uuid.NewV7(), "spam", nil, audit.ByCLI("test"), now); !errors.Is(err, account.ErrNotFound) {
		t.Fatalf("unknown account: %v", err)
	}
}

func TestRecordsHideALapsedSuspension(t *testing.T) {
	t.Parallel()
	s := account.NewPGStore(pgtest.New(t))
	ctx := context.Background()
	id := seed(t, s)
	until := now.Add(time.Hour)
	if _, err := account.Suspend(ctx, s, id, "spam", &until, audit.ByCLI("test"), now); err != nil {
		t.Fatal(err)
	}
	r, err := account.GetRecord(ctx, s, id, now.Add(2*time.Hour))
	if err != nil || r.Status != account.StatusActive || r.SuspendReason != "" || r.SuspendedUntil != nil {
		t.Fatalf("%+v %v", r, err)
	}
}
```

- [ ] **Step 7: Run them to see them fail**

Run: `go test ./internal/account/ -run 'Suspend|Records'`
Expected: FAIL, `undefined: account.Suspend`.

- [ ] **Step 8: Write the record and the use cases**

Create `internal/account/account_record.go`:

```go
package account

import (
	"context"
	"fmt"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/page"
)

// Record is an account as staff see it: the StaffAccount schema in
// api/schemas/staff.yaml. A suspension that has lapsed reads as active, with
// no reason or end.
type Record struct {
	ID             uuid.UUID  `json:"id"`
	DisplayName    string     `json:"display_name"`
	Status         Status     `json:"status"`
	SuspendedUntil *time.Time `json:"suspended_until,omitempty"`
	SuspendReason  string     `json:"suspend_reason,omitempty"`
	CreatedAt      time.Time  `json:"created_at"`
}

func recordOf(a Account, now time.Time) Record {
	r := Record{
		ID: a.ID(), DisplayName: a.DisplayName(), Status: a.Status(now), SuspendedUntil: nil, SuspendReason: "",
		CreatedAt: a.CreatedAt(),
	}
	if r.Status == StatusSuspended {
		r.SuspendedUntil, r.SuspendReason = a.SuspendedUntil(), a.SuspendReason()
	}
	return r
}

// GetRecord reads one account as staff see it.
func GetRecord(ctx context.Context, accounts Store, id uuid.UUID, now time.Time) (Record, error) {
	a, err := accounts.Get(ctx, id)
	if err != nil {
		return Record{}, fmt.Errorf("get account: %w", err)
	}
	return recordOf(a, now), nil
}

// Records lists accounts newest first. It returns the p.Fetch() rows the
// store read; the caller cuts the page.
func Records(ctx context.Context, accounts Store, p page.Request, now time.Time) ([]Record, error) {
	list, err := accounts.List(ctx, p)
	if err != nil {
		return nil, fmt.Errorf("list accounts: %w", err)
	}
	out := make([]Record, 0, len(list))
	for _, a := range list {
		out = append(out, recordOf(a, now))
	}
	return out, nil
}
```

Create `internal/account/account_suspend.go`:

```go
package account

import (
	"context"
	"errors"
	"fmt"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/audit"
)

// Suspend stops an account from writing, until the given time or, with a nil
// until, until Reinstate. It records account.suspend for by in the same
// transaction.
func Suspend(ctx context.Context, accounts Store, id uuid.UUID, reason string, until *time.Time, by audit.Actor, now time.Time) (Record, error) {
	a, err := accounts.Get(ctx, id)
	if err != nil {
		return Record{}, fmt.Errorf("get account: %w", err)
	}
	before := recordOf(a, now)
	if suspendErr := a.Suspend(reason, until, now); suspendErr != nil {
		return Record{}, suspendErr
	}
	after := recordOf(a, now)
	err = accounts.SaveAudited(ctx, &a, uuid.NewV7(), audit.Entry{
		Actor: by, Action: "account.suspend", Target: audit.Account(id), Diff: audit.Diff(before, after), At: now,
	})
	if errors.Is(err, ErrConflict) {
		return Record{}, apperr.ErrTryAgain
	}
	if err != nil {
		return Record{}, fmt.Errorf("save account: %w", err)
	}
	return after, nil
}

// Reinstate lifts a suspension and records account.unsuspend for by.
func Reinstate(ctx context.Context, accounts Store, id uuid.UUID, by audit.Actor, now time.Time) (Record, error) {
	a, err := accounts.Get(ctx, id)
	if err != nil {
		return Record{}, fmt.Errorf("get account: %w", err)
	}
	before := recordOf(a, now)
	a.Reinstate(now)
	after := recordOf(a, now)
	err = accounts.SaveAudited(ctx, &a, uuid.NewV7(), audit.Entry{
		Actor: by, Action: "account.unsuspend", Target: audit.Account(id), Diff: audit.Diff(before, after), At: now,
	})
	if errors.Is(err, ErrConflict) {
		return Record{}, apperr.ErrTryAgain
	}
	if err != nil {
		return Record{}, fmt.Errorf("save account: %w", err)
	}
	return after, nil
}
```

Append to `internal/account/client.go`:

```go
func (c Client) Record(ctx context.Context, id uuid.UUID) (Record, error) {
	return GetRecord(ctx, c.Store, id, c.Now())
}

func (c Client) Records(ctx context.Context, p page.Request) ([]Record, error) {
	return Records(ctx, c.Store, p, c.Now())
}

func (c Client) Suspend(ctx context.Context, id uuid.UUID, reason string, until *time.Time, by audit.Actor) (Record, error) {
	return Suspend(ctx, c.Store, id, reason, until, by, c.Now())
}

func (c Client) Reinstate(ctx context.Context, id uuid.UUID, by audit.Actor) (Record, error) {
	return Reinstate(ctx, c.Store, id, by, c.Now())
}
```

with imports `github.com/shopnexus/server2/internal/platform/audit` and `github.com/shopnexus/server2/internal/platform/page`. In `internal/account/client_test.go`, extend `TestClientDelegates` with a call to `c.Suspend` and `c.Reinstate` on the seeded account, checking the returned statuses.

- [ ] **Step 9: Run the account tests**

Run: `go test ./internal/account/`
Expected: `ok`.

- [ ] **Step 10: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/account
git commit -m "feat: audited suspension and the staff view of accounts

account.Record is an account as staff see it, suspension fields included.
Suspend and Reinstate record account.suspend and account.unsuspend in
the transaction of the change through Store.SaveAudited, and Store.List
pages accounts newest first. account.Client exposes the four for the staff
module.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 6: `staff/member`

**Files:**
- Create: `internal/staff/member/member.go`, `errors.go`, `password.go`, `totp.go`, `store.go`, `store_pg.go`, and tests `member_test.go`, `password_test.go`, `totp_test.go`, `store_pg_test.go`
- Modify: `go.mod`, `go.sum`

**Interfaces:**
- Consumes: `audit.Actor`, `audit.ActorCLI`, `audit.Entry`, `audit.Insert`, `contact.ParseEmail`, `page.Request`.
- Produces:
  - `member.Role` (`RoleModerator`, `RoleAdmin`) with `AtLeast(floor Role) bool`; `member.Status` (`StatusActive`, `StatusDisabled`); `member.Step` (`StepChangePassword`, `StepEnrollTOTP`, `StepTOTP`)
  - `member.New(id uuid.UUID, email, displayName string, role Role, passwordHash string, now time.Time) (Member, error)`; `member.NormalizeEmail(string) string`
  - `(*Member)`: `ID`, `Email`, `DisplayName`, `Role`, `Status`, `PasswordHash`, `CredentialsVersion() int`, `Enrolled() bool`, `Enrolling() bool`, `CreatedAt`, `WriteID`, `Next() Step`, `SetPassword(hash string, now)`, `ResetPassword(hash string, now)`, `StartEnrollment(secret []byte, now)`, `AcceptCode(code string, now) error`, `ResetTOTP(now)`, `Disable(now)`, `Enable(now)`, `ManagedBy(audit.Actor) error`
  - `member.Hasher{MemoryKiB, Time uint32; Threads uint8}`, `member.Production`, `member.Fast`, `(Hasher).Hash(string) string`, `member.VerifyPassword(phc, password string) bool`, `member.CheckPolicy(password, email string) error`, `member.TemporaryPassword() string`
  - `member.NewTOTPSecret() []byte`, `member.EncodeSecret([]byte) string`, `member.TOTPURI(secret []byte, email string) string`, `member.Code(secret []byte, at time.Time) string`
  - Errors: `ErrNotFound`, `ErrConflict`, `ErrEmailTaken` (409 `staff_email_taken`), `ErrInvalidMember` (422 `invalid_staff_member`), `ErrInvalidCredentials` (401 `invalid_credentials`), `ErrInvalidTOTPCode` (401 `invalid_totp_code`), `ErrPasswordTooWeak` (422 `password_too_weak`), `ErrAdminManagedByCLI` (403 `admin_managed_by_cli`)
  - `member.Store`: `CreateAudited(ctx, Member, audit.Entry) error`, `Get(ctx, id) (Member, error)`, `FindByEmail(ctx, email) (Member, error)`, `List(ctx, page.Request) ([]Member, error)`, `Save(ctx, *Member, writeID) error`, `SaveAudited(ctx, *Member, writeID, audit.Entry) error`; `member.NewPGStore(*pgxpool.Pool, cipher.AEAD) Store`

- [ ] **Step 1: Add `golang.org/x/crypto`**

```bash
go get golang.org/x/crypto@v0.58.0
```

It is imported in Step 6; `go mod tidy` in Step 9 keeps it.

- [ ] **Step 2: Write the failing entity tests**

Create `internal/staff/member/member_test.go`:

```go
package member_test

import (
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/staff/member"
)

var now = time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)

func newMember(t *testing.T, role member.Role) member.Member {
	t.Helper()
	m, err := member.New(uuid.NewV7(), " Mod@Example.COM ", " Mod One ", role, member.Fast.Hash("temporary-pass"), now)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func TestNewNormalises(t *testing.T) {
	t.Parallel()
	m := newMember(t, member.RoleModerator)
	if m.Email() != "mod@example.com" || m.DisplayName() != "Mod One" || m.Status() != member.StatusActive ||
		m.CredentialsVersion() != 1 || m.Next() != member.StepChangePassword || m.WriteID() != m.ID() {
		t.Fatalf("%+v", m)
	}
}

func TestNewRefuses(t *testing.T) {
	t.Parallel()
	cases := []struct{ email, name string; role member.Role }{
		{"not-an-email", "Mod", member.RoleModerator},
		{"mod@example.com", "  ", member.RoleModerator},
		{"mod@example.com", string(make([]rune, 101)), member.RoleModerator},
		{"mod@example.com", "Mod", member.Role("owner")},
	}
	for _, c := range cases {
		if _, err := member.New(uuid.NewV7(), c.email, c.name, c.role, "x", now); !errors.Is(err, member.ErrInvalidMember) {
			t.Errorf("%+v: %v", c, err)
		}
	}
}

func TestNextFollowsTheMember(t *testing.T) {
	t.Parallel()
	m := newMember(t, member.RoleModerator)
	m.SetPassword(member.Fast.Hash("a-long-new-password"), now)
	if m.Next() != member.StepEnrollTOTP || m.CredentialsVersion() != 2 {
		t.Fatalf("after the password: %s v%d", m.Next(), m.CredentialsVersion())
	}
	secret := member.NewTOTPSecret()
	m.StartEnrollment(secret, now)
	if m.Next() != member.StepEnrollTOTP || !m.Enrolling() || m.Enrolled() {
		t.Fatalf("enrolling: %s", m.Next())
	}
	if err := m.AcceptCode(member.Code(secret, now), now); err != nil {
		t.Fatal(err)
	}
	if m.Next() != member.StepTOTP || !m.Enrolled() || m.Enrolling() {
		t.Fatalf("enrolled: %s", m.Next())
	}
}

func TestAcceptCode(t *testing.T) {
	t.Parallel()
	m := newMember(t, member.RoleModerator)
	secret := member.NewTOTPSecret()
	m.StartEnrollment(secret, now)
	cur := member.Code(secret, now)
	wrong := cur[:5] + string(rune('0'+(cur[5]-'0'+1)%10))
	if err := m.AcceptCode(wrong, now); !errors.Is(err, member.ErrInvalidTOTPCode) {
		t.Fatalf("wrong code: %v", err)
	}
	if err := m.AcceptCode(member.Code(secret, now.Add(-30*time.Second)), now); err != nil {
		t.Fatalf("the previous step: %v", err)
	}
	if err := m.AcceptCode(member.Code(secret, now.Add(-30*time.Second)), now); !errors.Is(err, member.ErrInvalidTOTPCode) {
		t.Fatalf("the same code again: %v", err)
	}
	if err := m.AcceptCode(member.Code(secret, now), now); err != nil {
		t.Fatalf("the current step after the previous one: %v", err)
	}
	if err := m.AcceptCode(member.Code(secret, now.Add(-30*time.Second)), now.Add(30*time.Second)); !errors.Is(err, member.ErrInvalidTOTPCode) {
		t.Fatalf("a step already passed: %v", err)
	}
	if err := m.AcceptCode(member.Code(secret, now.Add(-time.Minute)), now.Add(2*time.Minute)); !errors.Is(err, member.ErrInvalidTOTPCode) {
		t.Fatalf("three steps old: %v", err)
	}
	fresh := newMember(t, member.RoleModerator)
	if err := fresh.AcceptCode("123456", now); !errors.Is(err, member.ErrInvalidTOTPCode) {
		t.Fatalf("no secret at all: %v", err)
	}
}

func TestVersionMovesWithCredentials(t *testing.T) {
	t.Parallel()
	m := newMember(t, member.RoleModerator)
	v := m.CredentialsVersion()
	m.Disable(now)
	m.Enable(now)
	m.ResetTOTP(now)
	m.ResetPassword(member.Fast.Hash("temporary-two"), now)
	if m.CredentialsVersion() != v+3 || m.Status() != member.StatusActive || m.Next() != member.StepChangePassword || m.Enrolled() {
		t.Fatalf("v%d %s %s", m.CredentialsVersion(), m.Status(), m.Next())
	}
}

func TestRoles(t *testing.T) {
	t.Parallel()
	if !member.RoleAdmin.AtLeast(member.RoleModerator) || member.RoleModerator.AtLeast(member.RoleAdmin) ||
		!member.RoleModerator.AtLeast(member.RoleModerator) || member.Role("owner").AtLeast(member.RoleModerator) {
		t.Fatal("role order")
	}
}

func TestManagedBy(t *testing.T) {
	t.Parallel()
	admin, mod := newMember(t, member.RoleAdmin), newMember(t, member.RoleModerator)
	staff := audit.Actor{Kind: audit.ActorStaff, StaffID: uuid.NewV7(), SessionID: uuid.UUID{}, Name: "", IP: clientIP}
	if err := admin.ManagedBy(staff); !errors.Is(err, member.ErrAdminManagedByCLI) {
		t.Fatalf("an admin by staff: %v", err)
	}
	if admin.ManagedBy(audit.ByCLI("root")) != nil || mod.ManagedBy(staff) != nil {
		t.Fatal("the CLI manages anyone; staff manage moderators")
	}
}
```

Add `clientIP = netip.MustParseAddr("203.0.113.7")` next to `now` (import `net/netip`).

Create `internal/staff/member/password_test.go`:

```go
package member_test

import (
	"errors"
	"strings"
	"testing"

	"github.com/shopnexus/server2/internal/staff/member"
)

func TestHashAndVerify(t *testing.T) {
	t.Parallel()
	h := member.Fast.Hash("correct horse battery")
	if !strings.HasPrefix(h, "$argon2id$v=19$m=8,t=1,p=1$") {
		t.Fatalf("PHC string: %s", h)
	}
	if !member.VerifyPassword(h, "correct horse battery") || member.VerifyPassword(h, "correct horse batterz") {
		t.Fatal("verify")
	}
	if member.Fast.Hash("same") == member.Fast.Hash("same") {
		t.Fatal("two hashes of one password share a salt")
	}
	other := member.Hasher{MemoryKiB: 16, Time: 2, Threads: 2}.Hash("p")
	if !member.VerifyPassword(other, "p") {
		t.Fatal("parameters come from the hash")
	}
	for _, bad := range []string{"", "plain", "$argon2id$v=19$m=8,t=1,p=1$!!$!!", "$argon2i$v=19$m=8,t=1,p=1$AAAA$AAAA"} {
		if member.VerifyPassword(bad, "p") {
			t.Errorf("verified against %q", bad)
		}
	}
}

func TestCheckPolicy(t *testing.T) {
	t.Parallel()
	for _, weak := range []string{"short-pass", strings.Repeat("x", 129), "Mod@Example.com"} {
		if err := member.CheckPolicy(weak, "mod@example.com"); !errors.Is(err, member.ErrPasswordTooWeak) {
			t.Errorf("%q: %v", weak, err)
		}
	}
	if err := member.CheckPolicy("twelve chars", "mod@example.com"); err != nil {
		t.Fatal(err)
	}
	if err := member.CheckPolicy(strings.Repeat("ữ", 12), "mod@example.com"); err != nil {
		t.Fatalf("characters, not bytes: %v", err)
	}
}

func TestTemporaryPassword(t *testing.T) {
	t.Parallel()
	a, b := member.TemporaryPassword(), member.TemporaryPassword()
	if len(a) != 16 || a == b || member.CheckPolicy(a, "x@y.z") != nil {
		t.Fatalf("%q %q", a, b)
	}
}
```

Create `internal/staff/member/totp_test.go`:

```go
package member_test

import (
	"encoding/base32"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/shopnexus/server2/internal/staff/member"
)

// RFC 6238 appendix B, SHA-1 rows, cut to six digits.
func TestCodeRFC6238(t *testing.T) {
	t.Parallel()
	secret := []byte("12345678901234567890")
	for unix, want := range map[int64]string{
		59: "287082", 1111111109: "081804", 1111111111: "050471",
		1234567890: "005924", 2000000000: "279037", 20000000000: "353130",
	} {
		if got := member.Code(secret, time.Unix(unix, 0)); got != want {
			t.Errorf("T=%d: got %s, want %s", unix, got, want)
		}
	}
}

func TestTOTPURI(t *testing.T) {
	t.Parallel()
	secret := member.NewTOTPSecret()
	u, err := url.Parse(member.TOTPURI(secret, "mod@example.com"))
	if err != nil {
		t.Fatal(err)
	}
	got, _ := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(u.Query().Get("secret"))
	if u.Scheme != "otpauth" || u.Host != "totp" || !strings.HasSuffix(u.Path, "shopnexus staff:mod@example.com") ||
		u.Query().Get("issuer") != "shopnexus staff" || string(got) != string(secret) || len(secret) != 20 {
		t.Fatalf("%s", u)
	}
	if member.EncodeSecret(secret) != u.Query().Get("secret") {
		t.Fatal("EncodeSecret differs from the URI's secret")
	}
}
```

- [ ] **Step 3: Run them to see them fail**

Run: `go test ./internal/staff/member/`
Expected: FAIL, `no non-test Go files` or `undefined: member.New`.

- [ ] **Step 4: Write the errors**

Create `internal/staff/member/errors.go`:

```go
package member

import (
	"errors"

	"github.com/shopnexus/server2/internal/platform/apperr"
)

var (
	ErrNotFound = errors.New("staff member: not found")
	ErrConflict = errors.New("staff member: changed meanwhile")

	ErrEmailTaken         = apperr.New(apperr.KindConflict, "staff_email_taken", "a staff member already has this email")
	ErrInvalidMember      = apperr.New(apperr.KindInvalid, "invalid_staff_member", "a staff member needs a valid email, a display name of 1 to 100 characters and a known role")
	ErrInvalidCredentials = apperr.New(apperr.KindUnauthenticated, "invalid_credentials", "the email or password is wrong")
	ErrInvalidTOTPCode    = apperr.New(apperr.KindUnauthenticated, "invalid_totp_code", "the code is wrong or was already used")
	ErrPasswordTooWeak    = apperr.New(apperr.KindInvalid, "password_too_weak", "a password has 12 to 128 characters and is neither the email nor the current password")
	ErrAdminManagedByCLI  = apperr.New(apperr.KindForbidden, "admin_managed_by_cli", "admins are managed with cmd/staff")
)
```

- [ ] **Step 5: Write the entity**

Create `internal/staff/member/member.go`:

```go
// Package member holds the staff member aggregate: email, role, status, the
// password hash and the TOTP secret. Hashing, codes and the password policy
// live here; the store seals TOTP secrets at rest.
package member

import (
	"strings"
	"time"
	"unicode/utf8"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/contact"
)

type Role string

const (
	RoleModerator Role = "moderator"
	RoleAdmin     Role = "admin"
)

// AtLeast reports whether r grants what floor does; an admin is also a
// moderator. An unknown role grants nothing.
func (r Role) AtLeast(floor Role) bool { return rank(r) > 0 && rank(r) >= rank(floor) }

func rank(r Role) int {
	switch r {
	case RoleAdmin:
		return 2
	case RoleModerator:
		return 1
	default:
		return 0
	}
}

type Status string

const (
	StatusActive   Status = "active"
	StatusDisabled Status = "disabled"
)

// Step is the sign-in call a member makes next.
type Step string

const (
	StepChangePassword Step = "change_password"
	StepEnrollTOTP     Step = "enroll_totp"
	StepTOTP           Step = "totp"
)

const maxNameRunes = 100

// Member is one moderator or admin. The store in this package reads the
// fields directly.
type Member struct {
	id                 uuid.UUID
	email              string
	displayName        string
	role               Role
	status             Status
	passwordHash       string
	mustChangePassword bool
	credentialsVersion int
	totpSecret         []byte
	totpPending        []byte
	totpLastStep       int64
	createdAt          time.Time
	updatedAt          time.Time
	writeID            uuid.UUID
}

// New builds an active member who replaces the password at the first
// sign-in. The first write ID is the id.
func New(id uuid.UUID, email, displayName string, role Role, passwordHash string, now time.Time) (Member, error) {
	addr, err := contact.ParseEmail(email)
	name := strings.TrimSpace(displayName)
	n := utf8.RuneCountInString(name)
	if err != nil || n == 0 || n > maxNameRunes || rank(role) == 0 {
		return Member{}, ErrInvalidMember
	}
	return Member{
		id: id, email: addr.Value(), displayName: name, role: role, status: StatusActive, passwordHash: passwordHash,
		mustChangePassword: true, credentialsVersion: 1, totpSecret: nil, totpPending: nil, totpLastStep: 0,
		createdAt: now, updatedAt: now, writeID: id,
	}, nil
}

// NormalizeEmail is the form emails are stored and looked up in.
func NormalizeEmail(raw string) string { return strings.ToLower(strings.TrimSpace(raw)) }

func (m *Member) ID() uuid.UUID           { return m.id }
func (m *Member) Email() string           { return m.email }
func (m *Member) DisplayName() string     { return m.displayName }
func (m *Member) Role() Role              { return m.role }
func (m *Member) Status() Status          { return m.status }
func (m *Member) PasswordHash() string    { return m.passwordHash }
func (m *Member) CredentialsVersion() int { return m.credentialsVersion }
func (m *Member) Enrolled() bool          { return m.totpSecret != nil }
func (m *Member) Enrolling() bool         { return m.totpPending != nil }
func (m *Member) CreatedAt() time.Time    { return m.createdAt }
func (m *Member) WriteID() uuid.UUID      { return m.writeID }

// Next is computed from the member, never taken from a ticket, so a client
// cannot skip a step.
func (m *Member) Next() Step {
	switch {
	case m.mustChangePassword:
		return StepChangePassword
	case m.totpSecret == nil:
		return StepEnrollTOTP
	default:
		return StepTOTP
	}
}

// SetPassword stores a password the member chose.
func (m *Member) SetPassword(hash string, now time.Time) {
	m.passwordHash, m.mustChangePassword = hash, false
	m.credentialsVersion++
	m.updatedAt = now
}

// ResetPassword stores a temporary password the member must replace.
func (m *Member) ResetPassword(hash string, now time.Time) {
	m.passwordHash, m.mustChangePassword = hash, true
	m.credentialsVersion++
	m.updatedAt = now
}

// StartEnrollment keeps secret until the first correct code confirms it; a
// second call replaces it.
func (m *Member) StartEnrollment(secret []byte, now time.Time) {
	m.totpPending = secret
	m.updatedAt = now
}

// AcceptCode checks code against the enrolled secret, or against the pending
// one, which a correct code then enrolls. A code whose time step is not past
// the last accepted one is refused.
func (m *Member) AcceptCode(code string, now time.Time) error {
	secret, enrolling := m.totpSecret, false
	if secret == nil {
		secret, enrolling = m.totpPending, true
	}
	if secret == nil {
		return ErrInvalidTOTPCode
	}
	step, ok := matchCode(secret, code, now, m.totpLastStep)
	if !ok {
		return ErrInvalidTOTPCode
	}
	if enrolling {
		m.totpSecret, m.totpPending = secret, nil
	}
	m.totpLastStep = step
	m.updatedAt = now
	return nil
}

// ResetTOTP removes the secret; the member enrolls again at the next
// sign-in, and every session ends.
func (m *Member) ResetTOTP(now time.Time) {
	m.totpSecret, m.totpPending = nil, nil
	m.credentialsVersion++
	m.updatedAt = now
}

// Disable stops the member signing in and ends every session; Enable does
// not bring the sessions back.
func (m *Member) Disable(now time.Time) {
	m.status = StatusDisabled
	m.credentialsVersion++
	m.updatedAt = now
}

func (m *Member) Enable(now time.Time) {
	m.status = StatusActive
	m.updatedAt = now
}

// ManagedBy refuses to let anyone but the CLI change an admin.
func (m *Member) ManagedBy(a audit.Actor) error {
	if m.role == RoleAdmin && a.Kind != audit.ActorCLI {
		return ErrAdminManagedByCLI
	}
	return nil
}
```

- [ ] **Step 6: Write passwords and TOTP**

Create `internal/staff/member/password.go`:

```go
package member

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"fmt"
	"strings"
	"unicode/utf8"

	"golang.org/x/crypto/argon2"
)

// Hasher holds the argon2id parameters for new hashes. VerifyPassword reads
// the parameters from the hash, so changing them never breaks a stored one.
type Hasher struct {
	MemoryKiB uint32
	Time      uint32
	Threads   uint8
}

var (
	// Production is the parameters of every stored hash outside tests.
	Production = Hasher{MemoryKiB: 64 * 1024, Time: 3, Threads: 4}
	// Fast keeps tests quick; argon2 needs at least 8 KiB per thread.
	Fast = Hasher{MemoryKiB: 8, Time: 1, Threads: 1}
)

const (
	saltLen = 16
	keyLen  = 32
	minLen  = 12
	maxLen  = 128
)

var b64 = base64.RawStdEncoding

// Hash returns password as a PHC string with a fresh salt.
func (h Hasher) Hash(password string) string {
	salt := make([]byte, saltLen)
	rand.Read(salt)
	key := argon2.IDKey([]byte(password), salt, h.Time, h.MemoryKiB, h.Threads, keyLen)
	return fmt.Sprintf("$argon2id$v=%d$m=%d,t=%d,p=%d$%s$%s", argon2.Version, h.MemoryKiB, h.Time, h.Threads,
		b64.EncodeToString(salt), b64.EncodeToString(key))
}

// VerifyPassword reports whether password matches phc, comparing in
// constant time. A malformed hash matches nothing.
func VerifyPassword(phc, password string) bool {
	parts := strings.Split(phc, "$")
	if len(parts) != 6 || parts[1] != "argon2id" || parts[2] != fmt.Sprintf("v=%d", argon2.Version) {
		return false
	}
	var h Hasher
	if _, err := fmt.Sscanf(parts[3], "m=%d,t=%d,p=%d", &h.MemoryKiB, &h.Time, &h.Threads); err != nil {
		return false
	}
	salt, err1 := b64.DecodeString(parts[4])
	want, err2 := b64.DecodeString(parts[5])
	if err1 != nil || err2 != nil || len(want) == 0 || h.Threads == 0 {
		return false
	}
	got := argon2.IDKey([]byte(password), salt, h.Time, h.MemoryKiB, h.Threads, uint32(len(want))) //nolint:gosec // len(want) is a decoded hash of a few dozen bytes.
	return subtle.ConstantTimeCompare(got, want) == 1
}

// CheckPolicy applies NIST SP 800-63B: 12 to 128 characters and not the
// email, with no composition rules.
func CheckPolicy(password, email string) error {
	n := utf8.RuneCountInString(password)
	if n < minLen || n > maxLen || strings.EqualFold(password, email) {
		return ErrPasswordTooWeak
	}
	return nil
}

// TemporaryPassword is 16 characters of base32, 80 random bits.
func TemporaryPassword() string { return rand.Text()[:16] }
```

Create `internal/staff/member/totp.go`:

```go
package member

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha1" //nolint:gosec // RFC 6238 TOTP, which every authenticator app implements, is HMAC-SHA1.
	"encoding/base32"
	"encoding/binary"
	"fmt"
	"net/url"
	"time"
)

const (
	totpPeriod = 30
	secretLen  = 20
	issuer     = "shopnexus staff"
)

var base32NoPad = base32.StdEncoding.WithPadding(base32.NoPadding)

// NewTOTPSecret returns 20 random bytes, the size RFC 4226 recommends.
func NewTOTPSecret() []byte {
	b := make([]byte, secretLen)
	rand.Read(b)
	return b
}

// EncodeSecret is the base32 form an authenticator takes by hand.
func EncodeSecret(secret []byte) string { return base32NoPad.EncodeToString(secret) }

// TOTPURI is the otpauth URI a QR code carries.
func TOTPURI(secret []byte, email string) string {
	q := url.Values{
		"secret": {EncodeSecret(secret)}, "issuer": {issuer},
		"algorithm": {"SHA1"}, "digits": {"6"}, "period": {"30"},
	}
	return "otpauth://totp/" + url.PathEscape(issuer+":"+email) + "?" + q.Encode()
}

// Code is the six-digit code for secret at t.
func Code(secret []byte, t time.Time) string { return codeAt(secret, t.Unix()/totpPeriod) }

func codeAt(secret []byte, step int64) string {
	var msg [8]byte
	binary.BigEndian.PutUint64(msg[:], uint64(step)) //nolint:gosec // A time step since 1970 is never negative.
	mac := hmac.New(sha1.New, secret)
	mac.Write(msg[:])
	sum := mac.Sum(nil)
	off := sum[len(sum)-1] & 0x0f
	bin := binary.BigEndian.Uint32(sum[off:off+4]) & 0x7fffffff
	return fmt.Sprintf("%06d", bin%1_000_000)
}

// matchCode accepts code for the step before, at or after now's, when that
// step is past last, and returns the step it matched.
func matchCode(secret []byte, code string, now time.Time, last int64) (int64, bool) {
	cur := now.Unix() / totpPeriod
	for _, s := range []int64{cur - 1, cur, cur + 1} {
		if s > last && hmac.Equal([]byte(codeAt(secret, s)), []byte(code)) {
			return s, true
		}
	}
	return 0, false
}
```

- [ ] **Step 7: Run the entity tests**

Run: `go test ./internal/staff/member/ -run 'New|Next|Accept|Version|Roles|Managed|Hash|Policy|Temporary|Code|URI'`
Expected: `ok`.

- [ ] **Step 8: Write the failing store tests**

Create `internal/staff/member/store_pg_test.go`:

```go
package member_test

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"testing"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/page"
	"github.com/shopnexus/server2/internal/platform/pgtest"
	"github.com/shopnexus/server2/internal/staff/member"
)

func sealer(t *testing.T) cipher.AEAD {
	t.Helper()
	key := make([]byte, 32)
	rand.Read(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		t.Fatal(err)
	}
	return aead
}

func newStore(t *testing.T) (member.Store, *pgxpool.Pool) {
	t.Helper()
	db := pgtest.New(t)
	return member.NewPGStore(db, sealer(t)), db
}

func created(t *testing.T, s member.Store, m member.Member) {
	t.Helper()
	e := audit.Entry{Actor: audit.ByCLI("test"), Action: "staff.create", Target: audit.Staff(m.ID()), Diff: nil, At: now}
	if err := s.CreateAudited(context.Background(), m, e); err != nil {
		t.Fatal(err)
	}
}

func actions(t *testing.T, db *pgxpool.Pool, id uuid.UUID) int {
	t.Helper()
	var n int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM staff_actions WHERE target_id = @id`,
		pgx.StrictNamedArgs{"id": id}).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}

func TestCreateGetFind(t *testing.T) {
	t.Parallel()
	s, db := newStore(t)
	ctx := context.Background()
	m := newMember(t, member.RoleModerator)
	created(t, s, m)
	if err := s.CreateAudited(ctx, m, audit.Entry{Actor: audit.ByCLI("test"), Action: "staff.create", Target: audit.Staff(m.ID()), Diff: nil, At: now}); err != nil {
		t.Fatalf("creating the same id again: %v", err)
	}
	if actions(t, db, m.ID()) != 1 {
		t.Fatal("a repeated create wrote a second audit row")
	}
	got, err := s.Get(ctx, m.ID())
	if err != nil || got.Email() != "mod@example.com" || got.Next() != member.StepChangePassword {
		t.Fatalf("%+v %v", got, err)
	}
	if f, err := s.FindByEmail(ctx, "mod@example.com"); err != nil || f.ID() != m.ID() {
		t.Fatalf("find: %v", err)
	}
	if _, err := s.FindByEmail(ctx, "nobody@example.com"); !errors.Is(err, member.ErrNotFound) {
		t.Fatalf("unknown email: %v", err)
	}
	if _, err := s.Get(ctx, uuid.NewV7()); !errors.Is(err, member.ErrNotFound) {
		t.Fatalf("unknown id: %v", err)
	}
}

func TestEmailTaken(t *testing.T) {
	t.Parallel()
	s, _ := newStore(t)
	created(t, s, newMember(t, member.RoleModerator))
	other := newMember(t, member.RoleAdmin)
	err := s.CreateAudited(context.Background(), other, audit.Entry{Actor: audit.ByCLI("test"), Action: "staff.create", Target: audit.Staff(other.ID()), Diff: nil, At: now})
	if !errors.Is(err, member.ErrEmailTaken) {
		t.Fatalf("got %v", err)
	}
}

func TestSecretsAreSealed(t *testing.T) {
	t.Parallel()
	s, db := newStore(t)
	ctx := context.Background()
	m := newMember(t, member.RoleModerator)
	created(t, s, m)
	secret := member.NewTOTPSecret()
	m.StartEnrollment(secret, now)
	if err := s.Save(ctx, &m, uuid.NewV7()); err != nil {
		t.Fatal(err)
	}
	var raw []byte
	if err := db.QueryRow(ctx, `SELECT totp_pending_secret FROM staff_members WHERE id = @id`, pgx.StrictNamedArgs{"id": m.ID()}).Scan(&raw); err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(raw, secret) || len(raw) <= len(secret) {
		t.Fatal("the secret is stored in the clear")
	}
	got, _ := s.Get(ctx, m.ID())
	if err := got.AcceptCode(member.Code(secret, now), now); err != nil {
		t.Fatalf("the sealed secret does not open: %v", err)
	}
}

func TestSaveAuditedConflictWritesNoAudit(t *testing.T) {
	t.Parallel()
	s, db := newStore(t)
	ctx := context.Background()
	m := newMember(t, member.RoleModerator)
	created(t, s, m)
	stale := m
	m.Disable(now)
	e := audit.Entry{Actor: audit.ByCLI("test"), Action: "staff.disable", Target: audit.Staff(m.ID()), Diff: nil, At: now}
	if err := s.SaveAudited(ctx, &m, uuid.NewV7(), e); err != nil {
		t.Fatal(err)
	}
	stale.Enable(now)
	if err := s.SaveAudited(ctx, &stale, uuid.NewV7(), e); !errors.Is(err, member.ErrConflict) {
		t.Fatalf("stale save: %v", err)
	}
	if actions(t, db, m.ID()) != 2 {
		t.Fatalf("rows %d, want the create and the disable", actions(t, db, m.ID()))
	}
}

func TestListNewestFirst(t *testing.T) {
	t.Parallel()
	s, _ := newStore(t)
	first := newMember(t, member.RoleModerator)
	created(t, s, first)
	second, _ := member.New(uuid.NewV7(), "two@example.com", "Two", member.RoleModerator, "x", now)
	created(t, s, second)
	got, err := s.List(context.Background(), page.Request{Limit: 10})
	if err != nil || len(got) != 2 || got[0].ID() != second.ID() {
		t.Fatalf("%v %v", got, err)
	}
}
```

- [ ] **Step 9: Write the store**

Create `internal/staff/member/store.go`:

```go
package member

import (
	"context"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/page"
)

// Store persists members. Each method is its own transaction.
type Store interface {
	// CreateAudited inserts m and writes e. Inserting the same id again does
	// nothing; another member's email is ErrEmailTaken.
	CreateAudited(ctx context.Context, m Member, e audit.Entry) error
	// Get returns ErrNotFound for an unknown id.
	Get(ctx context.Context, id uuid.UUID) (Member, error)
	// FindByEmail takes a NormalizeEmail form and returns ErrNotFound when no
	// member has it.
	FindByEmail(ctx context.Context, email string) (Member, error)
	// List is a query: members with IDs below p.Before(), newest first, at
	// most p.Fetch().
	List(ctx context.Context, p page.Request) ([]Member, error)
	// Save writes m when its row still has m.WriteID() or already has
	// writeID, then sets m's write ID. Otherwise ErrConflict.
	Save(ctx context.Context, m *Member, writeID uuid.UUID) error
	// SaveAudited is Save that writes e in the same transaction.
	SaveAudited(ctx context.Context, m *Member, writeID uuid.UUID, e audit.Entry) error
}
```

Create `internal/staff/member/store_pg.go`:

```go
package member

import (
	"context"
	"crypto/cipher"
	"crypto/rand"
	"errors"
	"fmt"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/page"
)

// pgStore seals TOTP secrets with AES-GCM, binding each ciphertext to its
// member's id, so a secret copied to another row does not open.
type pgStore struct {
	db   *pgxpool.Pool
	seal cipher.AEAD
}

func NewPGStore(db *pgxpool.Pool, seal cipher.AEAD) Store { return pgStore{db: db, seal: seal} }

const columns = `id, email, display_name, role, status, password_hash, must_change_password, credentials_version,
       totp_secret, totp_pending_secret, totp_last_step, created_at, updated_at, write_id`

func (s pgStore) sealed(id uuid.UUID, plain []byte) []byte {
	if plain == nil {
		return nil
	}
	nonce := make([]byte, s.seal.NonceSize())
	rand.Read(nonce)
	return s.seal.Seal(nonce, nonce, plain, id[:])
}

func (s pgStore) open(id uuid.UUID, sealed []byte) ([]byte, error) {
	if sealed == nil {
		return nil, nil
	}
	n := s.seal.NonceSize()
	if len(sealed) < n {
		return nil, errors.New("sealed secret too short")
	}
	plain, err := s.seal.Open(nil, sealed[:n], sealed[n:], id[:])
	if err != nil {
		return nil, fmt.Errorf("open totp secret: %w", err)
	}
	return plain, nil
}

func (s pgStore) scan(row pgx.Row) (Member, error) {
	var (
		m               Member
		secret, pending []byte
	)
	err := row.Scan(&m.id, &m.email, &m.displayName, &m.role, &m.status, &m.passwordHash, &m.mustChangePassword,
		&m.credentialsVersion, &secret, &pending, &m.totpLastStep, &m.createdAt, &m.updatedAt, &m.writeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Member{}, ErrNotFound
	}
	if err != nil {
		return Member{}, fmt.Errorf("select staff member: %w", err)
	}
	if m.totpSecret, err = s.open(m.id, secret); err != nil {
		return Member{}, err
	}
	if m.totpPending, err = s.open(m.id, pending); err != nil {
		return Member{}, err
	}
	return m, nil
}

const insertMember = `
INSERT INTO staff_members (` + columns + `)
VALUES (@id, @email, @display_name, @role, @status, @password_hash, @must_change_password, @credentials_version,
        @totp_secret, @totp_pending_secret, @totp_last_step, @created_at, @updated_at, @write_id)
ON CONFLICT (id) DO NOTHING`

func (s pgStore) CreateAudited(ctx context.Context, m Member, e audit.Entry) error {
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, insertMember, pgx.StrictNamedArgs{
			"id": m.id, "email": m.email, "display_name": m.displayName, "role": m.role, "status": m.status,
			"password_hash": m.passwordHash, "must_change_password": m.mustChangePassword,
			"credentials_version": m.credentialsVersion, "totp_secret": s.sealed(m.id, m.totpSecret),
			"totp_pending_secret": s.sealed(m.id, m.totpPending), "totp_last_step": m.totpLastStep,
			"created_at": m.createdAt, "updated_at": m.updatedAt, "write_id": m.writeID,
		})
		if pgErr, ok := errors.AsType[*pgconn.PgError](err); ok && pgErr.ConstraintName == "staff_members_email" {
			return ErrEmailTaken
		}
		if err != nil {
			return fmt.Errorf("insert staff member: %w", err)
		}
		if tag.RowsAffected() == 0 {
			return nil // the same id again
		}
		return audit.Insert(ctx, tx, e)
	})
	if err != nil {
		return fmt.Errorf("create staff member: %w", err)
	}
	return nil
}

func (s pgStore) Get(ctx context.Context, id uuid.UUID) (Member, error) {
	return s.scan(s.db.QueryRow(ctx, `SELECT `+columns+` FROM staff_members WHERE id = @id`, pgx.StrictNamedArgs{"id": id}))
}

func (s pgStore) FindByEmail(ctx context.Context, email string) (Member, error) {
	return s.scan(s.db.QueryRow(ctx, `SELECT `+columns+` FROM staff_members WHERE email = @email`, pgx.StrictNamedArgs{"email": email}))
}

func (s pgStore) List(ctx context.Context, p page.Request) ([]Member, error) {
	rows, err := s.db.Query(ctx, `SELECT `+columns+` FROM staff_members WHERE id < @before ORDER BY id DESC LIMIT @limit`,
		pgx.StrictNamedArgs{"before": p.Before(), "limit": p.Fetch()})
	if err != nil {
		return nil, fmt.Errorf("select staff members: %w", err)
	}
	defer rows.Close()
	var out []Member
	for rows.Next() {
		m, err := s.scan(rows)
		if err != nil {
			return nil, err
		}
		out = append(out, m)
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read staff members: %w", err)
	}
	return out, nil
}

const saveMember = `
UPDATE staff_members
SET display_name = @display_name, role = @role, status = @status, password_hash = @password_hash,
    must_change_password = @must_change_password, credentials_version = @credentials_version,
    totp_secret = @totp_secret, totp_pending_secret = @totp_pending_secret, totp_last_step = @totp_last_step,
    updated_at = @updated_at, write_id = @write_id
WHERE id = @id AND (write_id = @read_write_id OR write_id = @write_id)`

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func (s pgStore) update(ctx context.Context, q execer, m *Member, writeID uuid.UUID) error {
	tag, err := q.Exec(ctx, saveMember, pgx.StrictNamedArgs{
		"id": m.id, "read_write_id": m.writeID, "write_id": writeID, "display_name": m.displayName, "role": m.role,
		"status": m.status, "password_hash": m.passwordHash, "must_change_password": m.mustChangePassword,
		"credentials_version": m.credentialsVersion, "totp_secret": s.sealed(m.id, m.totpSecret),
		"totp_pending_secret": s.sealed(m.id, m.totpPending), "totp_last_step": m.totpLastStep, "updated_at": m.updatedAt,
	})
	if err != nil {
		return fmt.Errorf("update staff member: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	return nil
}

func (s pgStore) Save(ctx context.Context, m *Member, writeID uuid.UUID) error {
	if err := s.update(ctx, s.db, m, writeID); err != nil {
		return err
	}
	m.writeID = writeID
	return nil
}

func (s pgStore) SaveAudited(ctx context.Context, m *Member, writeID uuid.UUID, e audit.Entry) error {
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if err := s.update(ctx, tx, m, writeID); err != nil {
			return err
		}
		return audit.Insert(ctx, tx, e)
	})
	if err != nil {
		return fmt.Errorf("save staff member with audit: %w", err)
	}
	m.writeID = writeID
	return nil
}
```

Run `go mod tidy`.

- [ ] **Step 10: Run the member tests**

Run: `go test ./internal/staff/member/`
Expected: `ok`.

- [ ] **Step 11: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add go.mod go.sum internal/staff/member
git commit -m "feat: the staff member aggregate

staff/member holds a moderator or admin: the email, role and status, an
argon2id password hash in PHC form, and a TOTP secret the store seals with
AES-GCM bound to the member's id. The member computes its next sign-in
step, refuses a TOTP step it already accepted, and raises its credentials
version on every password change, password or TOTP reset and disable.
Only the CLI manages an admin.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `staff/quota`

**Files:**
- Create: `internal/staff/quota/quota.go`, `store.go`, `store_pg.go`, `quota_test.go`, `store_pg_test.go`

**Interfaces:**
- Consumes: `audit.Entry`, `audit.Insert`.
- Produces:
  - `quota.MaxFailures = 5`, `quota.LockFor = 15 * time.Minute`, `quota.ErrConflict`
  - `quota.Key(mac []byte, email string) []byte`, `quota.New(key []byte) Quota`
  - `(*Quota)`: `Key() []byte`, `Failures() int`, `Locked(now) (time.Duration, bool)`, `Fail(now) bool` (true when it locked), `Clear(now)`
  - `quota.Store`: `Get(ctx, key) (Quota, error)` (a new quota when there is no row), `Save(ctx, *Quota, writeID) error`, `SaveAudited(ctx, *Quota, writeID, audit.Entry) error`, `LockedUntil(ctx, keys [][]byte, now) (map[string]time.Time, error)` keyed by `string(key)`; `quota.NewPGStore(*pgxpool.Pool) Store`

- [ ] **Step 1: Write the failing tests**

Create `internal/staff/quota/quota_test.go`:

```go
package quota_test

import (
	"bytes"
	"testing"
	"time"

	"github.com/shopnexus/server2/internal/staff/quota"
)

var now = time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)

func TestFifthFailureLocks(t *testing.T) {
	t.Parallel()
	q := quota.New([]byte("k"))
	for i := 1; i < quota.MaxFailures; i++ {
		if q.Fail(now) {
			t.Fatalf("failure %d locked", i)
		}
	}
	if !q.Fail(now) {
		t.Fatal("the fifth failure did not lock")
	}
	if wait, locked := q.Locked(now.Add(time.Minute)); !locked || wait != quota.LockFor-time.Minute {
		t.Fatalf("locked %v for %v", locked, wait)
	}
	if _, locked := q.Locked(now.Add(quota.LockFor)); locked {
		t.Fatal("still locked after the lock ran out")
	}
	if q.Failures() != 0 {
		t.Fatal("the lock did not restart the count")
	}
}

func TestClear(t *testing.T) {
	t.Parallel()
	q := quota.New([]byte("k"))
	for range quota.MaxFailures {
		q.Fail(now)
	}
	q.Clear(now)
	if _, locked := q.Locked(now); locked || q.Failures() != 0 {
		t.Fatal("clear kept the lock")
	}
}

func TestKey(t *testing.T) {
	t.Parallel()
	mac := []byte("0123456789abcdef0123456789abcdef")
	a, b := quota.Key(mac, "mod@example.com"), quota.Key(mac, "mod@example.com")
	if !bytes.Equal(a, b) || len(a) != 32 || bytes.Contains(a, []byte("mod")) ||
		bytes.Equal(a, quota.Key([]byte("another key of thirty-two bytes!"), "mod@example.com")) {
		t.Fatal("key")
	}
}
```

Create `internal/staff/quota/store_pg_test.go`:

```go
package quota_test

import (
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/pgtest"
	"github.com/shopnexus/server2/internal/staff/quota"
)

func TestStore(t *testing.T) {
	t.Parallel()
	s := quota.NewPGStore(pgtest.New(t))
	ctx := context.Background()
	key := quota.Key([]byte("0123456789abcdef0123456789abcdef"), uuid.NewV7().String())

	q, err := s.Get(ctx, key)
	if err != nil || q.Failures() != 0 {
		t.Fatalf("a missing row: %+v %v", q, err)
	}
	racing := q
	q.Fail(now)
	if err := s.SaveAudited(ctx, &q, uuid.NewV7(), audit.Entry{Actor: audit.Anonymous(clientIP), Action: "staff.login_failed", Target: audit.Target{Kind: "", ID: uuid.UUID{}}, Diff: nil, At: now}); err != nil {
		t.Fatal(err)
	}
	racing.Fail(now)
	if err := s.Save(ctx, &racing, uuid.NewV7()); !errors.Is(err, quota.ErrConflict) {
		t.Fatalf("a second first save: %v", err)
	}
	got, _ := s.Get(ctx, key)
	if got.Failures() != 1 {
		t.Fatalf("failures %d", got.Failures())
	}
	for range quota.MaxFailures - 1 {
		got.Fail(now)
	}
	if err := s.Save(ctx, &got, uuid.NewV7()); err != nil {
		t.Fatal(err)
	}
	locked, err := s.LockedUntil(ctx, [][]byte{key, []byte("other")}, now)
	if err != nil || !locked[string(key)].Equal(now.Add(quota.LockFor)) || len(locked) != 1 {
		t.Fatalf("%v %v", locked, err)
	}
	if after, _ := s.LockedUntil(ctx, [][]byte{key}, now.Add(quota.LockFor+time.Second)); len(after) != 0 {
		t.Fatal("a lapsed lock is listed")
	}
}
```

Add `clientIP = netip.MustParseAddr("203.0.113.7")` next to `now` in `quota_test.go` (import `net/netip`).

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/staff/quota/`
Expected: FAIL, `undefined: quota.New`.

- [ ] **Step 3: Write the entity**

Create `internal/staff/quota/quota.go`:

```go
// Package quota locks a staff sign-in email after five failures in a row.
// Unknown emails count exactly like members' emails, so a lock tells nothing
// about which emails are staff. The key is an HMAC of the email.
package quota

import (
	"crypto/hmac"
	"crypto/sha256"
	"errors"
	"time"
	"uuid"
)

const (
	MaxFailures = 5
	LockFor     = 15 * time.Minute
)

var ErrConflict = errors.New("staff login quota: changed meanwhile")

// Quota counts failed sign-ins on one email.
type Quota struct {
	key         []byte
	failures    int
	lockedUntil *time.Time
	updatedAt   time.Time
	writeID     uuid.UUID // zero until first saved
}

// Key is HMAC-SHA256 of the normalised email under the staff quota key.
func Key(mac []byte, email string) []byte {
	h := hmac.New(sha256.New, mac)
	h.Write([]byte("staff-login:" + email))
	return h.Sum(nil)
}

// New is the quota of an email that has never failed.
func New(key []byte) Quota {
	return Quota{key: key, failures: 0, lockedUntil: nil, updatedAt: time.Time{}, writeID: uuid.UUID{}}
}

func (q *Quota) Key() []byte   { return q.key }
func (q *Quota) Failures() int { return q.failures }

// Locked reports whether the email is locked at now and for how long.
func (q *Quota) Locked(now time.Time) (time.Duration, bool) {
	if q.lockedUntil != nil && now.Before(*q.lockedUntil) {
		return q.lockedUntil.Sub(now), true
	}
	return 0, false
}

// Fail counts a failure. The fifth locks the email for LockFor and starts
// the count again; Fail reports whether it locked.
func (q *Quota) Fail(now time.Time) bool {
	q.failures++
	q.updatedAt = now
	if q.failures < MaxFailures {
		return false
	}
	until := now.Add(LockFor)
	q.lockedUntil, q.failures = &until, 0
	return true
}

// Clear forgets the failures and any lock.
func (q *Quota) Clear(now time.Time) {
	q.failures, q.lockedUntil, q.updatedAt = 0, nil, now
}
```

- [ ] **Step 4: Write the store**

Create `internal/staff/quota/store.go`:

```go
package quota

import (
	"context"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
)

// Store persists quotas. Each method is its own transaction.
type Store interface {
	// Get returns New(key) when the email has no row.
	Get(ctx context.Context, key []byte) (Quota, error)
	// Save writes q when its row still has q's write ID, or already has
	// writeID; a quota never saved conflicts with any row. Otherwise
	// ErrConflict.
	Save(ctx context.Context, q *Quota, writeID uuid.UUID) error
	// SaveAudited is Save that writes e in the same transaction.
	SaveAudited(ctx context.Context, q *Quota, writeID uuid.UUID, e audit.Entry) error
	// LockedUntil is a query: for each of keys locked at now, the end of the
	// lock, keyed by string(key).
	LockedUntil(ctx context.Context, keys [][]byte, now time.Time) (map[string]time.Time, error)
}
```

Create `internal/staff/quota/store_pg.go`:

```go
package quota

import (
	"context"
	"errors"
	"fmt"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/audit"
)

type pgStore struct{ db *pgxpool.Pool }

func NewPGStore(db *pgxpool.Pool) Store { return pgStore{db} }

func (s pgStore) Get(ctx context.Context, key []byte) (Quota, error) {
	q := New(key)
	err := s.db.QueryRow(ctx, `SELECT failures, locked_until, updated_at, write_id FROM staff_login_quotas WHERE key = @key`,
		pgx.StrictNamedArgs{"key": key}).Scan(&q.failures, &q.lockedUntil, &q.updatedAt, &q.writeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return New(key), nil
	}
	if err != nil {
		return Quota{}, fmt.Errorf("select staff login quota: %w", err)
	}
	return q, nil
}

// saveQuota inserts a new quota or updates one whose write_id matches. A
// quota never saved carries the zero UUID, which no row holds, so two first
// saves of one key conflict.
const saveQuota = `
INSERT INTO staff_login_quotas (key, failures, locked_until, updated_at, write_id)
VALUES (@key, @failures, @locked_until, @updated_at, @write_id)
ON CONFLICT (key) DO UPDATE
SET failures = EXCLUDED.failures, locked_until = EXCLUDED.locked_until, updated_at = EXCLUDED.updated_at,
    write_id = EXCLUDED.write_id
WHERE staff_login_quotas.write_id = @read_write_id OR staff_login_quotas.write_id = @write_id`

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func upsert(ctx context.Context, q execer, x *Quota, writeID uuid.UUID) error {
	tag, err := q.Exec(ctx, saveQuota, pgx.StrictNamedArgs{
		"key": x.key, "failures": x.failures, "locked_until": x.lockedUntil, "updated_at": x.updatedAt,
		"read_write_id": x.writeID, "write_id": writeID,
	})
	if err != nil {
		return fmt.Errorf("upsert staff login quota: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	return nil
}

func (s pgStore) Save(ctx context.Context, q *Quota, writeID uuid.UUID) error {
	if err := upsert(ctx, s.db, q, writeID); err != nil {
		return err
	}
	q.writeID = writeID
	return nil
}

func (s pgStore) SaveAudited(ctx context.Context, q *Quota, writeID uuid.UUID, e audit.Entry) error {
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if err := upsert(ctx, tx, q, writeID); err != nil {
			return err
		}
		return audit.Insert(ctx, tx, e)
	})
	if err != nil {
		return fmt.Errorf("save staff login quota with audit: %w", err)
	}
	q.writeID = writeID
	return nil
}

func (s pgStore) LockedUntil(ctx context.Context, keys [][]byte, now time.Time) (map[string]time.Time, error) {
	rows, err := s.db.Query(ctx, `SELECT key, locked_until FROM staff_login_quotas WHERE key = ANY(@keys) AND locked_until > @now`,
		pgx.StrictNamedArgs{"keys": keys, "now": now})
	if err != nil {
		return nil, fmt.Errorf("select staff login locks: %w", err)
	}
	defer rows.Close()
	out := map[string]time.Time{}
	for rows.Next() {
		var (
			key   []byte
			until time.Time
		)
		if err := rows.Scan(&key, &until); err != nil {
			return nil, fmt.Errorf("read staff login lock: %w", err)
		}
		out[string(key)] = until
	}
	if err := rows.Err(); err != nil {
		return nil, fmt.Errorf("read staff login locks: %w", err)
	}
	return out, nil
}
```

- [ ] **Step 5: Run the quota tests**

Run: `go test ./internal/staff/quota/`
Expected: `ok`.

- [ ] **Step 6: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/staff/quota
git commit -m "feat: the staff sign-in lock

staff/quota counts failed sign-ins per email, keyed by an HMAC of the
email, and locks the email for 15 minutes at the fifth failure. Unknown
emails get rows like members' emails. The store saves with write_id and
lists the locks for a page of members in one query.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `staff/session`

**Files:**
- Create: `internal/staff/session/session.go`, `store.go`, `store_pg.go`, `session_test.go`, `store_pg_test.go`

**Interfaces:**
- Consumes: `token.NewRefresh`, `audit.Entry`, `audit.Insert`, `member.Role`.
- Produces:
  - `session.TTL = 8 * time.Hour`, `session.AccessTTL = 5 * time.Minute`
  - Errors: `ErrNotFound`, `ErrConflict`, `ErrInvalidRefresh` (401 `invalid_refresh_token`), `ErrRevoked` (401 `session_revoked`), `ErrExpired` (401 `session_expired`)
  - `session.New(id, staffID uuid.UUID, version int, ip netip.Addr, userAgent string, now time.Time) (Session, string)`
  - `(*Session)`: `ID`, `StaffID`, `CredentialsVersion() int`, `ExpiresAt`, `RevokedAt`, `PrevRefreshHash`, `Usable(now) error`, `Rotate(now) string`, `Revoke(now)`, `SetVersion(int)`
  - `session.Grant{Role member.Role; Active, Current bool; RevokedAt *time.Time; ExpiresAt time.Time}` with `Check(now) error`
  - `session.Store`: `CreateAudited(ctx, Session, audit.Entry) error`, `Get(ctx, id)`, `FindByRefresh(ctx, hash)`, `FindByPrevRefresh(ctx, hash)`, `Save(ctx, *Session, writeID)`, `SaveAudited(ctx, *Session, writeID, audit.Entry)`, `Grant(ctx, id, staffID uuid.UUID) (Grant, error)`; `session.NewPGStore(*pgxpool.Pool) Store`

- [ ] **Step 1: Write the failing tests**

Create `internal/staff/session/session_test.go`:

```go
package session_test

import (
	"bytes"
	"errors"
	"net/netip"
	"strings"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/session"
)

var (
	now      = time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)
	clientIP = netip.MustParseAddr("203.0.113.7")
)

func TestNewAndRotate(t *testing.T) {
	t.Parallel()
	s, refresh := session.New(uuid.NewV7(), uuid.NewV7(), 4, clientIP, strings.Repeat("a", 600), now)
	if !s.ExpiresAt().Equal(now.Add(session.TTL)) || s.CredentialsVersion() != 4 || len([]rune(s.UserAgent())) != 500 {
		t.Fatalf("%+v", s)
	}
	next := s.Rotate(now.Add(time.Minute))
	if next == refresh || !bytes.Equal(s.PrevRefreshHash(), token.HashRefresh(refresh)) {
		t.Fatal("rotate")
	}
}

func TestUsable(t *testing.T) {
	t.Parallel()
	s, _ := session.New(uuid.NewV7(), uuid.NewV7(), 1, clientIP, "", now)
	if s.Usable(now.Add(session.TTL-time.Second)) != nil {
		t.Fatal("usable inside the eight hours")
	}
	if err := s.Usable(now.Add(session.TTL)); !errors.Is(err, session.ErrExpired) {
		t.Fatalf("at eight hours: %v", err)
	}
	s.Revoke(now)
	if err := s.Usable(now); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("revoked: %v", err)
	}
}

func TestGrantCheck(t *testing.T) {
	t.Parallel()
	ok := session.Grant{Role: member.RoleModerator, Active: true, Current: true, RevokedAt: nil, ExpiresAt: now.Add(time.Hour)}
	if ok.Check(now) != nil {
		t.Fatal("a live grant")
	}
	revoked, inactive, old, expired := ok, ok, ok, ok
	revoked.RevokedAt = &now
	inactive.Active = false
	old.Current = false
	expired.ExpiresAt = now
	for name, g := range map[string]session.Grant{"revoked": revoked, "disabled member": inactive, "old version": old} {
		if err := g.Check(now); !errors.Is(err, session.ErrRevoked) {
			t.Errorf("%s: %v", name, err)
		}
	}
	if err := expired.Check(now); !errors.Is(err, session.ErrExpired) {
		t.Fatalf("expired: %v", err)
	}
}
```

Create `internal/staff/session/store_pg_test.go`:

```go
package session_test

import (
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/pgtest"
	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/session"
)

// newMember inserts an active moderator at credentials version 1.
func newMember(t *testing.T, db *pgxpool.Pool) uuid.UUID {
	t.Helper()
	id := uuid.NewV7()
	_, err := db.Exec(context.Background(), `
INSERT INTO staff_members (id, email, display_name, role, status, password_hash, must_change_password,
                           credentials_version, totp_last_step, created_at, updated_at, write_id)
VALUES (@id, @email, 'Mod', 'moderator', 'active', 'x', false, 1, 0, @at, @at, @id)`,
		pgx.StrictNamedArgs{"id": id, "email": id.String() + "@staff.test", "at": now})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

func login(staffID, sessionID uuid.UUID) audit.Entry {
	return audit.Entry{
		Actor:  audit.Actor{Kind: audit.ActorStaff, StaffID: staffID, SessionID: sessionID, Name: "", IP: clientIP},
		Action: "staff.login", Target: audit.Staff(staffID), Diff: nil, At: now,
	}
}

func TestStore(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	st := session.NewPGStore(db)
	ctx := context.Background()
	staffID := newMember(t, db)
	s, refresh := session.New(uuid.NewV7(), staffID, 1, clientIP, "Firefox", now)
	if err := st.CreateAudited(ctx, s, login(staffID, s.ID())); err != nil {
		t.Fatal(err)
	}
	got, err := st.FindByRefresh(ctx, token.HashRefresh(refresh))
	if err != nil || got.ID() != s.ID() || got.IP() != clientIP || got.UserAgent() != "Firefox" {
		t.Fatalf("%+v %v", got, err)
	}
	stale := got
	next := got.Rotate(now.Add(time.Minute))
	if err := st.Save(ctx, &got, uuid.NewV7()); err != nil {
		t.Fatal(err)
	}
	if _, err := st.FindByRefresh(ctx, token.HashRefresh(next)); err != nil {
		t.Fatalf("by the new token: %v", err)
	}
	if prev, err := st.FindByPrevRefresh(ctx, token.HashRefresh(refresh)); err != nil || prev.ID() != s.ID() {
		t.Fatalf("by the old token: %v", err)
	}
	stale.Revoke(now)
	if err := st.Save(ctx, &stale, uuid.NewV7()); !errors.Is(err, session.ErrConflict) {
		t.Fatalf("stale save: %v", err)
	}
	if _, err := st.FindByRefresh(ctx, []byte("nothing")); !errors.Is(err, session.ErrNotFound) {
		t.Fatalf("unknown token: %v", err)
	}
}

func TestGrantFollowsTheMember(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	st := session.NewPGStore(db)
	ctx := context.Background()
	staffID := newMember(t, db)
	s, _ := session.New(uuid.NewV7(), staffID, 1, clientIP, "", now)
	if err := st.CreateAudited(ctx, s, login(staffID, s.ID())); err != nil {
		t.Fatal(err)
	}
	g, err := st.Grant(ctx, s.ID(), staffID)
	if err != nil || g.Role != member.RoleModerator || !g.Active || !g.Current || g.Check(now) != nil {
		t.Fatalf("%+v %v", g, err)
	}
	if _, err := db.Exec(ctx, `UPDATE staff_members SET credentials_version = 2 WHERE id = @id`, pgx.StrictNamedArgs{"id": staffID}); err != nil {
		t.Fatal(err)
	}
	if g, _ = st.Grant(ctx, s.ID(), staffID); g.Current || !errors.Is(g.Check(now), session.ErrRevoked) {
		t.Fatalf("after a credentials change: %+v", g)
	}
	if _, err := st.Grant(ctx, s.ID(), uuid.NewV7()); !errors.Is(err, session.ErrNotFound) {
		t.Fatalf("another member's session: %v", err)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/staff/session/`
Expected: FAIL, `undefined: session.New`.

- [ ] **Step 3: Write the entity**

Create `internal/staff/session/session.go`:

```go
// Package session holds staff sessions: one sign-in in one browser, eight
// hours long, with a refresh token that rotates in an HttpOnly cookie. A
// session lives only while its member's credentials version equals the one
// it was issued at.
package session

import (
	"errors"
	"net/netip"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff/member"
)

const (
	TTL          = 8 * time.Hour
	AccessTTL    = 5 * time.Minute
	maxUserAgent = 500
)

var (
	ErrNotFound       = errors.New("staff session: not found")
	ErrConflict       = errors.New("staff session: changed meanwhile")
	ErrInvalidRefresh = apperr.New(apperr.KindUnauthenticated, "invalid_refresh_token", "the refresh token is not valid")
	ErrRevoked        = apperr.New(apperr.KindUnauthenticated, "session_revoked", "the session was signed out")
	ErrExpired        = apperr.New(apperr.KindUnauthenticated, "session_expired", "the session has expired; sign in again")
)

type Session struct {
	id                 uuid.UUID
	staffID            uuid.UUID
	refreshHash        []byte
	prevRefreshHash    []byte
	credentialsVersion int
	ip                 netip.Addr
	userAgent          string
	createdAt          time.Time
	lastUsedAt         time.Time
	expiresAt          time.Time
	revokedAt          *time.Time
	writeID            uuid.UUID
}

// New starts a session at the member's credentials version and returns its
// refresh token; only the hash is kept. The first write ID is the id.
func New(id, staffID uuid.UUID, version int, ip netip.Addr, userAgent string, now time.Time) (Session, string) {
	refresh, hash := token.NewRefresh()
	if r := []rune(userAgent); len(r) > maxUserAgent {
		userAgent = string(r[:maxUserAgent])
	}
	return Session{
		id: id, staffID: staffID, refreshHash: hash, prevRefreshHash: nil, credentialsVersion: version, ip: ip,
		userAgent: userAgent, createdAt: now, lastUsedAt: now, expiresAt: now.Add(TTL), revokedAt: nil, writeID: id,
	}, refresh
}

func (s *Session) ID() uuid.UUID           { return s.id }
func (s *Session) StaffID() uuid.UUID      { return s.staffID }
func (s *Session) CredentialsVersion() int { return s.credentialsVersion }
func (s *Session) IP() netip.Addr          { return s.ip }
func (s *Session) UserAgent() string       { return s.userAgent }
func (s *Session) CreatedAt() time.Time    { return s.createdAt }
func (s *Session) ExpiresAt() time.Time    { return s.expiresAt }
func (s *Session) RevokedAt() *time.Time   { return s.revokedAt }
func (s *Session) PrevRefreshHash() []byte { return s.prevRefreshHash }

// Usable returns nil while the session is unrevoked and younger than TTL.
func (s *Session) Usable(now time.Time) error {
	if s.revokedAt != nil {
		return ErrRevoked
	}
	if !now.Before(s.expiresAt) {
		return ErrExpired
	}
	return nil
}

// Rotate replaces the refresh token, keeps the old hash to recognise a
// replay, and returns the new token.
func (s *Session) Rotate(now time.Time) string {
	refresh, hash := token.NewRefresh()
	s.prevRefreshHash, s.refreshHash, s.lastUsedAt = s.refreshHash, hash, now
	return refresh
}

// Revoke signs the session out; a second call keeps the first time.
func (s *Session) Revoke(now time.Time) {
	if s.revokedAt == nil {
		s.revokedAt = &now
	}
}

// SetVersion moves the session to the member's new credentials version,
// which keeps it alive through its own member's password change.
func (s *Session) SetVersion(v int) { s.credentialsVersion = v }

// Grant is what staff.Require reads about a session and its member.
type Grant struct {
	Role      member.Role
	Active    bool // the member is active
	Current   bool // the session's credentials version is the member's
	RevokedAt *time.Time
	ExpiresAt time.Time
}

// Check returns nil while the grant lets a request through at now.
func (g Grant) Check(now time.Time) error {
	switch {
	case g.RevokedAt != nil || !g.Active || !g.Current:
		return ErrRevoked
	case !now.Before(g.ExpiresAt):
		return ErrExpired
	default:
		return nil
	}
}
```

- [ ] **Step 4: Write the store**

Create `internal/staff/session/store.go`:

```go
package session

import (
	"context"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
)

// Store persists staff sessions. Each method is its own transaction.
type Store interface {
	// CreateAudited inserts s and writes e.
	CreateAudited(ctx context.Context, s Session, e audit.Entry) error
	Get(ctx context.Context, id uuid.UUID) (Session, error)
	FindByRefresh(ctx context.Context, hash []byte) (Session, error)
	FindByPrevRefresh(ctx context.Context, hash []byte) (Session, error)
	// Save writes s when its row still has s's write ID or already has
	// writeID. Otherwise ErrConflict.
	Save(ctx context.Context, s *Session, writeID uuid.UUID) error
	// SaveAudited is Save that writes e in the same transaction.
	SaveAudited(ctx context.Context, s *Session, writeID uuid.UUID, e audit.Entry) error
	// Grant is a query joining the session with its member. ErrNotFound when
	// the session does not exist or is not staffID's.
	Grant(ctx context.Context, id, staffID uuid.UUID) (Grant, error)
}
```

Create `internal/staff/session/store_pg.go`:

```go
package session

import (
	"context"
	"errors"
	"fmt"
	"net/netip"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/audit"
)

type pgStore struct{ db *pgxpool.Pool }

func NewPGStore(db *pgxpool.Pool) Store { return pgStore{db} }

const columns = `id, staff_id, refresh_hash, prev_refresh_hash, credentials_version, ip, user_agent,
       created_at, last_used_at, expires_at, revoked_at, write_id`

func scan(row pgx.Row) (Session, error) {
	var (
		s  Session
		ip netip.Prefix
	)
	err := row.Scan(&s.id, &s.staffID, &s.refreshHash, &s.prevRefreshHash, &s.credentialsVersion, &ip, &s.userAgent,
		&s.createdAt, &s.lastUsedAt, &s.expiresAt, &s.revokedAt, &s.writeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Session{}, ErrNotFound
	}
	if err != nil {
		return Session{}, fmt.Errorf("select staff session: %w", err)
	}
	s.ip = ip.Addr()
	return s, nil
}

const insertSession = `
INSERT INTO staff_sessions (` + columns + `)
VALUES (@id, @staff_id, @refresh_hash, NULL, @credentials_version, @ip, @user_agent,
        @created_at, @created_at, @expires_at, NULL, @write_id)`

func (st pgStore) CreateAudited(ctx context.Context, s Session, e audit.Entry) error {
	err := pgx.BeginFunc(ctx, st.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, insertSession, pgx.StrictNamedArgs{
			"id": s.id, "staff_id": s.staffID, "refresh_hash": s.refreshHash, "credentials_version": s.credentialsVersion,
			"ip": s.ip, "user_agent": s.userAgent, "created_at": s.createdAt, "expires_at": s.expiresAt, "write_id": s.writeID,
		}); err != nil {
			return fmt.Errorf("insert staff session: %w", err)
		}
		return audit.Insert(ctx, tx, e)
	})
	if err != nil {
		return fmt.Errorf("create staff session: %w", err)
	}
	return nil
}

func (st pgStore) Get(ctx context.Context, id uuid.UUID) (Session, error) {
	return scan(st.db.QueryRow(ctx, `SELECT `+columns+` FROM staff_sessions WHERE id = @id`, pgx.StrictNamedArgs{"id": id}))
}

func (st pgStore) FindByRefresh(ctx context.Context, hash []byte) (Session, error) {
	return scan(st.db.QueryRow(ctx, `SELECT `+columns+` FROM staff_sessions WHERE refresh_hash = @hash`, pgx.StrictNamedArgs{"hash": hash}))
}

func (st pgStore) FindByPrevRefresh(ctx context.Context, hash []byte) (Session, error) {
	return scan(st.db.QueryRow(ctx, `SELECT `+columns+` FROM staff_sessions WHERE prev_refresh_hash = @hash LIMIT 1`,
		pgx.StrictNamedArgs{"hash": hash}))
}

const saveSession = `
UPDATE staff_sessions
SET refresh_hash = @refresh_hash, prev_refresh_hash = @prev_refresh_hash, credentials_version = @credentials_version,
    last_used_at = @last_used_at, revoked_at = @revoked_at, write_id = @write_id
WHERE id = @id AND (write_id = @read_write_id OR write_id = @write_id)`

type execer interface {
	Exec(ctx context.Context, sql string, args ...any) (pgconn.CommandTag, error)
}

func update(ctx context.Context, q execer, s *Session, writeID uuid.UUID) error {
	tag, err := q.Exec(ctx, saveSession, pgx.StrictNamedArgs{
		"id": s.id, "read_write_id": s.writeID, "write_id": writeID, "refresh_hash": s.refreshHash,
		"prev_refresh_hash": s.prevRefreshHash, "credentials_version": s.credentialsVersion,
		"last_used_at": s.lastUsedAt, "revoked_at": s.revokedAt,
	})
	if err != nil {
		return fmt.Errorf("update staff session: %w", err)
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	return nil
}

func (st pgStore) Save(ctx context.Context, s *Session, writeID uuid.UUID) error {
	if err := update(ctx, st.db, s, writeID); err != nil {
		return err
	}
	s.writeID = writeID
	return nil
}

func (st pgStore) SaveAudited(ctx context.Context, s *Session, writeID uuid.UUID, e audit.Entry) error {
	err := pgx.BeginFunc(ctx, st.db, func(tx pgx.Tx) error {
		if err := update(ctx, tx, s, writeID); err != nil {
			return err
		}
		return audit.Insert(ctx, tx, e)
	})
	if err != nil {
		return fmt.Errorf("save staff session with audit: %w", err)
	}
	s.writeID = writeID
	return nil
}

const grant = `
SELECT m.role, m.status = 'active', s.credentials_version = m.credentials_version, s.revoked_at, s.expires_at
FROM staff_sessions s
JOIN staff_members m ON m.id = s.staff_id
WHERE s.id = @id AND s.staff_id = @staff_id`

func (st pgStore) Grant(ctx context.Context, id, staffID uuid.UUID) (Grant, error) {
	var g Grant
	err := st.db.QueryRow(ctx, grant, pgx.StrictNamedArgs{"id": id, "staff_id": staffID}).
		Scan(&g.Role, &g.Active, &g.Current, &g.RevokedAt, &g.ExpiresAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Grant{}, ErrNotFound
	}
	if err != nil {
		return Grant{}, fmt.Errorf("select staff grant: %w", err)
	}
	return g, nil
}
```

- [ ] **Step 5: Run the session tests**

Run: `go test ./internal/staff/session/`
Expected: `ok`.

- [ ] **Step 6: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/staff/session
git commit -m "feat: staff sessions

staff/session holds a sign-in that lasts eight hours with a refresh token
that rotates, the credentials version it was issued at, and the client's
address and user agent. Grant reads a session with its member in one query
for the middleware: a revoked session, a disabled member or a moved
credentials version ends it.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 9: Sign-in

**Files:**
- Create in `internal/staff/`: `keys.go`, `errors.go`, `views.go`, `ticket.go`, `cookie.go`, `stores.go`, `login.go`, `login_password.go`, `login_totp.go`, `member_create.go`, `mount.go`, `helpers_test.go`, `login_test.go`
- Create: `e2e/staff_helpers_test.go`, `e2e/staff_login_test.go`
- Modify: `api/openapi.yaml`, `internal/app/app.go`, `e2e/main_test.go`

**Interfaces:**
- Consumes: Tasks 2 to 8.
- Produces:
  - `staff.AudienceStaff = "shopnexus-staff"`, `staff.AudienceLogin = "shopnexus-staff-login"`, `staff.TicketTTL = 5 * time.Minute`
  - `staff.Hasher` (alias of `member.Hasher`), `staff.ProductionHasher`, `staff.FastHasher`
  - `staff.Keys{Secrets cipher.AEAD; Quota []byte; Hasher Hasher; Signer token.Signer; Verifier token.Verifier}`, `staff.NewKeys(config.StaffConfig, config.AuthConfig, Hasher) (Keys, error)`
  - `staff.Stores{Members member.Store; Quotas quota.Store; Sessions session.Store; Actions audit.Store}`, `staff.NewStores(*pgxpool.Pool, Keys) Stores`
  - Errors: `ErrLoginLocked` (429 `login_locked`, `details.retry_after`), `ErrInvalidLoginTicket` (401), `ErrStaffForbidden` (403 `staff_forbidden`)
  - Views: `Me`, `MemberView`, `LoginStep`, `SignIn`, `Access`, `Enrollment`; `meOf(member.Member) Me`, `viewOf(member.Member, *time.Time) MemberView`
  - `issued{refresh string; expiresAt time.Time}`, `setRefreshCookie(w, issued, now)`, `clearRefreshCookie(w)`
  - `staff.SignedIn{SignIn SignIn}` with `RefreshToken() string`, returned by `VerifyTOTP`
  - Use cases: `Login`, `ChangeTemporaryPassword`, `EnrollTOTP`, `VerifyTOTP`, `CreateMember` (signatures in the steps); `fail(ctx, quotas, key, by, target, refusal, now) error`
  - `staff.Settings{Keys Keys; TrustedProxies []netip.Prefix}`, `staff.Mount(module.Deps, Settings)`
  - `app.WithPasswordHasher(staff.Hasher) Option`

- [ ] **Step 1: Write the keys, errors and views**

Create `internal/staff/keys.go`:

```go
package staff

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"fmt"
	"time"

	"github.com/shopnexus/server2/internal/platform/config"
	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff/member"
)

const (
	AudienceStaff = "shopnexus-staff"
	AudienceLogin = "shopnexus-staff-login"
	TicketTTL     = 5 * time.Minute
)

// Hasher is member.Hasher, so app and tests pick one without importing
// package member.
type Hasher = member.Hasher

var (
	ProductionHasher = member.Production
	FastHasher       = member.Fast
)

// Keys is what staff signs, seals and hashes with.
type Keys struct {
	Secrets  cipher.AEAD // seals TOTP secrets at rest
	Quota    []byte      // the HMAC key of login quota keys
	Hasher   Hasher
	Signer   token.Signer
	Verifier token.Verifier
	dummy    string // a hash no password matches, verified for unknown emails
}

// NewKeys derives the TOTP sealing key and the quota HMAC key from
// STAFF_KEY with HKDF, under different labels, and signs with the auth JWT
// key under the staff audiences.
func NewKeys(staffCfg config.StaffConfig, authCfg config.AuthConfig, h Hasher) (Keys, error) {
	sealKey, err := hkdf.Key(sha256.New, staffCfg.Key, nil, "shopnexus staff totp secrets", 32)
	if err != nil {
		return Keys{}, fmt.Errorf("derive the totp key: %w", err)
	}
	quotaKey, err := hkdf.Key(sha256.New, staffCfg.Key, nil, "shopnexus staff login quota", 32)
	if err != nil {
		return Keys{}, fmt.Errorf("derive the quota key: %w", err)
	}
	block, err := aes.NewCipher(sealKey)
	if err != nil {
		return Keys{}, fmt.Errorf("totp cipher: %w", err)
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return Keys{}, fmt.Errorf("totp cipher: %w", err)
	}
	return Keys{
		Secrets: aead, Quota: quotaKey, Hasher: h,
		Signer: token.NewSigner(authCfg), Verifier: token.NewVerifier(authCfg), dummy: h.Hash(rand.Text()),
	}, nil
}
```

Create `internal/staff/errors.go`:

```go
package staff

import (
	"math"
	"time"

	"github.com/shopnexus/server2/internal/platform/apperr"
)

var (
	ErrLoginLocked        = apperr.New(apperr.KindRateLimited, "login_locked", "too many failed sign-ins on this email; wait and try again")
	ErrInvalidLoginTicket = apperr.New(apperr.KindUnauthenticated, "invalid_login_ticket", "the sign-in ticket is not valid; start again")
	ErrStaffForbidden     = apperr.New(apperr.KindForbidden, "staff_forbidden", "your role cannot do this")
)

func locked(wait time.Duration) error {
	return ErrLoginLocked.WithDetail("retry_after", int(math.Ceil(wait.Seconds())))
}
```

Create `internal/staff/views.go`:

```go
package staff

import (
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/staff/member"
)

// Me is the Me schema in api/schemas/staff.yaml.
type Me struct {
	ID          uuid.UUID   `json:"id"`
	Email       string      `json:"email"`
	DisplayName string      `json:"display_name"`
	Role        member.Role `json:"role"`
}

func meOf(m member.Member) Me {
	return Me{ID: m.ID(), Email: m.Email(), DisplayName: m.DisplayName(), Role: m.Role()}
}

// MemberView is the Member schema. It is also what an audit diff of a member
// shows, so it holds no secret.
type MemberView struct {
	ID           uuid.UUID     `json:"id"`
	Email        string        `json:"email"`
	DisplayName  string        `json:"display_name"`
	Role         member.Role   `json:"role"`
	Status       member.Status `json:"status"`
	TOTPEnrolled bool          `json:"totp_enrolled"`
	LockedUntil  *time.Time    `json:"locked_until,omitempty"`
	CreatedAt    time.Time     `json:"created_at"`
}

func viewOf(m member.Member, lockedUntil *time.Time) MemberView {
	return MemberView{
		ID: m.ID(), Email: m.Email(), DisplayName: m.DisplayName(), Role: m.Role(), Status: m.Status(),
		TOTPEnrolled: m.Enrolled(), LockedUntil: lockedUntil, CreatedAt: m.CreatedAt(),
	}
}

// LoginStep is the LoginStep schema.
type LoginStep struct {
	Ticket          string      `json:"ticket"`
	Next            member.Step `json:"next"`
	TicketExpiresAt time.Time   `json:"ticket_expires_at"`
}

// SignIn is the StaffSignIn schema.
type SignIn struct {
	AccessToken          string    `json:"access_token"`
	AccessTokenExpiresAt time.Time `json:"access_token_expires_at"`
	TokenType            string    `json:"token_type"`
	Staff                Me        `json:"staff"`
}

// Access is the StaffAccess schema.
type Access struct {
	AccessToken          string    `json:"access_token"`
	AccessTokenExpiresAt time.Time `json:"access_token_expires_at"`
	TokenType            string    `json:"token_type"`
}

// Enrollment is the TOTPEnrollment schema.
type Enrollment struct {
	Secret     string `json:"secret"`
	OTPAuthURI string `json:"otpauth_uri"`
}
```

- [ ] **Step 2: Write the ticket, the cookie and the stores**

Create `internal/staff/ticket.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff/member"
)

// issueTicket signs a login ticket at the member's credentials version and
// names the member's next step.
func issueTicket(k Keys, m *member.Member, now time.Time) (LoginStep, error) {
	t, exp, err := k.Signer.Sign(token.Claims{
		Subject: m.ID(), SessionID: uuid.UUID{}, AuthTime: time.Time{}, Version: m.CredentialsVersion(),
		Audience: AudienceLogin, ExpiresAt: time.Time{},
	}, TicketTTL, now)
	if err != nil {
		return LoginStep{}, fmt.Errorf("sign login ticket: %w", err)
	}
	return LoginStep{Ticket: t, Next: m.Next(), TicketExpiresAt: exp}, nil
}

// readTicket returns the member a ticket names while the member is active
// and the ticket carries their current credentials version. A password
// change, a reset or a disable since the ticket was issued ends it.
func readTicket(ctx context.Context, members member.Store, k Keys, ticket string, now time.Time) (member.Member, error) {
	c, err := k.Verifier.Verify(ticket, AudienceLogin, now)
	if err != nil {
		return member.Member{}, ErrInvalidLoginTicket
	}
	m, err := members.Get(ctx, c.Subject)
	if errors.Is(err, member.ErrNotFound) {
		return member.Member{}, ErrInvalidLoginTicket
	}
	if err != nil {
		return member.Member{}, fmt.Errorf("get staff member: %w", err)
	}
	if m.Status() != member.StatusActive || m.CredentialsVersion() != c.Version {
		return member.Member{}, ErrInvalidLoginTicket
	}
	return m, nil
}
```

Create `internal/staff/cookie.go`:

```go
package staff

import (
	"net/http"
	"time"
)

const (
	refreshCookie = "staff_refresh"
	// The browser sends the cookie to the refresh and logout endpoints only.
	cookiePath = "/v1/staff/session"
)

// issued is a refresh token and the end of its session, for the cookie.
type issued struct {
	refresh   string
	expiresAt time.Time
}

func setRefreshCookie(w http.ResponseWriter, i issued, now time.Time) {
	http.SetCookie(w, &http.Cookie{
		Name: refreshCookie, Value: i.refresh, Path: cookiePath, MaxAge: int(i.expiresAt.Sub(now).Seconds()),
		Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode,
	})
}

func clearRefreshCookie(w http.ResponseWriter) {
	http.SetCookie(w, &http.Cookie{
		Name: refreshCookie, Value: "", Path: cookiePath, MaxAge: -1,
		Secure: true, HttpOnly: true, SameSite: http.SameSiteStrictMode,
	})
}
```

Create `internal/staff/stores.go`:

```go
package staff

import (
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/quota"
	"github.com/shopnexus/server2/internal/staff/session"
)

// Stores is every adapter staff uses. Mount, cmd/staff and the e2e tests
// build them the same way.
type Stores struct {
	Members  member.Store
	Quotas   quota.Store
	Sessions session.Store
	Actions  audit.Store
}

func NewStores(db *pgxpool.Pool, k Keys) Stores {
	return Stores{
		Members: member.NewPGStore(db, k.Secrets), Quotas: quota.NewPGStore(db),
		Sessions: session.NewPGStore(db), Actions: audit.NewPGStore(db),
	}
}
```

- [ ] **Step 3: Write the failing use case tests**

Create `internal/staff/helpers_test.go`:

```go
package staff_test

import (
	"context"
	"net/netip"
	"testing"
	"time"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/config"
	"github.com/shopnexus/server2/internal/platform/pgtest"
	"github.com/shopnexus/server2/internal/staff"
	"github.com/shopnexus/server2/internal/staff/member"
)

var (
	now      = time.Date(2026, 10, 24, 9, 0, 0, 0, time.UTC)
	clientIP = netip.MustParseAddr("203.0.113.7")
)

type env struct {
	db     *pgxpool.Pool
	keys   staff.Keys
	stores staff.Stores
}

func newEnv(t *testing.T) env {
	t.Helper()
	auth := config.NewAuthKeys()
	auth.Issuer, auth.Audience = "server2-test", "shopnexus-app-test"
	k, err := staff.NewKeys(config.StaffConfig{Key: config.NewStaffKey(), ConsoleOrigin: "http://console.test"}, auth, staff.FastHasher)
	if err != nil {
		t.Fatal(err)
	}
	db := pgtest.New(t)
	return env{db: db, keys: k, stores: staff.NewStores(db, k)}
}

// sessionOf reads the session ID from a sign-in's access token.
func (e env) sessionOf(t *testing.T, in staff.SignedIn) uuid.UUID {
	t.Helper()
	c, err := e.keys.Verifier.Verify(in.SignIn.AccessToken, staff.AudienceStaff, now)
	if err != nil {
		t.Fatal(err)
	}
	return c.SessionID
}

// callerOf is the authn.Staff that staff.Require would put in the context.
func (e env) callerOf(t *testing.T, in staff.SignedIn) authn.Staff {
	t.Helper()
	return authn.Staff{StaffID: in.SignIn.Staff.ID, SessionID: e.sessionOf(t, in), Role: string(in.SignIn.Staff.Role), IP: clientIP}
}

// create makes a member and returns its view and temporary password.
func (e env) create(t *testing.T, email string, role member.Role) (staff.MemberView, string) {
	t.Helper()
	v, temp, err := staff.CreateMember(context.Background(), e.stores.Members, e.keys.Hasher, email, "Mod One", role, audit.ByCLI("test"), now)
	if err != nil {
		t.Fatal(err)
	}
	return v, temp
}

// enrolled makes a member that has changed its password, enrolled TOTP and
// signed in at now, and returns the password, the secret and the sign-in.
func (e env) enrolled(t *testing.T, email string, role member.Role) (password string, secret []byte, in staff.SignedIn) {
	t.Helper()
	ctx := context.Background()
	_, temp := e.create(t, email, role)
	step, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, email, temp, clientIP, now)
	if err != nil {
		t.Fatal(err)
	}
	password = "a long staff password"
	if step, err = staff.ChangeTemporaryPassword(ctx, e.stores.Members, e.keys, step.Ticket, password, clientIP, now); err != nil {
		t.Fatal(err)
	}
	enr, err := staff.EnrollTOTP(ctx, e.stores.Members, e.keys, step.Ticket, now)
	if err != nil {
		t.Fatal(err)
	}
	secret = decodeSecret(t, enr.Secret)
	if in, err = staff.VerifyTOTP(ctx, e.stores, e.keys, step.Ticket, member.Code(secret, now), clientIP, "test", now); err != nil {
		t.Fatal(err)
	}
	return password, secret, in
}
```

Add `decodeSecret` to the same file:

```go
func decodeSecret(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
```

The file imports `encoding/base32`, `uuid`, `github.com/jackc/pgx/v5/pgxpool` and `github.com/shopnexus/server2/internal/platform/authn` besides the ones shown. `staff.VerifyTOTP` takes the `Stores` because it touches members, quotas and sessions.

Create `internal/staff/login_test.go`:

```go
package staff_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/staff"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/quota"
)

func TestFirstSignInSteps(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	_, temp := e.create(t, "first@example.com", member.RoleModerator)
	step, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "first@example.com", temp, clientIP, now)
	if err != nil || step.Next != member.StepChangePassword || !step.TicketExpiresAt.Equal(now.Add(staff.TicketTTL)) {
		t.Fatalf("%+v %v", step, err)
	}
	if _, err := staff.EnrollTOTP(ctx, e.stores.Members, e.keys, step.Ticket, now); !errors.Is(err, staff.ErrInvalidLoginTicket) {
		t.Fatalf("enrolling before the password: %v", err)
	}
	if _, err := staff.ChangeTemporaryPassword(ctx, e.stores.Members, e.keys, step.Ticket, "short", clientIP, now); !errors.Is(err, member.ErrPasswordTooWeak) {
		t.Fatalf("weak password: %v", err)
	}
	if _, err := staff.ChangeTemporaryPassword(ctx, e.stores.Members, e.keys, step.Ticket, temp, clientIP, now); !errors.Is(err, member.ErrPasswordTooWeak) {
		t.Fatalf("the temporary password again: %v", err)
	}
	next, err := staff.ChangeTemporaryPassword(ctx, e.stores.Members, e.keys, step.Ticket, "a long staff password", clientIP, now)
	if err != nil || next.Next != member.StepEnrollTOTP {
		t.Fatalf("%+v %v", next, err)
	}
	if _, err := staff.EnrollTOTP(ctx, e.stores.Members, e.keys, step.Ticket, now); !errors.Is(err, staff.ErrInvalidLoginTicket) {
		t.Fatalf("the ticket from before the change: %v", err)
	}
	if _, err := staff.VerifyTOTP(ctx, e.stores, e.keys, next.Ticket, "123456", clientIP, "test", now); !errors.Is(err, staff.ErrInvalidLoginTicket) {
		t.Fatalf("a code before enrollment started: %v", err)
	}
	enr, err := staff.EnrollTOTP(ctx, e.stores.Members, e.keys, next.Ticket, now)
	if err != nil {
		t.Fatal(err)
	}
	secret := decodeSecret(t, enr.Secret)
	out, err := staff.VerifyTOTP(ctx, e.stores, e.keys, next.Ticket, member.Code(secret, now), clientIP, "test", now)
	if err != nil || out.SignIn.Staff.Email != "first@example.com" || out.SignIn.TokenType != "Bearer" ||
		!out.SignIn.AccessTokenExpiresAt.Equal(now.Add(5*time.Minute)) {
		t.Fatalf("%+v %v", out, err)
	}
	claims, err := e.keys.Verifier.Verify(out.SignIn.AccessToken, staff.AudienceStaff, now)
	if err != nil || claims.SessionID == (uuid.UUID{}) {
		t.Fatalf("access token: %+v %v", claims, err)
	}
	if _, err := staff.VerifyTOTP(ctx, e.stores, e.keys, next.Ticket, member.Code(secret, now), clientIP, "test", now); !errors.Is(err, member.ErrInvalidTOTPCode) {
		t.Fatalf("the same code twice: %v", err)
	}
}

func TestLoginRefusesAlike(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	v, temp := e.create(t, "known@example.com", member.RoleModerator)
	for name, try := range map[string][2]string{
		"unknown email":  {"nobody@example.com", temp},
		"wrong password": {"known@example.com", temp + "x"},
	} {
		if _, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, try[0], try[1], clientIP, now); !errors.Is(err, member.ErrInvalidCredentials) {
			t.Errorf("%s: %v", name, err)
		}
	}
	m, _ := e.stores.Members.Get(ctx, v.ID)
	m.Disable(now)
	if err := e.stores.Members.Save(ctx, &m, uuid.NewV7()); err != nil {
		t.Fatal(err)
	}
	if _, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "known@example.com", temp, clientIP, now); !errors.Is(err, member.ErrInvalidCredentials) {
		t.Fatalf("disabled: %v", err)
	}
}

func TestUnknownEmailLocksLikeAKnownOne(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	_, temp := e.create(t, "known@example.com", member.RoleModerator)
	for _, email := range []string{"known@example.com", "nobody@example.com"} {
		for range quota.MaxFailures {
			_, _ = staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, email, "wrong password", clientIP, now)
		}
		_, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, email, temp, clientIP, now.Add(time.Minute))
		if !errors.Is(err, staff.ErrLoginLocked) {
			t.Fatalf("%s: %v", email, err)
		}
	}
	if _, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "known@example.com", temp, clientIP, now.Add(quota.LockFor)); err != nil {
		t.Fatalf("after the lock: %v", err)
	}
}

func TestLoginNormalisesTheEmail(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	_, temp := e.create(t, "admin@example.com", member.RoleAdmin)
	if _, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, " Admin@Example.COM ", temp, clientIP, now); err != nil {
		t.Fatal(err)
	}
	for range quota.MaxFailures {
		_, _ = staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "ADMIN@example.com", "wrong password", clientIP, now)
	}
	if _, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "admin@example.com", temp, clientIP, now); !errors.Is(err, staff.ErrLoginLocked) {
		t.Fatalf("another spelling locked a different row: %v", err)
	}
}

func TestLoginCountsConcurrentFailures(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	start := make(chan struct{})
	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() {
			<-start
			_, _ = staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "race@example.com", "wrong password", clientIP, now)
		})
	}
	close(start)
	wg.Wait()
	q, err := e.stores.Quotas.Get(ctx, quota.Key(e.keys.Quota, "race@example.com"))
	if err != nil || q.Failures() != 4 {
		t.Fatalf("failures %d, want 4: %v", q.Failures(), err)
	}
}

func TestWrongCodesLock(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	password, secret, _ := e.enrolled(t, "codes@example.com", member.RoleModerator)
	later := now.Add(time.Minute)
	step, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "codes@example.com", password, clientIP, later)
	if err != nil || step.Next != member.StepTOTP {
		t.Fatalf("%+v %v", step, err)
	}
	good := member.Code(secret, later)
	bad := good[:5] + string(rune('0'+(good[5]-'0'+1)%10))
	for range quota.MaxFailures {
		if _, err := staff.VerifyTOTP(ctx, e.stores, e.keys, step.Ticket, bad, clientIP, "test", later); !errors.Is(err, member.ErrInvalidTOTPCode) {
			t.Fatalf("a wrong code: %v", err)
		}
	}
	if _, err := staff.VerifyTOTP(ctx, e.stores, e.keys, step.Ticket, good, clientIP, "test", later); !errors.Is(err, staff.ErrLoginLocked) {
		t.Fatalf("the right code while locked: %v", err)
	}
}
```

- [ ] **Step 4: Run them to see them fail**

Run: `go test ./internal/staff/`
Expected: FAIL, `undefined: staff.Login`.

- [ ] **Step 5: Write `Login` and `fail`**

Create `internal/staff/login.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/quota"
)

type LoginRequest struct {
	Email    string `json:"email"`
	Password string `json:"password"`
}

// Login checks an email and password and returns the next sign-in step. An
// unknown email, a wrong password and a disabled member fail alike, and an
// unknown email still costs one argon2 verification, so the response time
// does not tell them apart either. A correct password does not clear the
// failure count; only a finished sign-in does.
func Login(ctx context.Context, members member.Store, quotas quota.Store, k Keys, email, password string, ip netip.Addr, now time.Time) (LoginStep, error) {
	email = member.NormalizeEmail(email)
	key := quota.Key(k.Quota, email)
	q, err := quotas.Get(ctx, key)
	if err != nil {
		return LoginStep{}, fmt.Errorf("get login quota: %w", err)
	}
	if wait, isLocked := q.Locked(now); isLocked {
		return LoginStep{}, locked(wait)
	}
	m, err := members.FindByEmail(ctx, email)
	if errors.Is(err, member.ErrNotFound) {
		member.VerifyPassword(k.dummy, password)
		return LoginStep{}, fail(ctx, quotas, key, audit.Anonymous(ip), audit.Target{Kind: "", ID: uuid.UUID{}}, member.ErrInvalidCredentials, now)
	}
	if err != nil {
		return LoginStep{}, fmt.Errorf("find staff member: %w", err)
	}
	if !member.VerifyPassword(m.PasswordHash(), password) || m.Status() != member.StatusActive {
		return LoginStep{}, fail(ctx, quotas, key, audit.Anonymous(ip), audit.Staff(m.ID()), member.ErrInvalidCredentials, now)
	}
	return issueTicket(k, &m, now)
}

// fail counts a failed sign-in on key, records staff.login_failed, or
// staff.login_locked for the failure that locks, and returns refusal. A save
// that loses a race reads the quota again, so concurrent failures all count.
func fail(ctx context.Context, quotas quota.Store, key []byte, by audit.Actor, target audit.Target, refusal error, now time.Time) error {
	for range 5 {
		q, err := quotas.Get(ctx, key)
		if err != nil {
			return fmt.Errorf("get login quota: %w", err)
		}
		action := "staff.login_failed"
		if q.Fail(now) {
			action = "staff.login_locked"
		}
		err = quotas.SaveAudited(ctx, &q, uuid.NewV7(), audit.Entry{Actor: by, Action: action, Target: target, Diff: nil, At: now})
		if err == nil {
			return refusal
		}
		if !errors.Is(err, quota.ErrConflict) {
			return fmt.Errorf("save login quota: %w", err)
		}
	}
	return apperr.ErrTryAgain
}

// LoginHandler serves POST /v1/staff/login.
func LoginHandler(members member.Store, quotas quota.Store, k Keys, trusted []netip.Prefix, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in LoginRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		step, err := Login(r.Context(), members, quotas, k, in.Email, in.Password, httpx.ClientIP(r, trusted), now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, step)
	})
}
```

- [ ] **Step 6: Write the password step**

Create `internal/staff/login_password.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/staff/member"
)

type LoginPasswordRequest struct {
	Ticket      string `json:"ticket"`
	NewPassword string `json:"new_password"`
}

// ChangeTemporaryPassword replaces the temporary password of the member a
// ticket names and returns a ticket at the new credentials version.
func ChangeTemporaryPassword(ctx context.Context, members member.Store, k Keys, ticket, newPassword string, ip netip.Addr, now time.Time) (LoginStep, error) {
	m, err := readTicket(ctx, members, k, ticket, now)
	if err != nil {
		return LoginStep{}, err
	}
	if m.Next() != member.StepChangePassword {
		return LoginStep{}, ErrInvalidLoginTicket
	}
	if policyErr := member.CheckPolicy(newPassword, m.Email()); policyErr != nil {
		return LoginStep{}, policyErr
	}
	if member.VerifyPassword(m.PasswordHash(), newPassword) {
		return LoginStep{}, member.ErrPasswordTooWeak
	}
	m.SetPassword(k.Hasher.Hash(newPassword), now)
	err = members.SaveAudited(ctx, &m, uuid.NewV7(), audit.Entry{
		Actor: audit.BySignIn(m.ID(), ip), Action: "staff.password_change", Target: audit.Staff(m.ID()),
		Diff: map[string]any{"password": "changed"}, At: now,
	})
	if errors.Is(err, member.ErrConflict) {
		return LoginStep{}, apperr.ErrTryAgain
	}
	if err != nil {
		return LoginStep{}, fmt.Errorf("save staff member: %w", err)
	}
	return issueTicket(k, &m, now)
}

// ChangeTemporaryPasswordHandler serves POST /v1/staff/login/password.
func ChangeTemporaryPasswordHandler(members member.Store, k Keys, trusted []netip.Prefix, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in LoginPasswordRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		step, err := ChangeTemporaryPassword(r.Context(), members, k, in.Ticket, in.NewPassword, httpx.ClientIP(r, trusted), now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, step)
	})
}
```

- [ ] **Step 7: Write the TOTP steps**

Create `internal/staff/login_totp.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/quota"
	"github.com/shopnexus/server2/internal/staff/session"
)

type TicketRequest struct {
	Ticket string `json:"ticket"`
}

type LoginTOTPRequest struct {
	Ticket    string `json:"ticket"`
	Code      string `json:"code"`
	UserAgent string `header:"User-Agent" json:"-"`
}

// EnrollTOTP gives the member a ticket names a fresh secret to enroll; a
// second call replaces it.
func EnrollTOTP(ctx context.Context, members member.Store, k Keys, ticket string, now time.Time) (Enrollment, error) {
	m, err := readTicket(ctx, members, k, ticket, now)
	if err != nil {
		return Enrollment{}, err
	}
	if m.Next() != member.StepEnrollTOTP {
		return Enrollment{}, ErrInvalidLoginTicket
	}
	secret := member.NewTOTPSecret()
	m.StartEnrollment(secret, now)
	err = members.Save(ctx, &m, uuid.NewV7())
	if errors.Is(err, member.ErrConflict) {
		return Enrollment{}, apperr.ErrTryAgain
	}
	if err != nil {
		return Enrollment{}, fmt.Errorf("save staff member: %w", err)
	}
	return Enrollment{Secret: member.EncodeSecret(secret), OTPAuthURI: member.TOTPURI(secret, m.Email())}, nil
}

// SignedIn is what a finished sign-in returns: the response body and the
// refresh token for the cookie.
type SignedIn struct {
	SignIn SignIn
	cookie issued
}

// RefreshToken is the token the cookie carries; tests read it.
func (s SignedIn) RefreshToken() string { return s.cookie.refresh }

// VerifyTOTP finishes sign-in with a code. A wrong code counts toward the
// email's lock; a right one confirms a pending enrollment, clears the
// failures and starts a session recorded as staff.login.
func VerifyTOTP(ctx context.Context, st Stores, k Keys, ticket, code string, ip netip.Addr, userAgent string, now time.Time) (SignedIn, error) {
	m, err := readTicket(ctx, st.Members, k, ticket, now)
	if err != nil {
		return SignedIn{}, err
	}
	if step := m.Next(); step == member.StepChangePassword || (step == member.StepEnrollTOTP && !m.Enrolling()) {
		return SignedIn{}, ErrInvalidLoginTicket
	}
	key := quota.Key(k.Quota, m.Email())
	q, err := st.Quotas.Get(ctx, key)
	if err != nil {
		return SignedIn{}, fmt.Errorf("get login quota: %w", err)
	}
	if wait, isLocked := q.Locked(now); isLocked {
		return SignedIn{}, locked(wait)
	}
	enrolling := !m.Enrolled()
	if codeErr := m.AcceptCode(code, now); codeErr != nil {
		return SignedIn{}, fail(ctx, st.Quotas, key, audit.BySignIn(m.ID(), ip), audit.Staff(m.ID()), member.ErrInvalidTOTPCode, now)
	}
	// Saving the accepted step is what stops the code working twice.
	if enrolling {
		err = st.Members.SaveAudited(ctx, &m, uuid.NewV7(), audit.Entry{
			Actor: audit.BySignIn(m.ID(), ip), Action: "staff.totp_enroll", Target: audit.Staff(m.ID()),
			Diff: map[string]any{"totp": "enrolled"}, At: now,
		})
	} else {
		err = st.Members.Save(ctx, &m, uuid.NewV7())
	}
	if errors.Is(err, member.ErrConflict) {
		return SignedIn{}, apperr.ErrTryAgain
	}
	if err != nil {
		return SignedIn{}, fmt.Errorf("save staff member: %w", err)
	}
	if q.Failures() > 0 {
		q.Clear(now)
		if clearErr := st.Quotas.Save(ctx, &q, uuid.NewV7()); clearErr != nil && !errors.Is(clearErr, quota.ErrConflict) {
			return SignedIn{}, fmt.Errorf("clear login quota: %w", clearErr)
		}
	}
	s, refresh := session.New(uuid.NewV7(), m.ID(), m.CredentialsVersion(), ip, userAgent, now)
	err = st.Sessions.CreateAudited(ctx, s, audit.Entry{
		Actor:  audit.Actor{Kind: audit.ActorStaff, StaffID: m.ID(), SessionID: s.ID(), Name: "", IP: ip},
		Action: "staff.login", Target: audit.Staff(m.ID()), Diff: nil, At: now,
	})
	if err != nil {
		return SignedIn{}, fmt.Errorf("create staff session: %w", err)
	}
	access, exp, err := k.Signer.Sign(token.Claims{
		Subject: m.ID(), SessionID: s.ID(), AuthTime: now, Version: 0, Audience: AudienceStaff, ExpiresAt: time.Time{},
	}, session.AccessTTL, now)
	if err != nil {
		return SignedIn{}, fmt.Errorf("sign staff access token: %w", err)
	}
	return SignedIn{
		SignIn: SignIn{AccessToken: access, AccessTokenExpiresAt: exp, TokenType: "Bearer", Staff: meOf(m)},
		cookie: issued{refresh: refresh, expiresAt: s.ExpiresAt()},
	}, nil
}

// EnrollTOTPHandler serves POST /v1/staff/login/totp-enrollment.
func EnrollTOTPHandler(members member.Store, k Keys, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in TicketRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		enr, err := EnrollTOTP(r.Context(), members, k, in.Ticket, now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, enr)
	})
}

// VerifyTOTPHandler serves POST /v1/staff/login/totp and sets the refresh
// cookie.
func VerifyTOTPHandler(st Stores, k Keys, trusted []netip.Prefix, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in LoginTOTPRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		t := now()
		out, err := VerifyTOTP(r.Context(), st, k, in.Ticket, in.Code, httpx.ClientIP(r, trusted), in.UserAgent, t)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		setRefreshCookie(w, out.cookie, t)
		httpx.Respond(w, http.StatusOK, out.SignIn)
	})
}
```

- [ ] **Step 8: Write `CreateMember`**

Create `internal/staff/member_create.go`:

```go
package staff

import (
	"context"
	"fmt"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/staff/member"
)

// CreateMember creates a member with a temporary password, records
// staff.create for by, and returns the password once. The API creates
// moderators; cmd/staff creates admins.
func CreateMember(ctx context.Context, members member.Store, h Hasher, email, displayName string, role member.Role, by audit.Actor, now time.Time) (MemberView, string, error) {
	temp := member.TemporaryPassword()
	m, err := member.New(uuid.NewV7(), email, displayName, role, h.Hash(temp), now)
	if err != nil {
		return MemberView{}, "", err
	}
	v := viewOf(m, nil)
	err = members.CreateAudited(ctx, m, audit.Entry{
		Actor: by, Action: "staff.create", Target: audit.Staff(m.ID()), Diff: audit.Diff(nil, v), At: now,
	})
	if err != nil {
		return MemberView{}, "", fmt.Errorf("create staff member: %w", err)
	}
	return v, temp, nil
}
```

- [ ] **Step 9: Run the use case tests**

Run: `go test ./internal/staff/`
Expected: `ok`.

- [ ] **Step 10: Mount the sign-in routes**

Create `internal/staff/mount.go`:

```go
// Package staff signs in moderators and admins, checks their role on every
// request, and serves the console's API under /v1/staff. member, quota and
// session hold the aggregates; use cases are functions in this package.
package staff

import (
	"net/netip"

	"github.com/shopnexus/server2/internal/platform/module"
)

// Settings is what staff's Mount takes beyond module.Deps.
type Settings struct {
	Keys           Keys
	TrustedProxies []netip.Prefix
}

// Mount registers the staff endpoints.
func Mount(d module.Deps, s Settings) {
	st := NewStores(d.Pool, s.Keys)
	r, k, trusted, now, log := d.Router, s.Keys, s.TrustedProxies, d.Now, d.Log
	r.Handle("POST /v1/staff/login", LoginHandler(st.Members, st.Quotas, k, trusted, now, log))
	r.Handle("POST /v1/staff/login/password", ChangeTemporaryPasswordHandler(st.Members, k, trusted, now, log))
	r.Handle("POST /v1/staff/login/totp-enrollment", EnrollTOTPHandler(st.Members, k, now, log))
	r.Handle("POST /v1/staff/login/totp", VerifyTOTPHandler(st, k, trusted, now, log))
}
```

In `api/openapi.yaml`, before `components:`, add:

```yaml
  /v1/staff/login:
    $ref: "paths/staff.yaml#/login"
  /v1/staff/login/password:
    $ref: "paths/staff.yaml#/loginPassword"
  /v1/staff/login/totp-enrollment:
    $ref: "paths/staff.yaml#/loginTotpEnrollment"
  /v1/staff/login/totp:
    $ref: "paths/staff.yaml#/loginTotp"
```

In `internal/app/app.go`:

1. Add `hasher staff.Hasher` to `options`, set it to `staff.ProductionHasher` where `New` builds `o`, and add the option:

```go
// WithPasswordHasher sets the argon2id parameters of new staff passwords;
// tests pass staff.FastHasher.
func WithPasswordHasher(h staff.Hasher) Option { return func(o *options) { o.hasher = h } }
```

2. Make `mountModules` return an error and mount staff last:

```go
func mountModules(router *httpx.Router, pool *pgxpool.Pool, cfg config.Config, o options, log *slog.Logger) ([]restate.ServiceDefinition, error) {
	d := module.Deps{
		Router: router, Pool: pool,
		Ingress: ingress.NewClient(cfg.Restate.IngressURL), ServicePrefix: cfg.Restate.ServicePrefix,
		Now: time.Now, Log: log,
	}
	protect := auth.Protect(d, cfg.Auth)
	accounts := account.Mount(d, protect)
	services := auth.Mount(d, auth.Settings{Keys: cfg.Auth, TrustedProxies: cfg.TrustedProxies, SMS: o.sms, Email: o.email}, accounts)
	staffKeys, err := staff.NewKeys(cfg.Staff, cfg.Auth, o.hasher)
	if err != nil {
		return nil, fmt.Errorf("staff keys: %w", err)
	}
	staff.Mount(d, staff.Settings{Keys: staffKeys, TrustedProxies: cfg.TrustedProxies})
	return services, nil
}
```

and in `New` replace `defs := mountModules(...)` with:

```go
	defs, err := mountModules(a.router, pool, cfg, o, log)
	if err != nil {
		return nil, err
	}
```

- [ ] **Step 11: Write the e2e helpers**

In `e2e/main_test.go` add package variables:

```go
	staffKeys   staff.Keys   // the server's staff keys, so tests create members directly
	staffStores staff.Stores // on the e2e database
```

and in `run`, after `db = pool` and once `cfg` is built, before `app.New`:

```go
	if staffKeys, err = staff.NewKeys(cfg.Staff, cfg.Auth, staff.FastHasher); err != nil {
		fmt.Fprintln(os.Stderr, "e2e:", err)
		return 1
	}
	staffStores = staff.NewStores(pool, staffKeys)
```

and pass `app.WithPasswordHasher(staff.FastHasher)` to `app.New`.

Create `e2e/staff_helpers_test.go`:

```go
package e2e

import (
	"context"
	"encoding/base32"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/staff"
	"github.com/shopnexus/server2/internal/staff/member"
)

func newStaffEmail() string { return fmt.Sprintf("staff-%d@example.com", seq.Add(1)) }

// newStaff creates a member the way cmd/staff does and returns its email and
// temporary password.
func newStaff(t *testing.T, role member.Role) (id, email, temp string) {
	t.Helper()
	email = newStaffEmail()
	v, temp, err := staff.CreateMember(context.Background(), staffStores.Members, staff.FastHasher, email, "E2E Staff", role, audit.ByCLI("e2e"), time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return v.ID.String(), email, temp
}

type staffSession struct {
	ID       string
	Email    string
	Password string
	Secret   []byte
	Access   string
	Refresh  string // the staff_refresh cookie's value
}

type loginStep struct {
	Ticket string `json:"ticket"`
	Next   string `json:"next"`
}

type staffSignIn struct {
	AccessToken string `json:"access_token"`
	Staff       struct {
		ID    string `json:"id"`
		Email string `json:"email"`
		Role  string `json:"role"`
	} `json:"staff"`
}

func staffLogin(t *testing.T, email, password string) Response {
	t.Helper()
	return call(t, server, "POST", "/v1/staff/login", map[string]string{"email": email, "password": password})
}

// signInStaff creates a member and takes it through the first sign-in.
func signInStaff(t *testing.T, role member.Role) staffSession {
	t.Helper()
	id, email, temp := newStaff(t, role)
	res := staffLogin(t, email, temp)
	if res.Status != 200 {
		t.Fatalf("login: %d %s", res.Status, res.Body)
	}
	step := decode[loginStep](t, res)
	password := "a long e2e staff password"
	res = call(t, server, "POST", "/v1/staff/login/password", map[string]string{"ticket": step.Ticket, "new_password": password})
	if res.Status != 200 {
		t.Fatalf("password: %d %s", res.Status, res.Body)
	}
	step = decode[loginStep](t, res)
	res = call(t, server, "POST", "/v1/staff/login/totp-enrollment", map[string]string{"ticket": step.Ticket})
	if res.Status != 200 {
		t.Fatalf("enrollment: %d %s", res.Status, res.Body)
	}
	secret, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(decode[struct {
		Secret string `json:"secret"`
	}](t, res).Secret)
	if err != nil {
		t.Fatal(err)
	}
	res = call(t, server, "POST", "/v1/staff/login/totp", map[string]string{"ticket": step.Ticket, "code": member.Code(secret, time.Now())})
	if res.Status != 200 {
		t.Fatalf("totp: %d %s", res.Status, res.Body)
	}
	return staffSession{
		ID: id, Email: email, Password: password, Secret: secret,
		Access: decode[staffSignIn](t, res).AccessToken, Refresh: refreshCookieOf(t, res).Value,
	}
}

func refreshCookieOf(t *testing.T, res Response) *http.Cookie {
	t.Helper()
	for _, c := range (&http.Response{Header: res.Header}).Cookies() {
		if c.Name == "staff_refresh" {
			return c
		}
	}
	t.Fatalf("no staff_refresh cookie in %v", res.Header)
	return nil
}
```

- [ ] **Step 12: Write the e2e tests**

Create `e2e/staff_login_test.go`:

```go
package e2e

import (
	"net/http"
	"testing"
	"time"

	"github.com/shopnexus/server2/internal/staff/member"
)

func TestStaffFirstSignIn(t *testing.T) {
	t.Parallel()
	_, email, temp := newStaff(t, member.RoleModerator)
	step := decode[loginStep](t, staffLogin(t, email, temp))
	if step.Next != "change_password" {
		t.Fatalf("first step %q", step.Next)
	}
	res := call(t, server, "POST", "/v1/staff/login/password", map[string]string{"ticket": step.Ticket, "new_password": "a long e2e staff password"})
	step = decode[loginStep](t, res)
	if step.Next != "enroll_totp" {
		t.Fatalf("second step %q", step.Next)
	}
	res = call(t, server, "POST", "/v1/staff/login/totp-enrollment", map[string]string{"ticket": step.Ticket})
	enr := decode[struct {
		Secret string `json:"secret"`
		URI    string `json:"otpauth_uri"`
	}](t, res)
	if enr.Secret == "" || enr.URI == "" {
		t.Fatalf("%+v", enr)
	}
	s := signInStaff(t, member.RoleAdmin)
	if s.Access == "" || s.Refresh == "" {
		t.Fatalf("%+v", s)
	}
}

func TestStaffRefreshCookieAttributes(t *testing.T) {
	t.Parallel()
	id, email, temp := newStaff(t, member.RoleModerator)
	_ = id
	step := decode[loginStep](t, staffLogin(t, email, temp))
	step = decode[loginStep](t, call(t, server, "POST", "/v1/staff/login/password", map[string]string{"ticket": step.Ticket, "new_password": "a long e2e staff password"}))
	res := call(t, server, "POST", "/v1/staff/login/totp-enrollment", map[string]string{"ticket": step.Ticket})
	secret := decodeBase32(t, decode[struct {
		Secret string `json:"secret"`
	}](t, res).Secret)
	res = call(t, server, "POST", "/v1/staff/login/totp", map[string]string{"ticket": step.Ticket, "code": member.Code(secret, time.Now())}, [2]string{"User-Agent", "e2e-browser"})
	c := refreshCookieOf(t, res)
	if !c.HttpOnly || !c.Secure || c.SameSite != http.SameSiteStrictMode || c.Path != "/v1/staff/session" ||
		c.MaxAge < int((8*time.Hour-time.Minute).Seconds()) || c.MaxAge > int((8 * time.Hour).Seconds()) {
		t.Fatalf("%+v", c)
	}
}

func TestStaffLoginRefusals(t *testing.T) {
	t.Parallel()
	_, email, temp := newStaff(t, member.RoleModerator)
	if res := staffLogin(t, "not an email", temp); res.Status != 400 {
		t.Fatalf("malformed email: %d", res.Status)
	}
	for _, try := range [][2]string{{newStaffEmail(), temp}, {email, temp + "x"}} {
		if res := staffLogin(t, try[0], try[1]); res.Status != 401 || errorOf(t, res).Code != "invalid_credentials" {
			t.Fatalf("%v: %d %s", try, res.Status, res.Body)
		}
	}
	for _, target := range []string{email, newStaffEmail()} {
		for range 5 {
			staffLogin(t, target, "wrong password")
		}
		res := staffLogin(t, target, temp)
		e := errorOf(t, res)
		if res.Status != 429 || e.Code != "login_locked" || e.Details["retry_after"] == nil {
			t.Fatalf("%s: %d %s", target, res.Status, res.Body)
		}
	}
}

func TestStaffLoginStepRefusals(t *testing.T) {
	t.Parallel()
	_, email, temp := newStaff(t, member.RoleModerator)
	step := decode[loginStep](t, staffLogin(t, email, temp))
	if res := call(t, server, "POST", "/v1/staff/login/password", map[string]string{"ticket": "garbage", "new_password": "a long e2e staff password"}); res.Status != 401 || errorOf(t, res).Code != "invalid_login_ticket" {
		t.Fatalf("bad ticket: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", "/v1/staff/login/password", map[string]string{"ticket": step.Ticket, "new_password": "short"}); res.Status != 422 || errorOf(t, res).Code != "password_too_weak" {
		t.Fatalf("weak: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", "/v1/staff/login/totp-enrollment", map[string]string{"ticket": step.Ticket}); res.Status != 401 {
		t.Fatalf("enrollment before the password: %d %s", res.Status, res.Body)
	}
}

func TestStaffWrongCodesLock(t *testing.T) {
	t.Parallel()
	s := signInStaff(t, member.RoleModerator)
	step := decode[loginStep](t, staffLogin(t, s.Email, s.Password))
	good := member.Code(s.Secret, time.Now().Add(30*time.Second))
	bad := good[:5] + string(rune('0'+(good[5]-'0'+1)%10))
	for range 5 {
		if res := call(t, server, "POST", "/v1/staff/login/totp", map[string]string{"ticket": step.Ticket, "code": bad}); res.Status != 401 || errorOf(t, res).Code != "invalid_totp_code" {
			t.Fatalf("wrong code: %d %s", res.Status, res.Body)
		}
	}
	if res := call(t, server, "POST", "/v1/staff/login/totp", map[string]string{"ticket": step.Ticket, "code": good}); res.Status != 429 {
		t.Fatalf("after five wrong codes: %d %s", res.Status, res.Body)
	}
}
```

Add `decodeBase32` to `e2e/staff_helpers_test.go` and use it in `signInStaff` too:

```go
func decodeBase32(t *testing.T, s string) []byte {
	t.Helper()
	b, err := base32.StdEncoding.WithPadding(base32.NoPadding).DecodeString(s)
	if err != nil {
		t.Fatal(err)
	}
	return b
}
```

In `TestStaffRefreshCookieAttributes` remove the unused `id`: write `_, email, temp := newStaff(t, member.RoleModerator)`.

`TestStaffWrongCodesLock` uses the next step's code as the right one, because the step of the sign-in code is spent.

- [ ] **Step 13: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.` A missing status in the coverage check prints `e2e: declared responses no test observed:` with the operation and status.

```bash
git add api/openapi.yaml internal/staff internal/app e2e
git commit -m "feat: staff sign-in

POST /v1/staff/login checks the email and password and returns a ticket
and the next step: change the temporary password, enroll TOTP, or enter a
code. Unknown emails, wrong passwords and disabled members fail alike and
count toward the email's lock. The TOTP step starts an eight-hour session,
records staff.login and sets the staff_refresh cookie.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 10: Request checks and the session endpoints

**Files:**
- Create in `internal/staff/`: `require.go`, `session_refresh.go`, `session_logout.go`, `me.go`, `require_test.go`, `session_refresh_test.go`, `me_test.go`
- Create: `e2e/staff_session_test.go`
- Modify: `internal/platform/httpx/caller.go`, `internal/platform/httpx/bind.go`, `internal/platform/httpx/bind_test.go`, `internal/staff/mount.go`, `api/openapi.yaml`, `e2e/staff_helpers_test.go`

**Interfaces:**
- Consumes: Task 9's `Stores`, `Keys`, `issued`, `setRefreshCookie`, `clearRefreshCookie`, `meOf`, `SignedIn`.
- Produces:
  - `httpx.StaffCaller(w, r, log) (authn.Staff, bool)`; `httpx.Bind` reads `cookie:"name"` fields
  - `staff.Require(sessions session.Store, k Keys, trusted []netip.Prefix, now func() time.Time, log *slog.Logger, floor member.Role) func(http.Handler) http.Handler`
  - `staff.Refresh(ctx, Stores, Keys, refresh string, ip netip.Addr, now) (Refreshed, error)`; `Refreshed{Access Access}` with `RefreshToken() string`
  - `revoke(ctx, session.Store, id uuid.UUID, e *audit.Entry, now) error` (Tasks 10 and 11 call it)
  - `staff.Logout(ctx, session.Store, authn.Staff, now) error`, `staff.GetMe(ctx, member.Store, authn.Staff) (Me, error)`, `staff.ChangePassword(ctx, Stores, Keys, authn.Staff, current, next string, now) error`

- [ ] **Step 1: Teach `Bind` the cookie source and add `StaffCaller`**

Append to `internal/platform/httpx/bind_test.go`:

```go
func TestBindReadsACookie(t *testing.T) {
	t.Parallel()
	var got struct {
		Refresh string `cookie:"staff_refresh" json:"-"`
	}
	r := request(t, "POST", "/", "")
	r.AddCookie(&http.Cookie{Name: "staff_refresh", Value: "rt_abc"})
	if err := Bind(r, &got); err != nil || got.Refresh != "rt_abc" {
		t.Fatalf("%+v %v", got, err)
	}
	var none struct {
		Refresh string `cookie:"staff_refresh" json:"-"`
	}
	if err := Bind(request(t, "POST", "/", ""), &none); err != nil || none.Refresh != "" {
		t.Fatalf("no cookie: %+v %v", none, err)
	}
}
```

Run: `go test ./internal/platform/httpx/ -run Cookie`. Expected: FAIL, because `Bind` has no cookie source and leaves the field empty.

In `internal/platform/httpx/bind.go`:
- add `sourceCookie` after `sourceHeader` in the `source` constants;
- add `sourceCookie: "cookie"` to `sourceTags`;
- add a case to the switch in `Bind`:

```go
		case sourceCookie:
			if c, err := r.Cookie(f.name); err == nil {
				raw = c.Value
			}
```

- update the doc comments of `Bind` and `newPlan` to name `cookie` with `path`, `query` and `header`.

Append to `internal/platform/httpx/caller.go`:

```go
// StaffCaller returns the staff member of a route behind staff.Require, or
// writes 401 and reports false.
func StaffCaller(w http.ResponseWriter, r *http.Request, log *slog.Logger) (authn.Staff, bool) {
	s, ok := authn.StaffFrom(r.Context())
	if !ok {
		WriteError(w, r, log, authn.ErrUnauthenticated)
	}
	return s, ok
}
```

Run: `go test ./internal/platform/httpx/`. Expected: `ok`.

- [ ] **Step 2: Write the failing middleware tests**

Create `internal/staff/require_test.go`:

```go
package staff_test

import (
	"context"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff"
	"github.com/shopnexus/server2/internal/staff/member"
)

var discard = slog.New(slog.DiscardHandler)

// guarded serves 200 with the caller's role behind Require(floor), at now.
func guarded(e env, floor member.Role, at time.Time) http.Handler {
	return staff.Require(e.stores.Sessions, e.keys, nil, func() time.Time { return at }, discard, floor)(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			s, _ := authn.StaffFrom(r.Context())
			_, _ = io.WriteString(w, s.Role)
		}))
}

func get(t *testing.T, h http.Handler, bearer string) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequestWithContext(t.Context(), "GET", "/v1/staff/me", http.NoBody)
	if bearer != "" {
		r.Header.Set("Authorization", "Bearer "+bearer)
	}
	w := httptest.NewRecorder()
	h.ServeHTTP(w, r)
	return w
}

func TestRequireLetsALiveSessionThrough(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	_, _, in := e.enrolled(t, "mod@example.com", member.RoleModerator)
	if w := get(t, guarded(e, member.RoleModerator, now), in.SignIn.AccessToken); w.Code != 200 || w.Body.String() != "moderator" {
		t.Fatalf("%d %s", w.Code, w.Body)
	}
	if w := get(t, guarded(e, member.RoleAdmin, now), in.SignIn.AccessToken); w.Code != 403 {
		t.Fatalf("a moderator on an admin route: %d", w.Code)
	}
	if w := get(t, guarded(e, member.RoleModerator, now), ""); w.Code != 401 {
		t.Fatalf("no token: %d", w.Code)
	}
}

func TestRequireEndsWithDisable(t *testing.T) {
	t.Parallel()
	t.Skip("DisableMember lands in Task 11")
	e := newEnv(t)
	ctx := context.Background()
	_, _, in := e.enrolled(t, "mod@example.com", member.RoleModerator)
	id := in.SignIn.Staff.ID
	if _, err := staff.DisableMember(ctx, e.stores, id, audit.ByCLI("test"), now); err != nil {
		t.Fatal(err)
	}
	if w := get(t, guarded(e, member.RoleModerator, now), in.SignIn.AccessToken); w.Code != 401 {
		t.Fatalf("after the disable: %d", w.Code)
	}
	if _, err := staff.EnableMember(ctx, e.stores, id, audit.ByCLI("test"), now); err != nil {
		t.Fatal(err)
	}
	if w := get(t, guarded(e, member.RoleModerator, now), in.SignIn.AccessToken); w.Code != 401 {
		t.Fatalf("after enabling again: %d", w.Code)
	}
}

func TestRequireRefusesOtherTokens(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	_, temp := e.create(t, "mod@example.com", member.RoleModerator)
	step, err := staff.Login(context.Background(), e.stores.Members, e.stores.Quotas, e.keys, "mod@example.com", temp, clientIP, now)
	if err != nil {
		t.Fatal(err)
	}
	customer, _, _ := e.keys.Signer.Sign(token.Claims{
		Subject: uuid.NewV7(), SessionID: uuid.NewV7(), AuthTime: now, Version: 0, Audience: "shopnexus-app-test", ExpiresAt: time.Time{},
	}, time.Minute, now)
	noSession, _, _ := e.keys.Signer.Sign(token.Claims{
		Subject: uuid.NewV7(), SessionID: uuid.UUID{}, AuthTime: time.Time{}, Version: 0, Audience: staff.AudienceStaff, ExpiresAt: time.Time{},
	}, time.Minute, now)
	for name, tok := range map[string]string{"a login ticket": step.Ticket, "a customer token": customer, "no session": noSession} {
		if w := get(t, guarded(e, member.RoleModerator, now), tok); w.Code != 401 {
			t.Errorf("%s: %d", name, w.Code)
		}
	}
}
```

`TestRequireEndsWithDisable` and `TestRefreshAfterDisable` (Step 4) call `staff.DisableMember` and `staff.EnableMember`, which Task 11 writes. Both start with `t.Skip("DisableMember lands in Task 11")`, and Task 11 Step 1 removes the two skips.

- [ ] **Step 3: Write `Require`**

Create `internal/staff/require.go`:

```go
package staff

import (
	"errors"
	"log/slog"
	"net/http"
	"net/netip"
	"strings"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/session"
)

// Require lets a request through only for a live staff session whose member
// is active, at the session's credentials version, and holds at least
// floor's role. It reads the session and the member on every request, so a
// disable, a reset or a sign-out stops the next request.
func Require(sessions session.Store, k Keys, trusted []netip.Prefix, now func() time.Time, log *slog.Logger, floor member.Role) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			// The scheme is case-insensitive (RFC 9110).
			scheme, tok, _ := strings.Cut(r.Header.Get("Authorization"), " ")
			if !strings.EqualFold(scheme, "Bearer") || tok == "" {
				httpx.WriteError(w, r, log, authn.ErrUnauthenticated)
				return
			}
			at := now()
			c, err := k.Verifier.Verify(tok, AudienceStaff, at)
			if err != nil {
				httpx.WriteError(w, r, log, err)
				return
			}
			if c.SessionID == (uuid.UUID{}) {
				httpx.WriteError(w, r, log, token.ErrInvalid)
				return
			}
			g, err := sessions.Grant(r.Context(), c.SessionID, c.Subject)
			if errors.Is(err, session.ErrNotFound) {
				httpx.WriteError(w, r, log, session.ErrRevoked)
				return
			}
			if err != nil {
				httpx.WriteError(w, r, log, err)
				return
			}
			if checkErr := g.Check(at); checkErr != nil {
				httpx.WriteError(w, r, log, checkErr)
				return
			}
			if !g.Role.AtLeast(floor) {
				httpx.WriteError(w, r, log, ErrStaffForbidden)
				return
			}
			caller := authn.Staff{StaffID: c.Subject, SessionID: c.SessionID, Role: string(g.Role), IP: httpx.ClientIP(r, trusted)}
			next.ServeHTTP(w, r.WithContext(authn.WithStaff(r.Context(), caller)))
		})
	}
}
```

- [ ] **Step 4: Write the failing refresh, logout and password tests**

Create `internal/staff/session_refresh_test.go`:

```go
package staff_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/staff"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/session"
)

func TestRefreshRotates(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	_, _, in := e.enrolled(t, "mod@example.com", member.RoleModerator)
	out, err := staff.Refresh(ctx, e.stores, e.keys, in.RefreshToken(), clientIP, now.Add(time.Minute))
	if err != nil || out.RefreshToken() == in.RefreshToken() || out.Access.TokenType != "Bearer" {
		t.Fatalf("%+v %v", out, err)
	}
	if _, err := staff.Refresh(ctx, e.stores, e.keys, out.RefreshToken(), clientIP, now.Add(2*time.Minute)); err != nil {
		t.Fatalf("the rotated token: %v", err)
	}
	if _, err := staff.Refresh(ctx, e.stores, e.keys, "rt_unknown", clientIP, now); !errors.Is(err, session.ErrInvalidRefresh) {
		t.Fatalf("an unknown token: %v", err)
	}
	if _, err := staff.Refresh(ctx, e.stores, e.keys, in.RefreshToken(), clientIP, now.Add(session.TTL)); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("a token used twice: %v", err)
	}
}

func TestRefreshReuseEndsTheSession(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	_, _, in := e.enrolled(t, "mod@example.com", member.RoleModerator)
	out, err := staff.Refresh(ctx, e.stores, e.keys, in.RefreshToken(), clientIP, now)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := staff.Refresh(ctx, e.stores, e.keys, in.RefreshToken(), clientIP, now); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("replay: %v", err)
	}
	if _, err := staff.Refresh(ctx, e.stores, e.keys, out.RefreshToken(), clientIP, now); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("the newer token after a replay: %v", err)
	}
	var n int
	err = e.db.QueryRow(ctx, `SELECT count(*) FROM staff_actions WHERE action = 'staff.refresh_reuse' AND target_id = @id`,
		pgx.StrictNamedArgs{"id": in.SignIn.Staff.ID}).Scan(&n)
	if err != nil || n != 1 {
		t.Fatalf("audit rows %d: %v", n, err)
	}
}

func TestRefreshAfterDisable(t *testing.T) {
	t.Parallel()
	t.Skip("DisableMember lands in Task 11")
	e := newEnv(t)
	ctx := context.Background()
	_, _, in := e.enrolled(t, "mod@example.com", member.RoleModerator)
	if _, err := staff.DisableMember(ctx, e.stores, in.SignIn.Staff.ID, audit.ByCLI("test"), now); err != nil {
		t.Fatal(err)
	}
	if _, err := staff.Refresh(ctx, e.stores, e.keys, in.RefreshToken(), clientIP, now); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("after the disable: %v", err)
	}
	if _, err := staff.EnableMember(ctx, e.stores, in.SignIn.Staff.ID, audit.ByCLI("test"), now); err != nil {
		t.Fatal(err)
	}
	if _, err := staff.Refresh(ctx, e.stores, e.keys, in.RefreshToken(), clientIP, now); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("after enabling again: %v", err)
	}
}
```

Create `internal/staff/me_test.go`:

```go
package staff_test

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/shopnexus/server2/internal/staff"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/session"
)

func TestChangePasswordKeepsOnlyThisSession(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	password, secret, first := e.enrolled(t, "mod@example.com", member.RoleModerator)
	later := now.Add(time.Minute)
	step, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "mod@example.com", password, clientIP, later)
	if err != nil {
		t.Fatal(err)
	}
	second, err := staff.VerifyTOTP(ctx, e.stores, e.keys, step.Ticket, member.Code(secret, later), clientIP, "test", later)
	if err != nil {
		t.Fatal(err)
	}
	if err := staff.ChangePassword(ctx, e.stores, e.keys, e.callerOf(t, second), "wrong current", "another long password", later); !errors.Is(err, member.ErrInvalidCredentials) {
		t.Fatalf("a wrong current password: %v", err)
	}
	if err := staff.ChangePassword(ctx, e.stores, e.keys, e.callerOf(t, second), password, password, later); !errors.Is(err, member.ErrPasswordTooWeak) {
		t.Fatalf("the same password: %v", err)
	}
	if err := staff.ChangePassword(ctx, e.stores, e.keys, e.callerOf(t, second), password, "another long password", later); err != nil {
		t.Fatal(err)
	}
	if w := get(t, guarded(e, member.RoleModerator, later), second.SignIn.AccessToken); w.Code != 200 {
		t.Fatalf("this session: %d", w.Code)
	}
	if w := get(t, guarded(e, member.RoleModerator, later), first.SignIn.AccessToken); w.Code != 401 {
		t.Fatalf("the other session: %d", w.Code)
	}
	if _, err := staff.Refresh(ctx, e.stores, e.keys, first.RefreshToken(), clientIP, later); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("the other session's refresh: %v", err)
	}
}

func TestLogout(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	_, _, in := e.enrolled(t, "mod@example.com", member.RoleModerator)
	if err := staff.Logout(ctx, e.stores.Sessions, e.callerOf(t, in), now); err != nil {
		t.Fatal(err)
	}
	if w := get(t, guarded(e, member.RoleModerator, now), in.SignIn.AccessToken); w.Code != 401 {
		t.Fatalf("after logout: %d", w.Code)
	}
	me, err := staff.GetMe(ctx, e.stores.Members, e.callerOf(t, in))
	if err != nil || me.Email != "mod@example.com" {
		t.Fatalf("%+v %v", me, err)
	}
}
```

- [ ] **Step 5: Run them to see them fail**

Run: `go test ./internal/staff/`
Expected: FAIL, `undefined: staff.Refresh`.

- [ ] **Step 6: Write refresh and revoke**

Create `internal/staff/session_refresh.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"net/netip"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/platform/token"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/session"
)

type RefreshRequest struct {
	Refresh string `cookie:"staff_refresh" json:"-"`
}

// Refreshed is a new access token and the rotated refresh token.
type Refreshed struct {
	Access Access
	cookie issued
}

// RefreshToken is the token the new cookie carries; tests read it.
func (r Refreshed) RefreshToken() string { return r.cookie.refresh }

// Refresh rotates the refresh token and signs a new access token. A rotated
// token presented again, or two refreshes racing with one token, means two
// parties hold it, so the session ends and staff.refresh_reuse is recorded.
// A disabled member or a moved credentials version ends the session too.
func Refresh(ctx context.Context, st Stores, k Keys, refresh string, ip netip.Addr, now time.Time) (Refreshed, error) {
	hash := token.HashRefresh(refresh)
	s, err := st.Sessions.FindByRefresh(ctx, hash)
	if errors.Is(err, session.ErrNotFound) {
		prev, prevErr := st.Sessions.FindByPrevRefresh(ctx, hash)
		if errors.Is(prevErr, session.ErrNotFound) {
			return Refreshed{}, session.ErrInvalidRefresh
		}
		if prevErr != nil {
			return Refreshed{}, fmt.Errorf("find staff session by previous token: %w", prevErr)
		}
		return Refreshed{}, reused(ctx, st.Sessions, prev.ID(), prev.StaffID(), ip, now)
	}
	if err != nil {
		return Refreshed{}, fmt.Errorf("find staff session by token: %w", err)
	}
	if err = s.Usable(now); err != nil {
		return Refreshed{}, err
	}
	m, err := st.Members.Get(ctx, s.StaffID())
	if err != nil {
		return Refreshed{}, fmt.Errorf("get staff member: %w", err)
	}
	if m.Status() != member.StatusActive || m.CredentialsVersion() != s.CredentialsVersion() {
		if err = revoke(ctx, st.Sessions, s.ID(), nil, now); err != nil {
			return Refreshed{}, err
		}
		return Refreshed{}, session.ErrRevoked
	}
	next := s.Rotate(now)
	if err = st.Sessions.Save(ctx, &s, uuid.NewV7()); err != nil {
		if !errors.Is(err, session.ErrConflict) {
			return Refreshed{}, fmt.Errorf("save staff session: %w", err)
		}
		// The write that won is a refresh with the same token, or a sign-out.
		// Only the first means two parties hold the token.
		cur, getErr := st.Sessions.Get(ctx, s.ID())
		if getErr != nil {
			return Refreshed{}, fmt.Errorf("get staff session: %w", getErr)
		}
		if cur.RevokedAt() != nil {
			return Refreshed{}, session.ErrRevoked
		}
		return Refreshed{}, reused(ctx, st.Sessions, s.ID(), s.StaffID(), ip, now)
	}
	access, exp, err := k.Signer.Sign(token.Claims{
		Subject: m.ID(), SessionID: s.ID(), AuthTime: s.CreatedAt(), Version: 0, Audience: AudienceStaff, ExpiresAt: time.Time{},
	}, session.AccessTTL, now)
	if err != nil {
		return Refreshed{}, fmt.Errorf("sign staff access token: %w", err)
	}
	return Refreshed{
		Access: Access{AccessToken: access, AccessTokenExpiresAt: exp, TokenType: "Bearer"},
		cookie: issued{refresh: next, expiresAt: s.ExpiresAt()},
	}, nil
}

// reused ends a session whose refresh token two parties hold. Whoever
// presented the token proved nothing, so the record's actor is anonymous.
func reused(ctx context.Context, sessions session.Store, id, staffID uuid.UUID, ip netip.Addr, now time.Time) error {
	e := audit.Entry{Actor: audit.Anonymous(ip), Action: "staff.refresh_reuse", Target: audit.Staff(staffID), Diff: nil, At: now}
	if err := revoke(ctx, sessions, id, &e, now); err != nil {
		return err
	}
	return session.ErrRevoked
}

// revoke reloads the session and revokes it, recording e when given, and
// tries once more when a concurrent write gets there first.
func revoke(ctx context.Context, sessions session.Store, id uuid.UUID, e *audit.Entry, now time.Time) error {
	var err error
	for range 2 {
		var s session.Session
		if s, err = sessions.Get(ctx, id); err != nil {
			return fmt.Errorf("get staff session: %w", err)
		}
		if s.RevokedAt() != nil {
			return nil
		}
		s.Revoke(now)
		if e != nil {
			err = sessions.SaveAudited(ctx, &s, uuid.NewV7(), *e)
		} else {
			err = sessions.Save(ctx, &s, uuid.NewV7())
		}
		if err == nil {
			return nil
		}
		if !errors.Is(err, session.ErrConflict) {
			return fmt.Errorf("save staff session: %w", err)
		}
	}
	return fmt.Errorf("revoke staff session: %w", err)
}

// RefreshHandler serves POST /v1/staff/session/refresh. The spec requires
// X-Requested-With, which a cross-site form cannot set. A refusal clears the
// cookie, so the console stops retrying a dead session.
func RefreshHandler(st Stores, k Keys, trusted []netip.Prefix, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in RefreshRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		t := now()
		out, err := Refresh(r.Context(), st, k, in.Refresh, httpx.ClientIP(r, trusted), t)
		if errors.Is(err, session.ErrInvalidRefresh) || errors.Is(err, session.ErrRevoked) || errors.Is(err, session.ErrExpired) {
			clearRefreshCookie(w)
		}
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		setRefreshCookie(w, out.cookie, t)
		httpx.Respond(w, http.StatusOK, out.Access)
	})
}
```

- [ ] **Step 7: Write logout, me and password change**

Create `internal/staff/session_logout.go`:

```go
package staff

import (
	"context"
	"log/slog"
	"net/http"
	"time"

	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/staff/session"
)

// Logout signs the caller's session out.
func Logout(ctx context.Context, sessions session.Store, caller authn.Staff, now time.Time) error {
	return revoke(ctx, sessions, caller.SessionID, nil, now)
}

// LogoutHandler serves POST /v1/staff/session/logout and clears the cookie.
func LogoutHandler(sessions session.Store, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		if err := Logout(r.Context(), sessions, caller, now()); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		clearRefreshCookie(w)
		w.WriteHeader(http.StatusNoContent)
	})
}
```

Create `internal/staff/me.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/session"
)

type ChangePasswordRequest struct {
	CurrentPassword string `json:"current_password"`
	NewPassword     string `json:"new_password"`
}

// GetMe reads the signed-in member.
func GetMe(ctx context.Context, members member.Store, caller authn.Staff) (Me, error) {
	m, err := members.Get(ctx, caller.StaffID)
	if err != nil {
		return Me{}, fmt.Errorf("get staff member: %w", err)
	}
	return meOf(m), nil
}

// ChangePassword replaces the caller's password. The credentials version
// moves, which ends the member's other sessions; the caller's own session
// moves to the new version and stays.
func ChangePassword(ctx context.Context, st Stores, k Keys, caller authn.Staff, current, next string, now time.Time) error {
	m, err := st.Members.Get(ctx, caller.StaffID)
	if err != nil {
		return fmt.Errorf("get staff member: %w", err)
	}
	if !member.VerifyPassword(m.PasswordHash(), current) {
		return member.ErrInvalidCredentials
	}
	if policyErr := member.CheckPolicy(next, m.Email()); policyErr != nil {
		return policyErr
	}
	if member.VerifyPassword(m.PasswordHash(), next) {
		return member.ErrPasswordTooWeak
	}
	m.SetPassword(k.Hasher.Hash(next), now)
	err = st.Members.SaveAudited(ctx, &m, uuid.NewV7(), audit.Entry{
		Actor: audit.ByStaff(caller), Action: "staff.password_change", Target: audit.Staff(m.ID()),
		Diff: map[string]any{"password": "changed"}, At: now,
	})
	if errors.Is(err, member.ErrConflict) {
		return apperr.ErrTryAgain
	}
	if err != nil {
		return fmt.Errorf("save staff member: %w", err)
	}
	for range 2 {
		var s session.Session
		if s, err = st.Sessions.Get(ctx, caller.SessionID); err != nil {
			return fmt.Errorf("get staff session: %w", err)
		}
		s.SetVersion(m.CredentialsVersion())
		if err = st.Sessions.Save(ctx, &s, uuid.NewV7()); !errors.Is(err, session.ErrConflict) {
			break
		}
	}
	if err != nil {
		return fmt.Errorf("move staff session to the new password: %w", err)
	}
	return nil
}

// GetMeHandler serves GET /v1/staff/me.
func GetMeHandler(members member.Store, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		me, err := GetMe(r.Context(), members, caller)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, me)
	})
}

// ChangePasswordHandler serves PUT /v1/staff/me/password.
func ChangePasswordHandler(st Stores, k Keys, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in ChangePasswordRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		if err := ChangePassword(r.Context(), st, k, caller, in.CurrentPassword, in.NewPassword, now()); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
```

- [ ] **Step 8: Mount the routes and run the staff tests**

In `internal/staff/mount.go`, at the end of `Mount`, add:

```go
	mod := Require(st.Sessions, k, trusted, now, log, member.RoleModerator)
	r.Handle("POST /v1/staff/session/refresh", RefreshHandler(st, k, trusted, now, log))
	r.Handle("POST /v1/staff/session/logout", mod(LogoutHandler(st.Sessions, now, log)))
	r.Handle("GET /v1/staff/me", mod(GetMeHandler(st.Members, log)))
	r.Handle("PUT /v1/staff/me/password", mod(ChangePasswordHandler(st, k, now, log)))
```

with the import `github.com/shopnexus/server2/internal/staff/member`. In `api/openapi.yaml`, before `components:`, add:

```yaml
  /v1/staff/session/refresh:
    $ref: "paths/staff.yaml#/sessionRefresh"
  /v1/staff/session/logout:
    $ref: "paths/staff.yaml#/sessionLogout"
  /v1/staff/me:
    $ref: "paths/staff.yaml#/me"
  /v1/staff/me/password:
    $ref: "paths/staff.yaml#/mePassword"
```

Run: `go test ./internal/staff/`. Expected: `ok` (the two disable tests skip).

- [ ] **Step 9: Write the e2e tests**

Append to `e2e/staff_helpers_test.go`:

```go
func staffBearer(s staffSession) [2]string { return bearer(s.Access) }

func refreshWith(t *testing.T, cookie string, headers ...[2]string) Response {
	t.Helper()
	h := append([][2]string{{"Cookie", "staff_refresh=" + cookie}}, headers...)
	return call(t, server, "POST", "/v1/staff/session/refresh", nil, h...)
}

var csrf = [2]string{"X-Requested-With", "shopnexus-console"}
```

Create `e2e/staff_session_test.go`:

```go
package e2e

import (
	"testing"

	"github.com/shopnexus/server2/internal/staff/member"
)

func TestStaffRefresh(t *testing.T) {
	t.Parallel()
	s := signInStaff(t, member.RoleModerator)
	res := refreshWith(t, s.Refresh, csrf)
	if res.Status != 200 {
		t.Fatalf("refresh: %d %s", res.Status, res.Body)
	}
	next := refreshCookieOf(t, res).Value
	if next == s.Refresh {
		t.Fatal("the cookie did not rotate")
	}
	if res := refreshWith(t, s.Refresh, csrf); res.Status != 401 || errorOf(t, res).Code != "session_revoked" {
		t.Fatalf("the old cookie again: %d %s", res.Status, res.Body)
	}
	if res := refreshWith(t, next, csrf); res.Status != 401 {
		t.Fatalf("the newer cookie after a replay: %d %s", res.Status, res.Body)
	}
}

func TestStaffRefreshRefusals(t *testing.T) {
	t.Parallel()
	s := signInStaff(t, member.RoleModerator)
	if res := refreshWith(t, s.Refresh); res.Status != 400 {
		t.Fatalf("without X-Requested-With: %d %s", res.Status, res.Body)
	}
	if res := refreshWith(t, "rt_garbage", csrf); res.Status != 401 || errorOf(t, res).Code != "invalid_refresh_token" {
		t.Fatalf("a garbage cookie: %d %s", res.Status, res.Body)
	}
}

func TestStaffMeAndLogout(t *testing.T) {
	t.Parallel()
	s := signInStaff(t, member.RoleAdmin)
	res := call(t, server, "GET", "/v1/staff/me", nil, staffBearer(s))
	if res.Status != 200 || decode[struct {
		Role string `json:"role"`
	}](t, res).Role != "admin" {
		t.Fatalf("me: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/staff/me", nil); res.Status != 401 {
		t.Fatalf("me without a token: %d", res.Status)
	}
	if res := call(t, server, "POST", "/v1/staff/session/logout", nil); res.Status != 401 {
		t.Fatalf("logout without a token: %d", res.Status)
	}
	if res := call(t, server, "POST", "/v1/staff/session/logout", nil, staffBearer(s)); res.Status != 204 {
		t.Fatalf("logout: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/staff/me", nil, staffBearer(s)); res.Status != 401 {
		t.Fatalf("the access token after logout: %d", res.Status)
	}
}

func TestStaffChangePassword(t *testing.T) {
	t.Parallel()
	s := signInStaff(t, member.RoleModerator)
	body := func(current, next string) map[string]string {
		return map[string]string{"current_password": current, "new_password": next}
	}
	if res := call(t, server, "PUT", "/v1/staff/me/password", body(s.Password, "short"), staffBearer(s)); res.Status != 422 {
		t.Fatalf("weak: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "PUT", "/v1/staff/me/password", body("wrong current", "another long password"), staffBearer(s)); res.Status != 401 {
		t.Fatalf("wrong current: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "PUT", "/v1/staff/me/password", body(s.Password, "another long password"), staffBearer(s)); res.Status != 204 {
		t.Fatalf("change: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/staff/me", nil, staffBearer(s)); res.Status != 200 {
		t.Fatalf("this session after the change: %d", res.Status)
	}
}

// A customer token fails on the staff API and a staff token on the customer
// API, because each verifier checks its audience.
func TestTokensStayInTheirAPI(t *testing.T) {
	t.Parallel()
	customer, _ := newAccount(t)
	s := signInStaff(t, member.RoleModerator)
	if res := call(t, server, "GET", "/v1/staff/me", nil, bearer(customer.AccessToken)); res.Status != 401 {
		t.Fatalf("a customer token on the staff API: %d", res.Status)
	}
	if res := call(t, server, "GET", "/v1/accounts/me", nil, staffBearer(s)); res.Status != 401 {
		t.Fatalf("a staff token on the customer API: %d", res.Status)
	}
}
```

- [ ] **Step 10: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/platform/httpx internal/staff api/openapi.yaml e2e
git commit -m "feat: staff sessions on every request

staff.Require reads the session and the member on every staff request, so
a sign-out, a disable or a credentials change stops the next request, and
a role below the route's gets staff_forbidden. Refresh rotates the cookie
and ends the session when a rotated token comes back. A password change
ends the member's other sessions and keeps the current one. httpx.Bind
reads cookies.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 11: Moderator management

**Files:**
- Create in `internal/staff/`: `member_list.go`, `member_disable.go`, `member_unlock.go`, `member_reset.go`, `member_test.go`
- Create: `e2e/staff_members_test.go`
- Modify: `internal/staff/errors.go`, `internal/staff/member_create.go`, `internal/staff/mount.go`, `internal/staff/require_test.go`, `internal/staff/session_refresh_test.go`, `api/openapi.yaml`

**Interfaces:**
- Consumes: Task 9 and 10 (`Stores`, `Keys`, `viewOf`, `CreateMember`, `Require`). No session is revoked by hand: moving the credentials version ends them.
- Produces:
  - `staff.ErrMemberNotFound` (404 `staff_member_not_found`)
  - `ListMembers(ctx, Stores, Keys, page.Request, now) (page.Page[MemberView], error)`
  - `DisableMember(ctx, Stores, id uuid.UUID, by audit.Actor, now) (MemberView, error)`, `EnableMember(...)` same
  - `UnlockMember(ctx, Stores, Keys, id, by, now) (MemberView, error)`
  - `ResetMemberPassword(ctx, Stores, Keys, id, by, now) (string, error)`, `ResetMemberTOTP(ctx, Stores, id, by, now) (MemberView, error)`
  - Handlers for the seven member routes.

- [ ] **Step 1: Unskip the disable tests and write the failing tests**

Delete the `t.Skip("DisableMember lands in Task 11")` lines from `TestRequireEndsWithDisable` and `TestRefreshAfterDisable`.

Create `internal/staff/member_test.go`:

```go
package staff_test

import (
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/page"
	"github.com/shopnexus/server2/internal/staff"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/quota"
)

func TestAdminCannotTouchAnAdmin(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	admin, _ := e.create(t, "admin@example.com", member.RoleAdmin)
	by := audit.Actor{Kind: audit.ActorStaff, StaffID: uuid.NewV7(), SessionID: uuid.UUID{}, Name: "", IP: clientIP}
	if _, err := staff.DisableMember(ctx, e.stores, admin.ID, by, now); !errors.Is(err, member.ErrAdminManagedByCLI) {
		t.Fatalf("disable: %v", err)
	}
	if _, err := staff.ResetMemberPassword(ctx, e.stores, e.keys, admin.ID, by, now); !errors.Is(err, member.ErrAdminManagedByCLI) {
		t.Fatalf("reset password: %v", err)
	}
	if _, err := staff.DisableMember(ctx, e.stores, admin.ID, audit.ByCLI("root"), now); err != nil {
		t.Fatalf("the CLI: %v", err)
	}
	if _, err := staff.EnableMember(ctx, e.stores, uuid.NewV7(), audit.ByCLI("root"), now); !errors.Is(err, staff.ErrMemberNotFound) {
		t.Fatalf("an unknown id: %v", err)
	}
}

func TestResetsEndSessionsAndStartOver(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	_, _, in := e.enrolled(t, "mod@example.com", member.RoleModerator)
	id := in.SignIn.Staff.ID
	temp, err := staff.ResetMemberPassword(ctx, e.stores, e.keys, id, audit.ByCLI("root"), now)
	if err != nil || len(temp) != 16 {
		t.Fatalf("%q %v", temp, err)
	}
	if w := get(t, guarded(e, member.RoleModerator, now), in.SignIn.AccessToken); w.Code != 401 {
		t.Fatalf("a session after the reset: %d", w.Code)
	}
	step, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "mod@example.com", temp, clientIP, now)
	if err != nil || step.Next != member.StepChangePassword {
		t.Fatalf("%+v %v", step, err)
	}
	v, err := staff.ResetMemberTOTP(ctx, e.stores, id, audit.ByCLI("root"), now)
	if err != nil || v.TOTPEnrolled {
		t.Fatalf("%+v %v", v, err)
	}
}

func TestUnlockAndList(t *testing.T) {
	t.Parallel()
	e := newEnv(t)
	ctx := context.Background()
	v, temp := e.create(t, "mod@example.com", member.RoleModerator)
	for range quota.MaxFailures {
		_, _ = staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "mod@example.com", "wrong password", clientIP, now)
	}
	list, err := staff.ListMembers(ctx, e.stores, e.keys, page.Request{Limit: 10}, now)
	if err != nil || len(list.Items) != 1 || list.Items[0].LockedUntil == nil || !list.Items[0].LockedUntil.Equal(now.Add(quota.LockFor)) {
		t.Fatalf("%+v %v", list, err)
	}
	if _, err := staff.UnlockMember(ctx, e.stores, e.keys, v.ID, audit.ByCLI("root"), now); err != nil {
		t.Fatal(err)
	}
	if _, err := staff.Login(ctx, e.stores.Members, e.stores.Quotas, e.keys, "mod@example.com", temp, clientIP, now.Add(time.Second)); err != nil {
		t.Fatalf("after unlock: %v", err)
	}
}
```

- [ ] **Step 2: Run them to see them fail**

Run: `go test ./internal/staff/`
Expected: FAIL, `undefined: staff.DisableMember`.

- [ ] **Step 3: Write the use cases**

Append to `internal/staff/errors.go`, inside the `var` block:

```go
	ErrMemberNotFound = apperr.New(apperr.KindNotFound, "staff_member_not_found", "no staff member has this id")
```

Create `internal/staff/member_list.go`:

```go
package staff

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/platform/page"
	"github.com/shopnexus/server2/internal/staff/quota"
)

// ListMembers lists members newest first, each with the end of its email's
// sign-in lock when one is in force. The locks of a page come in one query.
func ListMembers(ctx context.Context, st Stores, k Keys, p page.Request, now time.Time) (page.Page[MemberView], error) {
	rows, err := st.Members.List(ctx, p)
	if err != nil {
		return page.Page[MemberView]{}, fmt.Errorf("list staff members: %w", err)
	}
	rows, more := page.Cut(rows, p)
	keys := make([][]byte, len(rows))
	for i := range rows {
		keys[i] = quota.Key(k.Quota, rows[i].Email())
	}
	locks, err := st.Quotas.LockedUntil(ctx, keys, now)
	if err != nil {
		return page.Page[MemberView]{}, fmt.Errorf("list staff login locks: %w", err)
	}
	out := page.Page[MemberView]{Items: make([]MemberView, 0, len(rows))}
	if more {
		out.NextCursor = new(rows[len(rows)-1].ID())
	}
	for i := range rows {
		var lockedUntil *time.Time
		if until, ok := locks[string(keys[i])]; ok {
			lockedUntil = &until
		}
		out.Items = append(out.Items, viewOf(rows[i], lockedUntil))
	}
	return out, nil
}

// ListMembersHandler serves GET /v1/staff/members.
func ListMembersHandler(st Stores, k Keys, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in page.Request
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		out, err := ListMembers(r.Context(), st, k, in, now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, out)
	})
}
```

Create `internal/staff/member_disable.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/staff/member"
)

// MemberRequest names a member by the path.
type MemberRequest struct {
	ID uuid.UUID `json:"-" path:"id"`
}

// DisableMember stops a member signing in and, by moving the credentials
// version, ends every session; enabling the member later brings none back.
func DisableMember(ctx context.Context, st Stores, id uuid.UUID, by audit.Actor, now time.Time) (MemberView, error) {
	m, err := st.Members.Get(ctx, id)
	if errors.Is(err, member.ErrNotFound) {
		return MemberView{}, ErrMemberNotFound
	}
	if err != nil {
		return MemberView{}, fmt.Errorf("get staff member: %w", err)
	}
	if manageErr := m.ManagedBy(by); manageErr != nil {
		return MemberView{}, manageErr
	}
	before := viewOf(m, nil)
	m.Disable(now)
	after := viewOf(m, nil)
	err = st.Members.SaveAudited(ctx, &m, uuid.NewV7(), audit.Entry{
		Actor: by, Action: "staff.disable", Target: audit.Staff(id), Diff: audit.Diff(before, after), At: now,
	})
	if errors.Is(err, member.ErrConflict) {
		return MemberView{}, apperr.ErrTryAgain
	}
	if err != nil {
		return MemberView{}, fmt.Errorf("save staff member: %w", err)
	}
	return after, nil
}

// EnableMember lets a disabled member sign in again.
func EnableMember(ctx context.Context, st Stores, id uuid.UUID, by audit.Actor, now time.Time) (MemberView, error) {
	m, err := st.Members.Get(ctx, id)
	if errors.Is(err, member.ErrNotFound) {
		return MemberView{}, ErrMemberNotFound
	}
	if err != nil {
		return MemberView{}, fmt.Errorf("get staff member: %w", err)
	}
	if manageErr := m.ManagedBy(by); manageErr != nil {
		return MemberView{}, manageErr
	}
	before := viewOf(m, nil)
	m.Enable(now)
	after := viewOf(m, nil)
	err = st.Members.SaveAudited(ctx, &m, uuid.NewV7(), audit.Entry{
		Actor: by, Action: "staff.enable", Target: audit.Staff(id), Diff: audit.Diff(before, after), At: now,
	})
	if errors.Is(err, member.ErrConflict) {
		return MemberView{}, apperr.ErrTryAgain
	}
	if err != nil {
		return MemberView{}, fmt.Errorf("save staff member: %w", err)
	}
	return after, nil
}

// DisableMemberHandler serves POST /v1/staff/members/{id}/disable.
func DisableMemberHandler(st Stores, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in MemberRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		v, err := DisableMember(r.Context(), st, in.ID, audit.ByStaff(caller), now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, v)
	})
}

// EnableMemberHandler serves POST /v1/staff/members/{id}/enable.
func EnableMemberHandler(st Stores, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in MemberRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		v, err := EnableMember(r.Context(), st, in.ID, audit.ByStaff(caller), now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, v)
	})
}
```

Create `internal/staff/member_unlock.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/staff/member"
	"github.com/shopnexus/server2/internal/staff/quota"
)

// UnlockMember clears the failed sign-ins and the lock on a member's email.
func UnlockMember(ctx context.Context, st Stores, k Keys, id uuid.UUID, by audit.Actor, now time.Time) (MemberView, error) {
	m, err := st.Members.Get(ctx, id)
	if errors.Is(err, member.ErrNotFound) {
		return MemberView{}, ErrMemberNotFound
	}
	if err != nil {
		return MemberView{}, fmt.Errorf("get staff member: %w", err)
	}
	if manageErr := m.ManagedBy(by); manageErr != nil {
		return MemberView{}, manageErr
	}
	q, err := st.Quotas.Get(ctx, quota.Key(k.Quota, m.Email()))
	if err != nil {
		return MemberView{}, fmt.Errorf("get login quota: %w", err)
	}
	q.Clear(now)
	err = st.Quotas.SaveAudited(ctx, &q, uuid.NewV7(), audit.Entry{
		Actor: by, Action: "staff.unlock", Target: audit.Staff(id), Diff: nil, At: now,
	})
	if errors.Is(err, quota.ErrConflict) {
		return MemberView{}, apperr.ErrTryAgain
	}
	if err != nil {
		return MemberView{}, fmt.Errorf("save login quota: %w", err)
	}
	return viewOf(m, nil), nil
}

// UnlockMemberHandler serves POST /v1/staff/members/{id}/unlock.
func UnlockMemberHandler(st Stores, k Keys, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in MemberRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		v, err := UnlockMember(r.Context(), st, k, in.ID, audit.ByStaff(caller), now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, v)
	})
}
```

Create `internal/staff/member_reset.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/staff/member"
)

// TemporaryPassword is the TemporaryPassword schema.
type TemporaryPassword struct {
	TemporaryPassword string `json:"temporary_password"`
}

// ResetMemberPassword gives a member a temporary password, which ends every
// session, and returns it once.
func ResetMemberPassword(ctx context.Context, st Stores, k Keys, id uuid.UUID, by audit.Actor, now time.Time) (string, error) {
	m, err := st.Members.Get(ctx, id)
	if errors.Is(err, member.ErrNotFound) {
		return "", ErrMemberNotFound
	}
	if err != nil {
		return "", fmt.Errorf("get staff member: %w", err)
	}
	if manageErr := m.ManagedBy(by); manageErr != nil {
		return "", manageErr
	}
	temp := member.TemporaryPassword()
	m.ResetPassword(k.Hasher.Hash(temp), now)
	err = st.Members.SaveAudited(ctx, &m, uuid.NewV7(), audit.Entry{
		Actor: by, Action: "staff.reset_password", Target: audit.Staff(id), Diff: map[string]any{"password": "reset"}, At: now,
	})
	if errors.Is(err, member.ErrConflict) {
		return "", apperr.ErrTryAgain
	}
	if err != nil {
		return "", fmt.Errorf("save staff member: %w", err)
	}
	return temp, nil
}

// ResetMemberTOTP removes a member's TOTP, which ends every session; the
// member enrolls again at the next sign-in.
func ResetMemberTOTP(ctx context.Context, st Stores, id uuid.UUID, by audit.Actor, now time.Time) (MemberView, error) {
	m, err := st.Members.Get(ctx, id)
	if errors.Is(err, member.ErrNotFound) {
		return MemberView{}, ErrMemberNotFound
	}
	if err != nil {
		return MemberView{}, fmt.Errorf("get staff member: %w", err)
	}
	if manageErr := m.ManagedBy(by); manageErr != nil {
		return MemberView{}, manageErr
	}
	before := viewOf(m, nil)
	m.ResetTOTP(now)
	after := viewOf(m, nil)
	err = st.Members.SaveAudited(ctx, &m, uuid.NewV7(), audit.Entry{
		Actor: by, Action: "staff.reset_totp", Target: audit.Staff(id), Diff: audit.Diff(before, after), At: now,
	})
	if errors.Is(err, member.ErrConflict) {
		return MemberView{}, apperr.ErrTryAgain
	}
	if err != nil {
		return MemberView{}, fmt.Errorf("save staff member: %w", err)
	}
	return after, nil
}

// ResetMemberPasswordHandler serves POST /v1/staff/members/{id}/reset-password.
func ResetMemberPasswordHandler(st Stores, k Keys, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in MemberRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		temp, err := ResetMemberPassword(r.Context(), st, k, in.ID, audit.ByStaff(caller), now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, TemporaryPassword{TemporaryPassword: temp})
	})
}

// ResetMemberTOTPHandler serves POST /v1/staff/members/{id}/reset-totp.
func ResetMemberTOTPHandler(st Stores, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in MemberRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		v, err := ResetMemberTOTP(r.Context(), st, in.ID, audit.ByStaff(caller), now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, v)
	})
}
```

Append to `internal/staff/member_create.go`:

```go
type CreateMemberRequest struct {
	Email       string `json:"email"`
	DisplayName string `json:"display_name"`
}

// CreatedMember is the CreatedMember schema.
type CreatedMember struct {
	Member            MemberView `json:"member"`
	TemporaryPassword string     `json:"temporary_password"`
}

// CreateMemberHandler serves POST /v1/staff/members. The API creates
// moderators only.
func CreateMemberHandler(st Stores, k Keys, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in CreateMemberRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		v, temp, err := CreateMember(r.Context(), st.Members, k.Hasher, in.Email, in.DisplayName, member.RoleModerator, audit.ByStaff(caller), now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusCreated, CreatedMember{Member: v, TemporaryPassword: temp})
	})
}
```

with imports `log/slog`, `net/http`, `github.com/shopnexus/server2/internal/platform/httpx`.

- [ ] **Step 4: Run the staff tests**

Run: `go test ./internal/staff/`
Expected: `ok`, the disable tests included.

- [ ] **Step 5: Mount the routes**

At the end of `Mount` in `internal/staff/mount.go`:

```go
	admin := Require(st.Sessions, k, trusted, now, log, member.RoleAdmin)
	r.Handle("GET /v1/staff/members", admin(ListMembersHandler(st, k, now, log)))
	r.Handle("POST /v1/staff/members", admin(CreateMemberHandler(st, k, now, log)))
	r.Handle("POST /v1/staff/members/{id}/disable", admin(DisableMemberHandler(st, now, log)))
	r.Handle("POST /v1/staff/members/{id}/enable", admin(EnableMemberHandler(st, now, log)))
	r.Handle("POST /v1/staff/members/{id}/unlock", admin(UnlockMemberHandler(st, k, now, log)))
	r.Handle("POST /v1/staff/members/{id}/reset-password", admin(ResetMemberPasswordHandler(st, k, now, log)))
	r.Handle("POST /v1/staff/members/{id}/reset-totp", admin(ResetMemberTOTPHandler(st, now, log)))
```

In `api/openapi.yaml`, before `components:`:

```yaml
  /v1/staff/members:
    $ref: "paths/staff.yaml#/members"
  /v1/staff/members/{id}/disable:
    $ref: "paths/staff.yaml#/memberDisable"
  /v1/staff/members/{id}/enable:
    $ref: "paths/staff.yaml#/memberEnable"
  /v1/staff/members/{id}/unlock:
    $ref: "paths/staff.yaml#/memberUnlock"
  /v1/staff/members/{id}/reset-password:
    $ref: "paths/staff.yaml#/memberResetPassword"
  /v1/staff/members/{id}/reset-totp:
    $ref: "paths/staff.yaml#/memberResetTotp"
```

- [ ] **Step 6: Write the e2e tests**

Create `e2e/staff_members_test.go`:

```go
package e2e

import (
	"testing"
	"uuid"

	"github.com/shopnexus/server2/internal/staff/member"
)

var memberOps = []string{"disable", "enable", "unlock", "reset-password", "reset-totp"}

func TestStaffManagesModerators(t *testing.T) {
	t.Parallel()
	admin := signInStaff(t, member.RoleAdmin)
	email := newStaffEmail()
	res := call(t, server, "POST", "/v1/staff/members", map[string]string{"email": email, "display_name": "New Mod"}, staffBearer(admin))
	created := decode[struct {
		Member struct {
			ID   string `json:"id"`
			Role string `json:"role"`
		} `json:"member"`
		Temporary string `json:"temporary_password"`
	}](t, res)
	if res.Status != 201 || created.Member.Role != "moderator" || len(created.Temporary) != 16 {
		t.Fatalf("create: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", "/v1/staff/members", map[string]string{"email": email, "display_name": "Again"}, staffBearer(admin)); res.Status != 409 {
		t.Fatalf("the same email: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", "/v1/staff/members", map[string]string{"email": "nope", "display_name": "Bad"}, staffBearer(admin)); res.Status != 400 {
		t.Fatalf("a bad email: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/staff/members?limit=100", nil, staffBearer(admin)); res.Status != 200 {
		t.Fatalf("list: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/staff/members", nil); res.Status != 401 {
		t.Fatalf("list without a token: %d", res.Status)
	}

	mod := signInStaff(t, member.RoleModerator)
	path := "/v1/staff/members/" + mod.ID + "/"
	if res := call(t, server, "POST", path+"disable", nil, staffBearer(admin)); res.Status != 200 {
		t.Fatalf("disable: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/staff/me", nil, staffBearer(mod)); res.Status != 401 {
		t.Fatalf("the disabled moderator's token: %d", res.Status)
	}
	if res := call(t, server, "POST", path+"enable", nil, staffBearer(admin)); res.Status != 200 {
		t.Fatalf("enable: %d %s", res.Status, res.Body)
	}
	for range 5 {
		staffLogin(t, mod.Email, "wrong password")
	}
	if res := staffLogin(t, mod.Email, mod.Password); res.Status != 429 {
		t.Fatalf("locked: %d", res.Status)
	}
	if res := call(t, server, "POST", path+"unlock", nil, staffBearer(admin)); res.Status != 200 {
		t.Fatalf("unlock: %d %s", res.Status, res.Body)
	}
	if res := staffLogin(t, mod.Email, mod.Password); res.Status != 200 {
		t.Fatalf("after unlock: %d %s", res.Status, res.Body)
	}
	res = call(t, server, "POST", path+"reset-password", nil, staffBearer(admin))
	if res.Status != 200 || len(decode[struct {
		Temporary string `json:"temporary_password"`
	}](t, res).Temporary) != 16 {
		t.Fatalf("reset password: %d %s", res.Status, res.Body)
	}
	res = call(t, server, "POST", path+"reset-totp", nil, staffBearer(admin))
	if res.Status != 200 || decode[struct {
		Enrolled bool `json:"totp_enrolled"`
	}](t, res).Enrolled {
		t.Fatalf("reset totp: %d %s", res.Status, res.Body)
	}
}

func TestStaffMemberOpsForbidden(t *testing.T) {
	t.Parallel()
	admin := signInStaff(t, member.RoleAdmin)
	mod := signInStaff(t, member.RoleModerator)
	otherAdmin, _, _ := newStaff(t, member.RoleAdmin)
	if res := call(t, server, "GET", "/v1/staff/members", nil, staffBearer(mod)); res.Status != 403 || errorOf(t, res).Code != "staff_forbidden" {
		t.Fatalf("a moderator listing: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", "/v1/staff/members", map[string]string{"email": newStaffEmail(), "display_name": "X"}, staffBearer(mod)); res.Status != 403 {
		t.Fatalf("a moderator creating: %d", res.Status)
	}
	for _, op := range memberOps {
		path := "/v1/staff/members/" + otherAdmin + "/" + op
		if res := call(t, server, "POST", path, nil, staffBearer(mod)); res.Status != 403 || errorOf(t, res).Code != "staff_forbidden" {
			t.Errorf("%s by a moderator: %d %s", op, res.Status, res.Body)
		}
		if res := call(t, server, "POST", path, nil, staffBearer(admin)); res.Status != 403 || errorOf(t, res).Code != "admin_managed_by_cli" {
			t.Errorf("%s on an admin: %d %s", op, res.Status, res.Body)
		}
		if res := call(t, server, "POST", "/v1/staff/members/"+uuid.NewV7().String()+"/"+op, nil, staffBearer(admin)); res.Status != 404 {
			t.Errorf("%s on an unknown id: %d %s", op, res.Status, res.Body)
		}
	}
}
```

- [ ] **Step 7: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/staff api/openapi.yaml e2e
git commit -m "feat: admins manage moderators

Admins list, create, disable, enable, unlock and reset moderators under
/v1/staff/members. Disable and both resets move the member's credentials
version, which ends every session; enabling a member brings none back.
An admin acting on an admin gets admin_managed_by_cli, and every change
is recorded with its diff.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 12: Customer accounts for moderators

**Files:**
- Create: `internal/auth/client.go`, `internal/auth/client_test.go`, `internal/staff/ports.go`, `internal/staff/account_list.go`, `internal/staff/account_get.go`, `internal/staff/account_suspend.go`, `e2e/staff_accounts_test.go`
- Modify: `internal/auth/mount.go`, `internal/staff/mount.go`, `internal/app/app.go`, `api/openapi.yaml`

**Interfaces:**
- Consumes: `account.Client` methods from Task 5; `audit.Store.List`; `Require`.
- Produces:
  - `auth.Identity{Kind credentials.Kind; Value string}`, `auth.Client{Credentials credentials.Store}` with `FindAccount(ctx, q string) (uuid.UUID, bool, error)` and `Identities(ctx, accountID) ([]Identity, error)`
  - `auth.Mounted{Services []restate.ServiceDefinition; Client Client}` returned by `auth.Mount`
  - `staff.AccountPort`, `staff.IdentityPort`; `staff.Mount(d, Settings, AccountPort, IdentityPort)`
  - `staff.ListAccounts(ctx, AccountPort, IdentityPort, q string, page.Request) (page.Page[account.Record], error)`, `staff.GetAccount(ctx, AccountPort, IdentityPort, audit.Store, id) (AccountDetail, error)`

- [ ] **Step 1: Write the failing `auth.Client` test**

Create `internal/auth/client_test.go`:

```go
package auth_test

import (
	"context"
	"testing"
	"uuid"

	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/platform/pgtest"
)

func TestClientFindsAccounts(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	ctx := context.Background()
	id := newAccount(t, db)
	creds := credentials.NewPGStore(db)
	c := credentials.New(id, credentials.NewIdentity(uuid.NewV7(), phone(t, "0901234567"), now), now)
	if err := creds.Create(ctx, c); err != nil {
		t.Fatal(err)
	}
	client := auth.Client{Credentials: creds}
	for _, q := range []string{"0901234567", "+84901234567", "84 901 234 567"} {
		got, ok, err := client.FindAccount(ctx, q)
		if err != nil || !ok || got != id {
			t.Errorf("%q: %v %v %v", q, got, ok, err)
		}
	}
	for _, q := range []string{"0907654321", "nobody@example.com", "not a phone"} {
		if _, ok, err := client.FindAccount(ctx, q); err != nil || ok {
			t.Errorf("%q matched: %v %v", q, ok, err)
		}
	}
	ids, err := client.Identities(ctx, id)
	if err != nil || len(ids) != 1 || ids[0].Kind != credentials.Phone || ids[0].Value != "+84901234567" {
		t.Fatalf("%+v %v", ids, err)
	}
	if none, err := client.Identities(ctx, uuid.NewV7()); err != nil || len(none) != 0 || none == nil {
		t.Fatalf("an account without credentials: %+v %v", none, err)
	}
}
```

`newAccount`, `phone` and `now` are in `internal/auth/helpers_test.go`. Run: `go test ./internal/auth/ -run ClientFinds`. Expected: FAIL, `undefined: auth.Client`.

- [ ] **Step 2: Write `auth.Client` and return it from `Mount`**

Create `internal/auth/client.go`:

```go
package auth

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/platform/contact"
)

// Identity is a sign-in method as staff see it: the Identity schema in
// api/schemas/staff.yaml.
type Identity struct {
	Kind  credentials.Kind `json:"kind"`
	Value string           `json:"value"`
}

// Client implements the ports other modules declare for auth's data. It
// only reads.
type Client struct {
	Credentials credentials.Store
}

// FindAccount returns the account holding the phone number or email q, in
// any form a person types. A q that is neither, or that no account holds,
// reports false.
func (c Client) FindAccount(ctx context.Context, q string) (uuid.UUID, bool, error) {
	var (
		a   contact.Address
		err error
	)
	if strings.Contains(q, "@") {
		a, err = contact.ParseEmail(q)
	} else {
		a, err = contact.ParsePhone(q)
	}
	if err != nil {
		return uuid.UUID{}, false, nil //nolint:nilerr // A q that is no phone or email matches no account.
	}
	ref, err := c.Credentials.FindIdentity(ctx, credentials.KindOf(a), a.Value())
	if errors.Is(err, credentials.ErrNotFound) {
		return uuid.UUID{}, false, nil
	}
	if err != nil {
		return uuid.UUID{}, false, fmt.Errorf("find identity: %w", err)
	}
	return ref.AccountID, true, nil
}

// Identities lists an account's sign-in methods; an account without
// credentials has none.
func (c Client) Identities(ctx context.Context, accountID uuid.UUID) ([]Identity, error) {
	cr, err := c.Credentials.Get(ctx, accountID)
	if errors.Is(err, credentials.ErrNotFound) {
		return []Identity{}, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get credentials: %w", err)
	}
	ids := cr.Identities()
	out := make([]Identity, 0, len(ids))
	for _, i := range ids {
		out = append(out, Identity{Kind: i.Kind(), Value: i.Value()})
	}
	return out, nil
}
```

In `internal/auth/mount.go` add:

```go
// Mounted is what auth's Mount gives app and other modules.
type Mounted struct {
	Services []restate.ServiceDefinition
	Client   Client
}
```

change `Mount` to return `Mounted`, and its final `return []restate.ServiceDefinition{...}` to:

```go
	return Mounted{
		Services: []restate.ServiceDefinition{
			restate.Reflect(OTP{
				Prefix: d.ServicePrefix, Quotas: quotas, Challenges: challenges, Codes: codes, SMS: s.SMS, Email: s.Email,
				Now: now,
			}),
			restate.Reflect(SignIn{
				Prefix: d.ServicePrefix, Challenges: challenges, Credentials: creds, Accounts: accounts,
				Now: now,
			}),
		},
		Client: Client{Credentials: creds},
	}
```

Update the doc comment: `// Mount registers auth's HTTP handlers and returns its Restate services, with prefixed names, and the client other modules read identities through.`

Run: `go test ./internal/auth/ -run ClientFinds`. Expected: `ok`.

- [ ] **Step 3: Declare the staff ports and write the use cases**

Create `internal/staff/ports.go`:

```go
package staff

import (
	"context"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/page"
)

// AccountPort is what staff needs from module account; account.Client
// implements it. Suspend and Reinstate record their audit row in the
// account's own transaction.
type AccountPort interface {
	Record(ctx context.Context, id uuid.UUID) (account.Record, error)
	Records(ctx context.Context, p page.Request) ([]account.Record, error)
	Suspend(ctx context.Context, id uuid.UUID, reason string, until *time.Time, by audit.Actor) (account.Record, error)
	Reinstate(ctx context.Context, id uuid.UUID, by audit.Actor) (account.Record, error)
}

// IdentityPort is what staff needs from module auth; auth.Client implements
// it.
type IdentityPort interface {
	FindAccount(ctx context.Context, q string) (uuid.UUID, bool, error)
	Identities(ctx context.Context, accountID uuid.UUID) ([]auth.Identity, error)
}
```

Create `internal/staff/account_list.go`:

```go
package staff

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/platform/page"
)

type ListAccountsRequest struct {
	page.Request

	Q string `json:"-" query:"q"`
}

// ListAccounts lists accounts newest first or, with q, the one account q
// names by ID, phone number or email. A q that names nothing gives an empty
// page.
func ListAccounts(ctx context.Context, accounts AccountPort, identities IdentityPort, q string, p page.Request) (page.Page[account.Record], error) {
	out := page.Page[account.Record]{Items: []account.Record{}}
	if q == "" {
		rows, err := accounts.Records(ctx, p)
		if err != nil {
			return page.Page[account.Record]{}, fmt.Errorf("list accounts: %w", err)
		}
		rows, more := page.Cut(rows, p)
		out.Items = append(out.Items, rows...)
		if more {
			out.NextCursor = new(rows[len(rows)-1].ID)
		}
		return out, nil
	}
	id, parseErr := uuid.Parse(q)
	if parseErr != nil {
		found, ok, err := identities.FindAccount(ctx, q)
		if err != nil {
			return page.Page[account.Record]{}, fmt.Errorf("find account: %w", err)
		}
		if !ok {
			return out, nil
		}
		id = found
	}
	r, err := accounts.Record(ctx, id)
	if errors.Is(err, account.ErrNotFound) {
		return out, nil
	}
	if err != nil {
		return page.Page[account.Record]{}, fmt.Errorf("get account: %w", err)
	}
	out.Items = append(out.Items, r)
	return out, nil
}

// ListAccountsHandler serves GET /v1/staff/accounts.
func ListAccountsHandler(accounts AccountPort, identities IdentityPort, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in ListAccountsRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		out, err := ListAccounts(r.Context(), accounts, identities, in.Q, in.Request)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, out)
	})
}
```

Create `internal/staff/account_get.go`:

```go
package staff

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/platform/page"
)

// historyLength is how many staff actions the account screen shows.
const historyLength = 20

// AccountDetail is the StaffAccountDetail schema.
type AccountDetail struct {
	Account    account.Record  `json:"account"`
	Identities []auth.Identity `json:"identities"`
	Actions    []audit.Action  `json:"actions"`
}

type AccountRequest struct {
	ID uuid.UUID `json:"-" path:"id"`
}

// GetAccount reads an account with its identities and the latest staff
// actions on it.
func GetAccount(ctx context.Context, accounts AccountPort, identities IdentityPort, actions audit.Store, id uuid.UUID) (AccountDetail, error) {
	r, err := accounts.Record(ctx, id)
	if err != nil {
		return AccountDetail{}, fmt.Errorf("get account: %w", err)
	}
	ids, err := identities.Identities(ctx, id)
	if err != nil {
		return AccountDetail{}, fmt.Errorf("list identities: %w", err)
	}
	history := page.Request{Cursor: uuid.UUID{}, Limit: historyLength}
	acts, err := actions.List(ctx, audit.Filter{StaffID: uuid.UUID{}, Action: "", TargetID: id, Since: time.Time{}, Until: time.Time{}}, history)
	if err != nil {
		return AccountDetail{}, fmt.Errorf("list staff actions: %w", err)
	}
	acts, _ = page.Cut(acts, history)
	if acts == nil {
		acts = []audit.Action{}
	}
	return AccountDetail{Account: r, Identities: ids, Actions: acts}, nil
}

// GetAccountHandler serves GET /v1/staff/accounts/{id}.
func GetAccountHandler(accounts AccountPort, identities IdentityPort, actions audit.Store, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in AccountRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		d, err := GetAccount(r.Context(), accounts, identities, actions, in.ID)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, d)
	})
}
```

(import `time` too). `account.ErrNotFound` is an `*apperr.Error` with kind not found, so an unknown id answers 404 through the wrap.

Create `internal/staff/account_suspend.go`. The handlers call the port directly; a use case here would only forward:

```go
package staff

import (
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
)

type SuspendRequest struct {
	ID     uuid.UUID  `json:"-"     path:"id"`
	Reason string     `json:"reason"`
	Until  *time.Time `json:"until"`
}

// SuspendAccountHandler serves POST /v1/staff/accounts/{id}/suspend.
func SuspendAccountHandler(accounts AccountPort, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in SuspendRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		rec, err := accounts.Suspend(r.Context(), in.ID, in.Reason, in.Until, audit.ByStaff(caller))
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, rec)
	})
}

// UnsuspendAccountHandler serves POST /v1/staff/accounts/{id}/unsuspend.
func UnsuspendAccountHandler(accounts AccountPort, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		caller, ok := httpx.StaffCaller(w, r, log)
		if !ok {
			return
		}
		var in AccountRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		rec, err := accounts.Reinstate(r.Context(), in.ID, audit.ByStaff(caller))
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, rec)
	})
}
```

Run `golangci-lint run --enable-only tagalign --fix ./internal/staff/` to align the tags.

- [ ] **Step 4: Mount the routes and wire the ports**

Change the signature of `Mount` in `internal/staff/mount.go` to:

```go
// Mount registers the staff endpoints. accounts and identities reach the
// customer data of modules account and auth.
func Mount(d module.Deps, s Settings, accounts AccountPort, identities IdentityPort) {
```

and append inside it:

```go
	r.Handle("GET /v1/staff/accounts", mod(ListAccountsHandler(accounts, identities, log)))
	r.Handle("GET /v1/staff/accounts/{id}", mod(GetAccountHandler(accounts, identities, st.Actions, log)))
	r.Handle("POST /v1/staff/accounts/{id}/suspend", mod(SuspendAccountHandler(accounts, log)))
	r.Handle("POST /v1/staff/accounts/{id}/unsuspend", mod(UnsuspendAccountHandler(accounts, log)))
```

In `internal/app/app.go`, in `mountModules`:

```go
	authm := auth.Mount(d, auth.Settings{Keys: cfg.Auth, TrustedProxies: cfg.TrustedProxies, SMS: o.sms, Email: o.email}, accounts)
	staffKeys, err := staff.NewKeys(cfg.Staff, cfg.Auth, o.hasher)
	if err != nil {
		return nil, fmt.Errorf("staff keys: %w", err)
	}
	staff.Mount(d, staff.Settings{Keys: staffKeys, TrustedProxies: cfg.TrustedProxies}, accounts, authm.Client)
	return authm.Services, nil
```

In `api/openapi.yaml`, before `components:`:

```yaml
  /v1/staff/accounts:
    $ref: "paths/staff.yaml#/accounts"
  /v1/staff/accounts/{id}:
    $ref: "paths/staff.yaml#/account"
  /v1/staff/accounts/{id}/suspend:
    $ref: "paths/staff.yaml#/accountSuspend"
  /v1/staff/accounts/{id}/unsuspend:
    $ref: "paths/staff.yaml#/accountUnsuspend"
```

- [ ] **Step 5: Write the e2e tests**

Create `e2e/staff_accounts_test.go`:

```go
package e2e

import (
	"net/url"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/staff/member"
)

type staffAccount struct {
	ID     string `json:"id"`
	Status string `json:"status"`
	Reason string `json:"suspend_reason"`
}

type staffAccountList struct {
	Items []staffAccount `json:"items"`
}

func TestStaffFindsAccounts(t *testing.T) {
	t.Parallel()
	mod := signInStaff(t, member.RoleModerator)
	customer, phone := newAccount(t)
	for _, q := range []string{phone, customer.Account.ID} {
		// A phone starts with +, which a raw query string reads as a space.
		res := call(t, server, "GET", "/v1/staff/accounts?"+url.Values{"q": {q}}.Encode(), nil, staffBearer(mod))
		list := decode[staffAccountList](t, res)
		if res.Status != 200 || len(list.Items) != 1 || list.Items[0].ID != customer.Account.ID {
			t.Fatalf("q=%s: %d %s", q, res.Status, res.Body)
		}
	}
	if res := call(t, server, "GET", "/v1/staff/accounts?q=0907777777", nil, staffBearer(mod)); len(decode[staffAccountList](t, res).Items) != 0 {
		t.Fatalf("an unknown phone: %s", res.Body)
	}
	if res := call(t, server, "GET", "/v1/staff/accounts?limit=5", nil, staffBearer(mod)); res.Status != 200 {
		t.Fatalf("every account: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/staff/accounts", nil); res.Status != 401 {
		t.Fatalf("without a token: %d", res.Status)
	}
}

func TestStaffSuspendsAnAccount(t *testing.T) {
	t.Parallel()
	mod := signInStaff(t, member.RoleModerator)
	customer, _ := newAccount(t)
	path := "/v1/staff/accounts/" + customer.Account.ID

	res := call(t, server, "GET", path, nil, staffBearer(mod))
	detail := decode[struct {
		Identities []struct {
			Kind string `json:"kind"`
		} `json:"identities"`
	}](t, res)
	if res.Status != 200 || len(detail.Identities) != 1 || detail.Identities[0].Kind != "phone" {
		t.Fatalf("detail: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", path+"/suspend", map[string]string{"reason": "   "}, staffBearer(mod)); res.Status != 422 {
		t.Fatalf("a blank reason: %d %s", res.Status, res.Body)
	}
	past := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	if res := call(t, server, "POST", path+"/suspend", map[string]string{"reason": "spam", "until": past}, staffBearer(mod)); res.Status != 422 {
		t.Fatalf("an end in the past: %d %s", res.Status, res.Body)
	}
	res = call(t, server, "POST", path+"/suspend", map[string]string{"reason": "spam"}, staffBearer(mod))
	if got := decode[staffAccount](t, res); res.Status != 200 || got.Status != "suspended" || got.Reason != "spam" {
		t.Fatalf("suspend: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "PATCH", "/v1/accounts/me", map[string]string{"display_name": "New"}, bearer(customer.AccessToken)); res.Status != 403 {
		t.Fatalf("the suspended customer writing: %d %s", res.Status, res.Body)
	}
	res = call(t, server, "GET", path, nil, staffBearer(mod))
	history := decode[struct {
		Actions []struct {
			Action string `json:"action"`
			Actor  struct {
				StaffID string `json:"staff_id"`
			} `json:"actor"`
		} `json:"actions"`
	}](t, res)
	if len(history.Actions) != 1 || history.Actions[0].Action != "account.suspend" || history.Actions[0].Actor.StaffID != mod.ID {
		t.Fatalf("history: %s", res.Body)
	}
	if got := decode[staffAccount](t, call(t, server, "POST", path+"/unsuspend", nil, staffBearer(mod))); got.Status != "active" {
		t.Fatalf("unsuspend: %+v", got)
	}

	unknown := "/v1/staff/accounts/" + uuid.NewV7().String()
	if res := call(t, server, "GET", unknown, nil, staffBearer(mod)); res.Status != 404 {
		t.Fatalf("get unknown: %d", res.Status)
	}
	if res := call(t, server, "POST", unknown+"/suspend", map[string]string{"reason": "spam"}, staffBearer(mod)); res.Status != 404 {
		t.Fatalf("suspend unknown: %d", res.Status)
	}
	if res := call(t, server, "POST", unknown+"/unsuspend", nil, staffBearer(mod)); res.Status != 404 {
		t.Fatalf("unsuspend unknown: %d", res.Status)
	}
}
```

- [ ] **Step 6: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/auth internal/staff internal/app api/openapi.yaml e2e
git commit -m "feat: moderators find, read and suspend customer accounts

GET /v1/staff/accounts lists accounts or finds one by ID, phone number or
email; the account screen adds its identities and the latest staff
actions on it. Suspend and unsuspend go through account.Client, which
records the change in the account's transaction. Staff reaches module
account and module auth through ports it declares; auth.Mount now
returns auth.Client with its services.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: The audit log endpoint

**Files:**
- Create: `internal/staff/action_list.go`, `e2e/staff_actions_test.go`
- Modify: `internal/staff/mount.go`, `api/openapi.yaml`

**Interfaces:**
- Consumes: `audit.Store.List`, `audit.Filter`, `page.Request`, the `admin` middleware from Task 11.
- Produces: `staff.ListActions(ctx, audit.Store, audit.Filter, page.Request) (page.Page[audit.Action], error)`, `ListActionsHandler`.

- [ ] **Step 1: Write the use case and handler**

Create `internal/staff/action_list.go`:

```go
package staff

import (
	"context"
	"fmt"
	"log/slog"
	"net/http"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/platform/page"
)

type ListActionsRequest struct {
	page.Request
	audit.Filter
}

// ListActions lists the audit log newest first, narrowed by f.
func ListActions(ctx context.Context, actions audit.Store, f audit.Filter, p page.Request) (page.Page[audit.Action], error) {
	rows, err := actions.List(ctx, f, p)
	if err != nil {
		return page.Page[audit.Action]{}, fmt.Errorf("list staff actions: %w", err)
	}
	rows, more := page.Cut(rows, p)
	out := page.Page[audit.Action]{Items: make([]audit.Action, 0, len(rows))}
	out.Items = append(out.Items, rows...)
	if more {
		out.NextCursor = new(rows[len(rows)-1].ID)
	}
	return out, nil
}

// ListActionsHandler serves GET /v1/staff/actions.
func ListActionsHandler(actions audit.Store, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var in ListActionsRequest
		if err := httpx.Bind(r, &in); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		out, err := ListActions(r.Context(), actions, in.Filter, in.Request)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, http.StatusOK, out)
	})
}
```

Append to `Mount`:

```go
	r.Handle("GET /v1/staff/actions", admin(ListActionsHandler(st.Actions, log)))
```

In `api/openapi.yaml`, before `components:`:

```yaml
  /v1/staff/actions:
    $ref: "paths/staff.yaml#/actions"
```

- [ ] **Step 2: Write the e2e test**

Create `e2e/staff_actions_test.go`:

```go
package e2e

import (
	"net/url"
	"testing"

	"github.com/shopnexus/server2/internal/staff/member"
)

func TestStaffActions(t *testing.T) {
	t.Parallel()
	admin := signInStaff(t, member.RoleAdmin)
	mod := signInStaff(t, member.RoleModerator)
	customer, _ := newAccount(t)
	if res := call(t, server, "POST", "/v1/staff/accounts/"+customer.Account.ID+"/suspend", map[string]string{"reason": "spam"}, staffBearer(mod)); res.Status != 200 {
		t.Fatalf("suspend: %d %s", res.Status, res.Body)
	}
	type actionList struct {
		Items []struct {
			Action string `json:"action"`
			Actor  struct {
				Kind        string `json:"kind"`
				DisplayName string `json:"display_name"`
			} `json:"actor"`
		} `json:"items"`
	}
	q := url.Values{"target_id": {customer.Account.ID}}
	res := call(t, server, "GET", "/v1/staff/actions?"+q.Encode(), nil, staffBearer(admin))
	got := decode[actionList](t, res)
	if res.Status != 200 || len(got.Items) != 1 || got.Items[0].Action != "account.suspend" || got.Items[0].Actor.DisplayName != "E2E Staff" {
		t.Fatalf("by target: %d %s", res.Status, res.Body)
	}
	q = url.Values{"staff_id": {mod.ID}, "action": {"staff.login"}}
	if got := decode[actionList](t, call(t, server, "GET", "/v1/staff/actions?"+q.Encode(), nil, staffBearer(admin))); len(got.Items) != 1 {
		t.Fatalf("the moderator's sign-in: %+v", got)
	}
	if res := call(t, server, "GET", "/v1/staff/actions", nil, staffBearer(mod)); res.Status != 403 {
		t.Fatalf("a moderator reading the log: %d", res.Status)
	}
}
```

- [ ] **Step 3: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/staff api/openapi.yaml e2e
git commit -m "feat: admins read the audit log

GET /v1/staff/actions lists staff_actions newest first, filtered by staff
member, action, target and time, with the actor's name.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---
### Task 14: `cmd/staff`

**Files:**
- Create: `cmd/staff/main.go`, `cmd/staff/main_test.go`
- Modify: `CLAUDE.md`

**Interfaces:**
- Consumes: `staff.NewKeys`, `staff.NewStores`, `staff.CreateMember`, `DisableMember`, `EnableMember`, `ResetMemberPassword`, `ResetMemberTOTP`, `audit.ByCLI`, `member.RoleAdmin`, `member.NormalizeEmail`.
- Produces: `go run ./cmd/staff create-admin --email E --name N`, and `disable`, `enable`, `reset-password`, `reset-totp` with `--email E`.

- [ ] **Step 1: Write the failing test**

Create `cmd/staff/main_test.go`:

```go
package main

import (
	"bytes"
	"context"
	"strings"
	"testing"
)

// Bad arguments stop before the config is read, so this needs no database.
func TestRunRefusesBadArguments(t *testing.T) {
	t.Parallel()
	cases := map[string][]string{
		"usage":            {"no command"},
		"--email":          {"disable"},
		"--name":           {"create-admin", "--email", "a@example.com"},
		"flag provided but": {"enable", "--colour", "red"},
	}
	for want, args := range cases {
		if args[0] == "no command" {
			args = nil
		}
		err := run(context.Background(), args, &bytes.Buffer{})
		if err == nil || !strings.Contains(err.Error(), want) {
			t.Errorf("%v: %v, want a mention of %q", args, err, want)
		}
	}
	if err := run(context.Background(), []string{"promote", "--email", "a@example.com"}, &bytes.Buffer{}); err == nil || !strings.Contains(err.Error(), "usage") {
		t.Errorf("an unknown command: %v", err)
	}
}
```

Run: `go test ./cmd/staff/`. Expected: FAIL, `undefined: run`.

- [ ] **Step 2: Write the command**

Create `cmd/staff/main.go`:

```go
// Command staff manages staff members from a host with database access. It
// is the only way to create, disable, enable or reset an admin; it manages
// moderators too.
//
//	go run ./cmd/staff create-admin --email a@example.com --name "An Nguyen"
//	go run ./cmd/staff disable --email a@example.com
//
// The commands are create-admin, disable, enable, reset-password and
// reset-totp. create-admin and reset-password print the temporary password.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/user"
	"slices"
	"time"

	"github.com/shopnexus/server2/internal/platform/audit"
	"github.com/shopnexus/server2/internal/platform/config"
	"github.com/shopnexus/server2/internal/platform/postgres"
	"github.com/shopnexus/server2/internal/staff"
	"github.com/shopnexus/server2/internal/staff/member"
)

const usage = "usage: staff create-admin --email <email> --name <name>\n" +
	"       staff disable|enable|reset-password|reset-totp --email <email>"

var commands = []string{"create-admin", "disable", "enable", "reset-password", "reset-totp"}

func main() {
	if err := run(context.Background(), os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "staff:", err)
		os.Exit(1)
	}
}

func run(ctx context.Context, args []string, out io.Writer) error {
	if len(args) == 0 || !slices.Contains(commands, args[0]) {
		return errors.New(usage)
	}
	cmd := args[0]
	fs := flag.NewFlagSet(cmd, flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	email := fs.String("email", "", "the member's email")
	name := fs.String("name", "", "the display name, for create-admin")
	if err := fs.Parse(args[1:]); err != nil {
		return fmt.Errorf("%w\n%s", err, usage)
	}
	switch {
	case *email == "":
		return errors.New("--email is required")
	case cmd == "create-admin" && *name == "":
		return errors.New("--name is required for create-admin")
	default:
	}

	osUser, err := user.Current()
	if err != nil {
		return fmt.Errorf("current OS user: %w", err)
	}
	if err = config.LoadDotEnv(".env"); err != nil {
		return fmt.Errorf("load .env: %w", err)
	}
	cfg, err := config.Load(os.LookupEnv)
	if err != nil {
		return fmt.Errorf("config:\n%w", err)
	}
	pool, err := postgres.NewPool(ctx, cfg.DatabaseURL)
	if err != nil {
		return fmt.Errorf("connect to postgres: %w", err)
	}
	defer pool.Close()
	keys, err := staff.NewKeys(cfg.Staff, cfg.Auth, staff.ProductionHasher)
	if err != nil {
		return fmt.Errorf("staff keys: %w", err)
	}
	st := staff.NewStores(pool, keys)
	by, now := audit.ByCLI(osUser.Username), time.Now()

	if cmd == "create-admin" {
		v, temp, createErr := staff.CreateMember(ctx, st.Members, keys.Hasher, *email, *name, member.RoleAdmin, by, now)
		if createErr != nil {
			return fmt.Errorf("create admin: %w", createErr)
		}
		fmt.Fprintf(out, "created admin %s (%s)\ntemporary password: %s\n", v.Email, v.ID, temp)
		return nil
	}
	m, err := st.Members.FindByEmail(ctx, member.NormalizeEmail(*email))
	if errors.Is(err, member.ErrNotFound) {
		return fmt.Errorf("no staff member has the email %s", *email)
	}
	if err != nil {
		return fmt.Errorf("find staff member: %w", err)
	}
	switch cmd {
	case "disable":
		_, err = staff.DisableMember(ctx, st, m.ID(), by, now)
	case "enable":
		_, err = staff.EnableMember(ctx, st, m.ID(), by, now)
	case "reset-password":
		var temp string
		if temp, err = staff.ResetMemberPassword(ctx, st, keys, m.ID(), by, now); err == nil {
			fmt.Fprintf(out, "temporary password: %s\n", temp)
		}
	default: // reset-totp
		_, err = staff.ResetMemberTOTP(ctx, st, m.ID(), by, now)
	}
	if err != nil {
		return fmt.Errorf("%s: %w", cmd, err)
	}
	fmt.Fprintf(out, "%s %s: done\n", cmd, m.Email())
	return nil
}
```

Run: `go test ./cmd/staff/`. Expected: `ok`.

- [ ] **Step 3: Name the command in `CLAUDE.md`**

In `CLAUDE.md`, under `## Commands`, add after the `make down` line:

```markdown
- `go run ./cmd/staff create-admin --email <email> --name <name>`: create a
  staff admin and print its temporary password. `disable`, `enable`,
  `reset-password` and `reset-totp` take `--email`. The API has no way to
  create or change an admin.
```

Run the writing checker on the added lines.

- [ ] **Step 4: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add cmd/staff CLAUDE.md
git commit -m "feat: cmd/staff manages admins

go run ./cmd/staff create-admin creates an admin and prints its temporary
password; disable, enable, reset-password and reset-totp take an email.
Each runs the use case the API runs, recorded with the OS user as a CLI
actor, and only the CLI may act on an admin.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Console CORS and the design record

**Files:**
- Create: `internal/platform/httpx/cors.go`, `internal/platform/httpx/cors_test.go`, `e2e/staff_cors_test.go`
- Modify: `internal/app/app.go`, `ARCHITECTURE.md`

**Interfaces:**
- Produces: `httpx.CORS(origin, prefix string) func(http.Handler) http.Handler`.

- [ ] **Step 1: Write the failing CORS test**

Create `internal/platform/httpx/cors_test.go`:

```go
package httpx

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestCORS(t *testing.T) {
	t.Parallel()
	next := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusTeapot) })
	h := CORS("http://console.test", "/v1/staff/")(next)
	serve := func(method, path, origin string, preflight bool) *httptest.ResponseRecorder {
		r := httptest.NewRequestWithContext(t.Context(), method, path, http.NoBody)
		if origin != "" {
			r.Header.Set("Origin", origin)
		}
		if preflight {
			r.Header.Set("Access-Control-Request-Method", "POST")
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, r)
		return w
	}

	w := serve(http.MethodOptions, "/v1/staff/session/refresh", "http://console.test", true)
	if w.Code != http.StatusNoContent || w.Header().Get("Access-Control-Allow-Origin") != "http://console.test" ||
		w.Header().Get("Access-Control-Allow-Credentials") != "true" ||
		w.Header().Get("Access-Control-Allow-Headers") != "Authorization, Content-Type, X-Requested-With" {
		t.Fatalf("preflight: %d %v", w.Code, w.Header())
	}
	if w := serve(http.MethodGet, "/v1/staff/me", "http://console.test", false); w.Code != http.StatusTeapot || w.Header().Get("Access-Control-Allow-Origin") != "http://console.test" {
		t.Fatalf("a request from the console: %d %v", w.Code, w.Header())
	}
	for name, w := range map[string]*httptest.ResponseRecorder{
		"another origin":   serve(http.MethodOptions, "/v1/staff/me", "http://evil.test", true),
		"the customer API": serve(http.MethodOptions, "/v1/accounts/me", "http://console.test", true),
		"no origin":        serve(http.MethodGet, "/v1/staff/me", "", false),
	} {
		if w.Header().Get("Access-Control-Allow-Origin") != "" || w.Code != http.StatusTeapot {
			t.Errorf("%s: %d %v", name, w.Code, w.Header())
		}
	}
}
```

Run: `go test ./internal/platform/httpx/ -run CORS`. Expected: FAIL, `undefined: CORS`.

- [ ] **Step 2: Write `CORS` and wire it**

Create `internal/platform/httpx/cors.go`:

```go
package httpx

import (
	"net/http"
	"strings"
)

// CORS answers cross-origin requests from origin to paths under prefix, with
// credentials so the staff refresh cookie travels. Other origins and other
// paths get no CORS headers, so the browser refuses them; the customer API
// is called from the app, not a browser.
func CORS(origin, prefix string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !strings.HasPrefix(r.URL.Path, prefix) || r.Header.Get("Origin") != origin {
				next.ServeHTTP(w, r)
				return
			}
			h := w.Header()
			h.Set("Access-Control-Allow-Origin", origin)
			h.Set("Access-Control-Allow-Credentials", "true")
			h.Add("Vary", "Origin")
			if r.Method == http.MethodOptions && r.Header.Get("Access-Control-Request-Method") != "" {
				h.Set("Access-Control-Allow-Methods", "GET, POST, PUT")
				h.Set("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Requested-With")
				h.Set("Access-Control-Max-Age", "600")
				w.WriteHeader(http.StatusNoContent)
				return
			}
			next.ServeHTTP(w, r)
		})
	}
}
```

In `internal/app/app.go`, in `New`, wrap the validator so a preflight, which the spec does not describe, is answered before it:

```go
	cors := httpx.CORS(cfg.Staff.ConsoleOrigin, "/v1/staff/")
	a.Handler = httpx.Trace(httpx.Recover(log)(httpx.AccessLog(log)(cors(validate(a.router)))))
```

Run: `go test ./internal/platform/httpx/`. Expected: `ok`.

- [ ] **Step 3: Check the preflight end to end**

Create `e2e/staff_cors_test.go`. A preflight is not an operation in the spec, so this test calls the server without `call`:

```go
package e2e

import (
	"net/http"
	"testing"
)

func TestStaffCORSPreflight(t *testing.T) {
	t.Parallel()
	preflight := func(path, origin string) *http.Response {
		req, err := http.NewRequestWithContext(t.Context(), http.MethodOptions, server+path, http.NoBody)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Origin", origin)
		req.Header.Set("Access-Control-Request-Method", "POST")
		req.Header.Set("Access-Control-Request-Headers", "x-requested-with")
		res, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		_ = res.Body.Close()
		return res
	}
	if res := preflight("/v1/staff/session/refresh", "http://console.e2e"); res.StatusCode != http.StatusNoContent ||
		res.Header.Get("Access-Control-Allow-Origin") != "http://console.e2e" || res.Header.Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatalf("the console: %d %v", res.StatusCode, res.Header)
	}
	if res := preflight("/v1/staff/session/refresh", "http://evil.e2e"); res.Header.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("another origin: %v", res.Header)
	}
	if res := preflight("/v1/accounts/me", "http://console.e2e"); res.Header.Get("Access-Control-Allow-Origin") != "" {
		t.Fatalf("the customer API: %v", res.Header)
	}
}
```

- [ ] **Step 4: Record the design in `ARCHITECTURE.md`**

Add a section after `### Session use cases`:

```markdown
### Staff and authorization

Moderators and admins run the web console on staff accounts of their own
(module `staff`), never on a customer account with a role.
`~/shopnexus/specs/2026-10-24-server2-staff-authorization-design.md` holds
the decisions and the API.

- Sign-in takes an email and password, then up to two more calls with a
  five-minute ticket (audience `shopnexus-staff-login`): replace the
  temporary password, enroll TOTP, enter a code. The server computes the
  next step from the member. An unknown email, a wrong password and a
  disabled member all get `invalid_credentials`, and five failures on one
  email lock it for 15 minutes whether or not the email is a member's. The
  lock is keyed by an HMAC of the email (`staff_login_quotas`), and only a
  finished sign-in clears the count.
- A session lasts 8 hours. Its refresh token lives in an `HttpOnly; Secure;
  SameSite=Strict` cookie on `/v1/staff/session`, and the refresh call needs
  `X-Requested-With: shopnexus-console`. Access tokens (audience
  `shopnexus-staff`) last 5 minutes and carry no role.
- `staff.Require(..., floor)` reads the session and the member on every
  request. A session lives while it is unrevoked, younger than 8 hours,
  its member is active, and its credentials version equals the member's.
  A password change or reset, a TOTP reset and a disable raise the version,
  which ends every session without touching `staff_sessions`; enabling a
  member brings none back.
- Admins exist only through `cmd/staff`. The API manages moderators, and
  `Member.ManagedBy` refuses an admin target to anyone but the CLI.
- Every staff write and sign-in event is a row in `staff_actions`, written
  by `audit.Insert` inside the adapter transaction of the change
  (`SaveAudited`, `CreateAudited`). `audit.Diff` takes view structs, so no
  hash or secret reaches a row.
- TOTP secrets are sealed with AES-GCM under a key HKDF derives from
  `STAFF_KEY`, bound to the member's id. Passwords are argon2id
  (64 MiB, 3 passes, 4 lanes) in PHC form.
- Staff reaches customer data through ports it declares: `AccountPort`
  (`account.Client`) and `IdentityPort` (`auth.Client`). CORS allows
  `STAFF_CONSOLE_ORIGIN` on `/v1/staff/` and nothing else.
```

and in `### Module layout`, after the paragraph about `Mount`, add: `` `staff.Mount` takes the `AccountPort` and `IdentityPort` it reads customers through, after account and auth have mounted. ``

Run `python3 ~/.claude/skills/humanizing-writing/ai-tells.py` on the new section and rewrite any hit.

- [ ] **Step 5: Run it by hand**

```bash
make run                      # terminal 1; appends STAFF_KEY to .env on first use
go run ./cmd/staff create-admin --email admin@example.com --name "Admin"   # terminal 2
```

Expected: `created admin admin@example.com (<id>)` and `temporary password: <16 characters>`. Then, with `TEMP` set to it:

```bash
STEP=$(curl -s localhost:8080/v1/staff/login -H 'Content-Type: application/json' \
  -d "{\"email\":\"admin@example.com\",\"password\":\"$TEMP\"}")
echo "$STEP"                  # next: change_password
TICKET=$(echo "$STEP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
STEP=$(curl -s localhost:8080/v1/staff/login/password -H 'Content-Type: application/json' \
  -d "{\"ticket\":\"$TICKET\",\"new_password\":\"a long admin password\"}")
TICKET=$(echo "$STEP" | python3 -c 'import json,sys; print(json.load(sys.stdin)["ticket"])')
SECRET=$(curl -s localhost:8080/v1/staff/login/totp-enrollment -H 'Content-Type: application/json' \
  -d "{\"ticket\":\"$TICKET\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["secret"])')
CODE=$(python3 -c 'import base64,hmac,hashlib,struct,time,sys; s=sys.argv[1]; k=base64.b32decode(s+"="*(-len(s)%8)); h=hmac.new(k,struct.pack(">Q",int(time.time())//30),hashlib.sha1).digest(); o=h[-1]&15; print("%06d"%((struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000))' "$SECRET")
curl -si localhost:8080/v1/staff/login/totp -H 'Content-Type: application/json' \
  -d "{\"ticket\":\"$TICKET\",\"code\":\"$CODE\"}"
```

Expected: `200`, a `Set-Cookie: staff_refresh=...; Path=/v1/staff/session; Max-Age=28800; HttpOnly; Secure; SameSite=Strict` header and a body with `access_token`. Use the token on `GET /v1/staff/me` (expect the admin) and `GET /v1/staff/actions` (expect `staff.create`, `staff.password_change`, `staff.totp_enroll` and `staff.login`). Then check the table holds no secret:

```bash
docker compose exec postgres psql -U server2 -c "SELECT action, diff FROM staff_actions ORDER BY id"
```

Expected: diffs with `"password": "changed"` and `"totp": "enrolled"`, and no hash, secret or code. Write down anything that differs and fix it in this task.

- [ ] **Step 6: Run the suite and commit**

Run: `make test`. Expected: every package `ok`, `0 issues.`

```bash
git add internal/platform/httpx internal/app e2e ARCHITECTURE.md
git commit -m "feat: CORS for the staff console, and the staff design in ARCHITECTURE.md

httpx.CORS answers the console's origin on /v1/staff/ with credentials,
before request validation, and sends nothing to other origins or to the
customer API. ARCHITECTURE.md records how staff sign in, how a session
ends, who manages admins and how the audit log is written.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
