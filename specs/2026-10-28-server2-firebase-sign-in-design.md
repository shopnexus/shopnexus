# Design: server2 sign-in through Firebase

Date: 2026-10-28.
Status: decided in conversation, question by question. It settles the
server2 proposals in `2026-10-27-phone-verification-design.md`. When the
work lands, the decisions below go into `~/shopnexus/server2/ARCHITECTURE.md`.

## Scope

The app verifies a phone number through Firebase: Phone Number
Verification (PNV) on the SIM, or an SMS code through Firebase
Authentication. It sends the token Firebase returns to server2, which
checks it, signs the person in, and creates the account on first use.
Server2 stops sending codes. Sign-in by email goes, so every account has a
phone number. Staff sign-in (email, password, TOTP) is a separate flow and
does not change.

In September 2026 PNV covered no Vietnamese carrier, so people in Vietnam
take the SMS path until Google adds one. An installed app uses a new
carrier without an update, and server2 already accepts its tokens.

## Decisions

| Question | Decision |
|---|---|
| Email OTP | Removed with the rest of server2's OTP: endpoints, challenges, quotas, the SMS and email senders, email identities. |
| Accounts with only an email | Deleted by the migration. |
| Acting without a phone | `phone_required` goes from posting a listing, opening a deal and opening a chat; every account has a phone. |
| Endpoint | `POST /v1/auth/sign-in {phone_token}` with an `Idempotency-Key`. The token's `iss` tells PNV from Firebase Authentication. |
| Replay of a token | Accepted until `exp`, and only within 5 minutes of the verification: `auth_time` for Firebase Authentication, `iat` for PNV. |
| Keys | Fetched from JWKS URLs in the configuration; e2e serves its own keys and signs its own tokens. |
| Firebase user records | Left alone. The app signs out of Firebase once it has the token. |
| Key fetching | Written in server2 on `golang-jwt/jwt/v5`, with no JWKS library. |
| Foreign numbers | 422 `invalid_phone`, as today: Vietnamese mobile numbers only. |

## API

`POST /v1/auth/sign-in`, `Idempotency-Key` required.

```json
{"phone_token": "eyJhbGciOi...", "device_name": "Pixel 9"}
```

`device_name` is optional, at most 100 characters, and names the session
in the device list, as it does today. The body takes no other field. The answer is the existing `SignIn`
schema: the access and refresh tokens and `account {id, is_new}`.

| Status | Code | When |
|---|---|---|
| 200 | | Signed in; `is_new` when this call created the account. |
| 400 | `invalid_request` | No key, a malformed body. |
| 401 | `invalid_phone_token` | Any failed check below. The log records which one. |
| 401 | `session_revoked`, `session_expired` | A repeated key whose session was signed out since. |
| 403 | `account_suspended` | |
| 409 | `try_again` | A lost race while creating or saving, as today. |
| 422 | `invalid_phone` | The verified number is not a Vietnamese mobile. |
| 503 | `unavailable` | No signing keys could be fetched yet. `apperr` gains `KindUnavailable` for it. |

`POST /v1/auth/otp`, `POST /v1/auth/otp/verify`, their schemas, the codes
`invalid_code`, `code_expired`, `code_locked`, `otp_too_soon`, `otp_limit`
and `phone_required` leave the spec.

## Flow

1. The HTTP handler verifies the token and gets the number in the +84
   form. The token stays out of Restate's journal, which the admin API
   can read.
2. It calls `SignIn.Run({phone, at})` with the invocation key
   `<phone>/<Idempotency-Key>`. A repeated key attaches only to a run for
   the same number, so the key alone gets no session.
3. `SignIn` keeps the second half of today's flow. A step finds the phone
   identity in `Credentials`. When found, a step reads the account status
   (suspended ends the run) and the next marks the identity used. When not
   found, it creates the `Account` with `restatex.NewID(ctx, at)`, then the
   `Credentials`; `ErrTaken` deletes the account again.
4. The handler issues the session after the service returns. A repeated key
   rotates that session's refresh token, as today.

The endpoint has no quota. Firebase limits code requests; this endpoint
checks a signature.

## Token checks

Package `internal/provider/firebase` holds `PhoneVerifier` with
`Verify(ctx, token) (contact.Address, error)`; module auth sees only that
interface. The verifier reads `iss` without the signature to pick the key
set, then verifies the token with that issuer's key set and algorithm
only.

| | Firebase Authentication (SMS) | PNV (SIM) |
|---|---|---|
| `alg` | RS256 | ES256, with `typ` `JWT` |
| `iss` | `https://securetoken.google.com/<project id>` | `https://fpnv.googleapis.com/projects/<project number>` |
| `aud` | `<project id>` | a list holding `https://fpnv.googleapis.com/projects/<project id>` |
| Fresh | `auth_time` within 5 minutes | `iat` within 5 minutes |
| Also | `firebase.sign_in_provider` is `phone` | `test_number: true` only with `PNV_TEST_NUMBERS=true` |
| Number | `phone_number` | `sub` |

For both: `exp` in the future, `iat` not in the future, with 30 seconds
of clock skew. The number goes through `contact.ParsePhone`. A PNV test
number is the country code followed by zeros and fails that check, so
with `PNV_TEST_NUMBERS=true` a test number is stored as it comes.

Key sets, one per URL:

- An EC key must be P-256 with its point on the curve; RSA keys are read
  from `n` and `e`. Other key types and keys whose `use` is not `sig` are
  skipped.
- Keys are cached for the `max-age` of `Cache-Control`. A response without
  `max-age` keeps its keys until a token names an unknown `kid`.
- An unknown `kid` fetches again, at most once a minute, so forged tokens
  with random `kid`s cannot make server2 call Google in a loop. Requests
  that arrive during a fetch wait for it.
- A failed fetch keeps the old keys. With no keys ever fetched, the
  endpoint answers 503 so the app retries instead of asking for a new SMS
  code.
- The HTTP client times out after 5 seconds.

## Removed

- Service `OTP`, aggregates `Challenge` and `Quota`, their repositories
  and tests.
- `internal/provider/sms`, `internal/provider/email`, the options
  `WithSMSSender` and `WithEmailSender`, and the production guard on those
  log senders.
- `contact.Parse`, which picked the parser by kind for the OTP request.
  `ParseEmail` and `NormalizeEmail` stay: staff members have emails.
- The identity kinds `email` and `google` (no code creates a Google
  identity), so the staff `Identity` schema lists `phone` only, and
  `FindAccount` looks up phone numbers only.
- `OTP_KEY`: `AuthConfig.OTPKey`, the key `cmd/keygen` prints and the
  `make run` check that looks for it.
- The `phone_required` checks of `ListingPost`, `OpenDeal` and the first
  message of a chat. Catalog, deal and chat then call nothing in module
  auth and lose it as a dependency. `authsvc.Service.Identities` stays for
  the staff account view.
- The e2e inbox stub, `emailAccount` and the tests of posting without a
  phone.

`identities` and `Credentials` stay, with the rule that an account keeps
at least one identity.

## Data

Migration `0022`:

1. `DROP TABLE otp_challenges, otp_quotas`.
2. Delete the identities whose kind is not `phone`, then the
   `credentials` rows left with no identity, then the accounts left with no
   credentials. None of the 21 foreign keys to `accounts` cascades, so an
   email-only account that owns listings or deals stops the migration with
   the key's name instead of deleting rows elsewhere. The development
   database had no such account on 2026-10-28; a database that has one is
   reset.
3. `ALTER TABLE identities ADD CHECK (kind = 'phone')`.

## Configuration

Every variable is set in every environment; a missing one stops the
process with its name.

| Variable | Development value | Notes |
|---|---|---|
| `FIREBASE_PROJECT_ID` | `shopnexus-26aca` | Replaces `FCM_PROJECT_ID`; push and sign-in share it. |
| `FIREBASE_PROJECT_NUMBER` | `5362373878` | Builds the PNV `iss`. |
| `FIREBASE_AUTH_JWKS_URL` | `https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com` | |
| `PNV_JWKS_URL` | `https://fpnv.googleapis.com/v1beta/jwks` | |
| `PNV_TEST_NUMBERS` | `true` | `true` or `false`; `APP_ENV=prod` with `true` stops the server. |

## Tests

`internal/provider/firebase/firebasetest`: `New(t)` serves a JWKS from
`httptest` with one RSA and one EC key and returns the configuration that
points at it. `SMSToken(phone)` and `PNVToken(phone)` sign valid tokens;
options set one claim wrong. The app, auth service and e2e tests use it,
and e2e's `newAccount` signs an SMS token for a random Vietnamese number
and calls `/v1/auth/sign-in`.

- `firebase`: each check in the table refuses a token with that claim
  wrong; a wrong `alg`; an unknown `kid` fetches once and then waits a
  minute; a failed fetch keeps the old keys; no keys gives the unavailable
  error.
- `SignIn`: a new account, a known one, a suspended one, and the
  `ErrTaken` race, with the input `{phone, at}`.
- e2e: the first sign-in is new and the second is not, with the same
  account; a repeated key with the same number gets the same session; the
  same key with another number runs apart; a forged and a stale token get
  401; a foreign number gets 422; a suspended account gets 403.
- app: `APP_ENV=prod` with `PNV_TEST_NUMBERS=true` stops `New`.

e2e serves the PNV keys from a URL that fails for the whole run, so a PNV
token gets the 503 the spec declares; the PNV checks run in the
`firebase` tests.
