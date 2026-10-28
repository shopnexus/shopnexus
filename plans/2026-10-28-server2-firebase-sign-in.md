# Firebase Sign-In Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace server2's OTP sign-in with `POST /v1/auth/sign-in`, which checks a phone token from Firebase (SMS through Firebase Authentication, or PNV from the SIM) and signs the person in.

**Architecture:** A new provider package `internal/provider/firebase` fetches and caches the JWKS of both issuers and verifies tokens on `golang-jwt/jwt/v5`. Module auth's HTTP handler verifies the token, then calls the existing Restate `SignIn` service with only the proven number; the challenge half of that service, the OTP service, the SMS and email senders and email identities are deleted. `phone_required` goes from catalog, deal and chat, which then no longer depend on module auth.

**Tech Stack:** Go 1.27, `github.com/golang-jwt/jwt/v5` v5.3.1 (already in go.mod, the newest release), `crypto/ecdsa.ParseUncompressedPublicKey`, pgx v5, Restate Go SDK, PostgreSQL migrations.

**Spec:** `~/shopnexus/specs/2026-10-28-server2-firebase-sign-in-design.md`

## Global Constraints

- Configuration has no defaults; every variable is set in every environment and a missing one stops the process with its name.
- New variables: `FIREBASE_PROJECT_ID` (replaces `FCM_PROJECT_ID`), `FIREBASE_PROJECT_NUMBER`, `FIREBASE_AUTH_JWKS_URL`, `PNV_JWKS_URL`, `PNV_TEST_NUMBERS` (`true` or `false`). `OTP_KEY` goes.
- `APP_ENV=prod` with `PNV_TEST_NUMBERS=true` stops `app.New`.
- Tokens never enter Restate's journal; the handler verifies, Restate receives the number.
- The invocation key of `SignIn` is `<phone>/<Idempotency-Key>`.
- Freshness: 5 minutes (`auth_time` for Firebase Authentication, `iat` for PNV); clock skew 30 seconds.
- A key set fetches at most once a minute; HTTP timeout 5 seconds.
- A use case, Restate handler or HTTP handler reads top to bottom; no helper called from one place.
- Scratch files and logs go in `tmp/`, never `/tmp`.
- Prose in files (comments, ARCHITECTURE.md, commit messages) goes through `python3 ~/.claude/skills/humanizing-writing/ai-tells.py --stats <file>`.
- Before multi-package test runs, recreate the test Restate: `docker compose -f docker-compose.test.yml up -d --wait --force-recreate restate`.

## Review Focus

1. A token whose header says `alg: none`, or HS256 keyed with the RSA public key: refused with `invalid_phone_token` (Task 4 test `TestVerifyRefusesAlgorithmSwaps`).
2. A JWKS response that is not JSON, or larger than 1 MB: the fetch fails and the keys held stay in use (Task 3 test `TestKeySetBadBodyKeepsTheKeys`).
3. Parallel first sign-ins of one new number with different keys: exactly one account, every reply 200 or 409 (Task 5 test `TestSignInRace`).
4. A Firebase Authentication token from another sign-in method (`sign_in_provider` `password`, no `phone_number`): 401, never an account without a number (Task 4 table rows "another provider", "no phone_number").
5. Phone clocks running ahead: a token issued 20 seconds in the future passes; one 60 seconds ahead is refused (Task 4 rows "iat 20 s ahead", "iat 60 s ahead").

---

### Task 1: phone_required removal in catalog, deal and chat

Every account will have a phone number, so posting a listing, opening a deal and opening a chat stop asking module auth. The three modules lose their `authsvc.Service` dependency.

**Files:**
- Modify: `internal/catalog/service/listing_post_durable.go` (the `hasPhone` step, the `Auth` field, the `Run` doc comment), `internal/catalog/service/service.go` (`Deps.Auth`, `Catalog.auth`, the `Auth:` passed to `ListingPost` in `Durable`), `internal/catalog/catalog.go` (`Mount` loses `auth`), `internal/catalog/domain/errors.go` (`ErrPhoneRequired`)
- Modify: `internal/deal/service/deal_open.go:38-44`, `internal/deal/service/service.go` (`Deps.Auth`, `auth`), `internal/deal/deal.go` (`Mount` loses `auth`), `internal/deal/domain/errors.go` (`ErrPhoneRequired`)
- Modify: `internal/chat/service/message_send_durable.go` (`HasPhone` and the `Identities` read, the `phone_required` case), `internal/chat/service/service.go` (`Deps.Auth`, `auth`), `internal/chat/chat.go` (`Mount` loses `auth`), `internal/chat/domain/errors.go` (`ErrPhoneRequired`)
- Modify: `internal/app/app.go` (the three `Mount` calls drop `authm.Service`)
- Modify: `api/paths/catalog.yaml:8,33`, `api/paths/deal.yaml:8,36`, `api/paths/chat.yaml:7,32` (remove `phone_required` from the descriptions)
- Test: `internal/catalog/service/listing_test.go:40-42`, `internal/catalog/service/helpers_test.go:62`, `internal/deal/service/deal_test.go:115`, `internal/deal/service/helpers_test.go` (`emailOnly`, `Auth:`), `internal/chat/service/chat_test.go:80`, `internal/chat/service/helpers_test.go` (`emailOnly`, `Auth:`), `e2e/catalog_test.go:109-121,192-194`, `e2e/deal_test.go:166`, `e2e/chat_test.go:147`

**Interfaces:**
- Produces: `catalog.Mount(d, g, accounts, media)`, `deal.Mount(d, protect, accounts, catalog)`, `chat.Mount(d, protect, accounts, catalog, media)`.

- [ ] **Step 1: Turn the three "no phone" cases into cases that pass**

In `internal/catalog/service/listing_test.go` replace lines 40-42 with:

```go
	if _, err := e.catalog.Post(ctx, e.account(t), uuid.NewV7().String(), bad); !errors.Is(err, domain.ErrInvalidListing) {
		t.Fatalf("an account without a phone reaches the draft's checks: %v", err)
	}
```

(`bad` has a root category, so the post gets past the account checks and stops at the draft; check the name of the draft error in `internal/catalog/domain/errors.go` and use it.)

In `internal/deal/service/deal_test.go`, remove the row `{"no phone", e.emailOnly(t), listing, domain.ErrPhoneRequired},` and add after the loop:

```go
	if _, created, err := e.deals.Open(ctx, e.emailOnly(t), listing); err != nil || !created {
		t.Fatalf("an account without a phone opens a deal: %v %v", created, err)
	}
```

In `internal/chat/service/chat_test.go`, remove the row `{"no phone", e.emailOnly(t), listing, domain.ErrPhoneRequired},` and add after the loop:

```go
	if _, err := e.chat.Open(ctx, e.emailOnly(t), key(), service.OpenInput{ListingID: listing, Text: "Còn không?"}); err != nil {
		t.Fatalf("an account without a phone opens a chat: %v", err)
	}
```

Rename `emailOnly` to `phoneless` in both helpers files and both tests, with the comment `// phoneless creates an account with no identity.`

- [ ] **Step 2: Run them and watch them fail**

Run: `go test -count=1 ./internal/catalog/service/ ./internal/deal/service/ ./internal/chat/service/ 2>&1 | grep -E '^(---|ok|FAIL)|phone' | head -20`
Expected: three FAILs, each with `phone_required` in the error.

- [ ] **Step 3: Remove the checks and the dependency**

- `listing_post_durable.go`: delete the `hasPhone` step and its `if !hasPhone` block, the `Auth authsvc.Service` field, and the now unused imports (`slices`, `authsvc`, `authdomain`). The `Run` comment becomes: `// Run checks, in order, that the seller is not suspended and is under the cap, then the draft.` followed by the existing sentences about the row and the uploads.
- `deal_open.go`: delete lines 38-44 (the `Identities` read and the `ErrPhoneRequired` return) and the unused imports.
- `message_send_durable.go`: delete the `ids, readErr := s.Chat.auth.Identities(...)` block and the `out.HasPhone = ...` line, keep `if out.Listing != nil { other = out.Listing.SellerID }` inside `if in.Opening`, delete the `HasPhone` field from the facts struct and the `case in.Opening && !f.HasPhone:` arm.
- Delete `ErrPhoneRequired` from the three `domain/errors.go` files.
- Remove `Auth` from the three `service.Deps`, the `auth` field from the three service structs and their `New`, and the `auth authsvc.Service` parameter from the three `Mount` functions; fix `internal/app/app.go`:

```go
	catalogm := catalog.Mount(d, catalog.Guards{Protect: protect, Identify: auth.Identify(d, cfg.Auth)},
		accounts, mediam.Service)
	dealm := deal.Mount(d, protect, accounts, catalogm.Service)
	...
	chatm := chat.Mount(d, protect, accounts, catalogm.Service, mediam.Service)
```

- Test helpers: drop `Auth:` from the `service.Deps` literals in the three `helpers_test.go` files and any `authsvc`/`authrepo` imports left unused. Keep the helpers that give test accounts a phone identity (`seller`, `person`): they still build accounts the way sign-in does.
- API: in the three path files remove `phone_required` from the descriptions, e.g. `"The account is suspended (account_suspended), or a block stands between the buyer and the seller (blocked)."`
- e2e: delete `emailAccount` (`e2e/catalog_test.go:109-121`) and the three `phone_required` expectations (`catalog_test.go:192-194`, `deal_test.go:166`, `chat_test.go:147`).

- [ ] **Step 4: Run the packages and e2e**

Run: `docker compose -f docker-compose.test.yml up -d --wait --force-recreate restate >tmp/restate.log 2>&1; go build ./... && go test -count=1 ./internal/catalog/... ./internal/deal/... ./internal/chat/... ./internal/app/ ./e2e/ 2>&1 | grep -E '^(---|ok|FAIL)'`
Expected: every package `ok`. `grep -rn 'phone_required\|ErrPhoneRequired' internal api e2e` prints nothing.

- [ ] **Step 5: Commit**

```bash
git add -A internal api e2e
git commit -m "refactor: posting, deals and chats no longer ask for a phone

Every account will have a phone number once sign-in goes through
Firebase. Catalog, deal and chat stop reading identities and lose module
auth as a dependency.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Firebase configuration

**Files:**
- Modify: `internal/platform/config/config.go` (`Config.Firebase`, `FirebaseConfig`, `PushConfig` loses `ProjectID`, `Load`)
- Modify: `internal/app/app.go` (`push.NewFCM(..., cfg.Firebase.ProjectID)`)
- Modify: `.env.example`, the local `.env`
- Test: `internal/platform/config/config_test.go`

**Interfaces:**
- Produces: `config.FirebaseConfig{ProjectID, ProjectNumber, AuthJWKSURL, PNVJWKSURL string; TestNumbers bool}` at `Config.Firebase`; `config.PushConfig{Credentials []byte}`.

- [ ] **Step 1: Write the failing config tests**

In `config_test.go`'s `required()`, remove `"FCM_PROJECT_ID": ""` and add:

```go
		"FIREBASE_PROJECT_ID":          "shopnexus-test",
		"FIREBASE_PROJECT_NUMBER":      "123456789",
		"FIREBASE_AUTH_JWKS_URL":       "https://keys.example.test/auth",
		"PNV_JWKS_URL":                 "https://keys.example.test/pnv",
		"PNV_TEST_NUMBERS":             "false",
```

In `TestLoadAllSet`, add `"PNV_TEST_NUMBERS": "true"` to the overrides and to `want`:

```go
		Firebase: FirebaseConfig{
			ProjectID: "shopnexus-test", ProjectNumber: "123456789",
			AuthJWKSURL: "https://keys.example.test/auth", PNVJWKSURL: "https://keys.example.test/pnv", TestNumbers: true,
		},
```

Replace the test that set `FCM_CREDENTIALS` without `FCM_PROJECT_ID` (around line 269) with:

```go
	env["FCM_CREDENTIALS"] = b64([]byte(`{"type":"service_account"}`))
	if got, err := Load(lookup(env)); err != nil || string(got.Push.Credentials) != `{"type":"service_account"}` {
		t.Fatalf("credentials: %v", err)
	}
```

and add to the table of bad values (the one with `"short otp key"`):

```go
		{"no firebase project", map[string]string{"FIREBASE_PROJECT_ID": ""}, "FIREBASE_PROJECT_ID"},
		{"test numbers not a bool", map[string]string{"PNV_TEST_NUMBERS": "yes"}, "PNV_TEST_NUMBERS"},
```

and a missing-variable check for `PNV_JWKS_URL` in whatever form the file already tests a missing variable.

- [ ] **Step 2: Run and watch them fail**

Run: `go test -count=1 ./internal/platform/config/ 2>&1 | tail -15`
Expected: compile error `unknown field Firebase` / `undefined: FirebaseConfig`.

- [ ] **Step 3: Implement**

In `config.go` add to `Config` after `Push`:

```go
	Firebase       FirebaseConfig
```

Replace `PushConfig` and add `FirebaseConfig`:

```go
// PushConfig says how pushes reach phones. Empty credentials mean the log
// sender. The credentials are never logged.
type PushConfig struct {
	Credentials []byte //exhaustruct:optional FCM_CREDENTIALS: a service account's JSON in base64, or empty
}

// FirebaseConfig names the Firebase project that pushes go through and phone
// tokens come from, and where the keys that sign those tokens are published.
type FirebaseConfig struct {
	ProjectID     string // FIREBASE_PROJECT_ID
	ProjectNumber string // FIREBASE_PROJECT_NUMBER: builds the issuer of PNV tokens
	AuthJWKSURL   string // FIREBASE_AUTH_JWKS_URL: the keys of Firebase Authentication's ID tokens
	PNVJWKSURL    string // PNV_JWKS_URL: the keys of Phone Number Verification tokens
	TestNumbers   bool   // PNV_TEST_NUMBERS: accept the test numbers of PNV's test mode; never in prod
}
```

In `Load`, replace the push block with:

```go
	var push PushConfig
	if raw := set("FCM_CREDENTIALS"); raw != "" {
		b, err := base64.StdEncoding.DecodeString(raw)
		if err != nil {
			errs = append(errs, errors.New("FCM_CREDENTIALS: want base64 of a service account's JSON"))
		}
		push.Credentials = b
	}
```

and add to the `cfg` literal after `Push: push,`:

```go
		Firebase: FirebaseConfig{
			ProjectID:     need("FIREBASE_PROJECT_ID"),
			ProjectNumber: need("FIREBASE_PROJECT_NUMBER"),
			AuthJWKSURL:   need("FIREBASE_AUTH_JWKS_URL"),
			PNVJWKSURL:    need("PNV_JWKS_URL"),
			TestNumbers:   oneOf("PNV_TEST_NUMBERS", "true", "false") == "true",
		},
```

In `internal/app/app.go` change the FCM line to `push.NewFCM(context.Background(), cfg.Push.Credentials, cfg.Firebase.ProjectID)`.

In `.env.example` replace the push block with:

```
# Firebase: the project pushes go through and phone tokens come from, and
# where the keys that sign those tokens are published.
FIREBASE_PROJECT_ID=shopnexus-26aca
FIREBASE_PROJECT_NUMBER=5362373878
FIREBASE_AUTH_JWKS_URL=https://www.googleapis.com/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com
PNV_JWKS_URL=https://fpnv.googleapis.com/v1beta/jwks
# Accept the test numbers of PNV's test mode; APP_ENV=prod refuses true.
PNV_TEST_NUMBERS=true
# Pushes through Firebase Cloud Messaging: a service account's JSON in
# base64. Empty writes pushes to the log instead.
FCM_CREDENTIALS=
```

Update the local `.env` (git-ignored); its other values stay:

```bash
sed -i '/^FCM_PROJECT_ID=/d' .env
grep -q '^FIREBASE_PROJECT_ID=' .env || sed -n '/^# Firebase: the project/,/^PNV_TEST_NUMBERS=/p' .env.example >> .env
```

- [ ] **Step 4: Run**

Run: `go build ./... && go test -count=1 ./internal/platform/config/ ./internal/app/ 2>&1 | tail -5`
Expected: `ok` for both (the app tests build `config.Config` literals; `Firebase` is unread until Task 5).

- [ ] **Step 5: Commit**

```bash
git add internal/platform/config internal/app .env.example
git commit -m "feat: Firebase configuration for phone tokens

FIREBASE_PROJECT_ID replaces FCM_PROJECT_ID, so pushes and sign-in share
the project. FIREBASE_PROJECT_NUMBER, FIREBASE_AUTH_JWKS_URL, PNV_JWKS_URL
and PNV_TEST_NUMBERS are required in every environment.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Key sets from a JWKS URL

**Files:**
- Create: `internal/provider/firebase/keys.go`
- Modify: `internal/platform/apperr/apperr.go` (`KindUnavailable`), `internal/platform/httpx/respond.go` (503)
- Test: `internal/provider/firebase/keys_test.go` (package `firebase`, internal)

**Interfaces:**
- Produces: `type keySet struct{url string; http *http.Client; now func() time.Time; log *slog.Logger; ...}`, `func (s *keySet) key(ctx context.Context, kid string) (crypto.PublicKey, error)`, `var ErrUnavailable` (apperr `KindUnavailable`, code `unavailable`), `var errUnknownKey`, `apperr.KindUnavailable` → HTTP 503.

- [ ] **Step 1: Write the failing tests**

`internal/provider/firebase/keys_test.go`:

```go
package firebase

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"log/slog"
	"math/big"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

var start = time.Date(2026, 10, 28, 9, 0, 0, 0, time.UTC)

// server serves body with cacheControl, or status when it is not 200, and
// counts requests.
type server struct {
	mu           sync.Mutex
	status       int
	body         string
	cacheControl string
	hits         atomic.Int32
}

func (s *server) set(status int, body, cacheControl string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.status, s.body, s.cacheControl = status, body, cacheControl
}

func (s *server) ServeHTTP(w http.ResponseWriter, _ *http.Request) {
	s.hits.Add(1)
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cacheControl != "" {
		w.Header().Set("Cache-Control", s.cacheControl)
	}
	w.WriteHeader(s.status)
	_, _ = w.Write([]byte(s.body))
}

func b64(b []byte) string { return base64.RawURLEncoding.EncodeToString(b) }

func ecJWK(t *testing.T, kid string) (map[string]string, *ecdsa.PublicKey) {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	pt, err := k.PublicKey.Bytes() // 0x04 || X || Y
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"kty": "EC", "crv": "P-256", "kid": kid, "use": "sig", "x": b64(pt[1:33]), "y": b64(pt[33:])}, &k.PublicKey
}

func rsaJWK(t *testing.T, kid string, bits int) (map[string]string, *rsa.PublicKey) {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, bits)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{
		"kty": "RSA", "kid": kid, "use": "sig", "n": b64(k.N.Bytes()), "e": b64(big.NewInt(int64(k.E)).Bytes()),
	}, &k.PublicKey
}

func doc(t *testing.T, keys ...map[string]string) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{"keys": keys})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

// newSet is a key set on srv with its clock at *at.
func newSet(t *testing.T, srv *server, at *time.Time) *keySet {
	t.Helper()
	ts := httptest.NewServer(srv)
	t.Cleanup(ts.Close)
	return &keySet{url: ts.URL, http: ts.Client(), now: func() time.Time { return *at }, log: slog.New(slog.DiscardHandler)}
}

func TestKeySetReadsECAndRSAKeys(t *testing.T) {
	t.Parallel()
	ec, ecPub := ecJWK(t, "ec")
	rs, rsaPub := rsaJWK(t, "rsa", 2048)
	small, _ := rsaJWK(t, "small", 1024)
	enc, _ := ecJWK(t, "enc")
	enc["use"] = "enc"
	offCurve, _ := ecJWK(t, "off")
	offCurve["y"] = b64(make([]byte, 32))
	srv := &server{}
	srv.set(http.StatusOK, doc(t, ec, rs, small, enc, offCurve, map[string]string{"kty": "oct", "kid": "oct", "k": "AAAA"}), "")
	at := start
	s := newSet(t, srv, &at)
	ctx := context.Background()
	if k, err := s.key(ctx, "ec"); err != nil || !k.(*ecdsa.PublicKey).Equal(ecPub) {
		t.Fatalf("ec: %v", err)
	}
	if k, err := s.key(ctx, "rsa"); err != nil || !k.(*rsa.PublicKey).Equal(rsaPub) {
		t.Fatalf("rsa: %v", err)
	}
	for _, kid := range []string{"small", "enc", "off", "oct"} {
		if _, err := s.key(ctx, kid); !errors.Is(err, errUnknownKey) {
			t.Errorf("%s is held: %v", kid, err)
		}
	}
}

func TestKeySetCachesForMaxAge(t *testing.T) {
	t.Parallel()
	ec, _ := ecJWK(t, "ec")
	srv := &server{}
	srv.set(http.StatusOK, doc(t, ec), "public, max-age=3600, must-revalidate")
	at := start
	s := newSet(t, srv, &at)
	for range 3 {
		if _, err := s.key(context.Background(), "ec"); err != nil {
			t.Fatal(err)
		}
	}
	if n := srv.hits.Load(); n != 1 {
		t.Fatalf("fetches within max-age: %d", n)
	}
	at = start.Add(time.Hour)
	if _, err := s.key(context.Background(), "ec"); err != nil || srv.hits.Load() != 2 {
		t.Fatalf("after max-age: %v, %d fetches", err, srv.hits.Load())
	}
}

// An unknown kid fetches again, at most once a minute, so forged kids
// cannot make the server call Google in a loop.
func TestKeySetUnknownKidFetchesOnceAMinute(t *testing.T) {
	t.Parallel()
	ec, _ := ecJWK(t, "ec")
	srv := &server{}
	srv.set(http.StatusOK, doc(t, ec), "")
	at := start
	s := newSet(t, srv, &at)
	ctx := context.Background()
	if _, err := s.key(ctx, "ec"); err != nil {
		t.Fatal(err)
	}
	for _, kid := range []string{"forged-1", "forged-2"} {
		if _, err := s.key(ctx, kid); !errors.Is(err, errUnknownKey) {
			t.Fatalf("%s: %v", kid, err)
		}
	}
	if n := srv.hits.Load(); n != 1 {
		t.Fatalf("unknown kids within a minute fetched: %d", n)
	}
	rotated, _ := ecJWK(t, "rotated")
	srv.set(http.StatusOK, doc(t, ec, rotated), "")
	at = start.Add(time.Minute)
	if _, err := s.key(ctx, "rotated"); err != nil || srv.hits.Load() != 2 {
		t.Fatalf("a key published since: %v, %d fetches", err, srv.hits.Load())
	}
}

func TestKeySetFailedFetchKeepsTheKeys(t *testing.T) {
	t.Parallel()
	ec, _ := ecJWK(t, "ec")
	srv := &server{}
	srv.set(http.StatusOK, doc(t, ec), "max-age=60")
	at := start
	s := newSet(t, srv, &at)
	if _, err := s.key(context.Background(), "ec"); err != nil {
		t.Fatal(err)
	}
	srv.set(http.StatusServiceUnavailable, "down", "")
	at = start.Add(2 * time.Minute)
	if _, err := s.key(context.Background(), "ec"); err != nil || srv.hits.Load() != 2 {
		t.Fatalf("a failed refresh: %v, %d fetches", err, srv.hits.Load())
	}
}

func TestKeySetBadBodyKeepsTheKeys(t *testing.T) {
	t.Parallel()
	ec, _ := ecJWK(t, "ec")
	srv := &server{}
	srv.set(http.StatusOK, doc(t, ec), "max-age=60")
	at := start
	s := newSet(t, srv, &at)
	if _, err := s.key(context.Background(), "ec"); err != nil {
		t.Fatal(err)
	}
	for i, body := range []string{"<html>", `{"keys": [` + strings.Repeat(`{"kty":"EC"},`, 1<<17) + `{}]}`} {
		srv.set(http.StatusOK, body, "")
		at = start.Add(time.Duration(i+2) * time.Minute)
		if _, err := s.key(context.Background(), "ec"); err != nil {
			t.Fatalf("body %d replaced the keys: %v", i, err)
		}
	}
}

func TestKeySetWithoutKeysIsUnavailable(t *testing.T) {
	t.Parallel()
	srv := &server{}
	srv.set(http.StatusInternalServerError, "down", "")
	at := start
	s := newSet(t, srv, &at)
	for range 2 {
		if _, err := s.key(context.Background(), "ec"); !errors.Is(err, ErrUnavailable) {
			t.Fatalf("%v", err)
		}
	}
	if n := srv.hits.Load(); n != 1 {
		t.Fatalf("fetches within a minute while down: %d", n)
	}
}

func TestKeySetParallelLookupsFetchOnce(t *testing.T) {
	t.Parallel()
	ec, _ := ecJWK(t, "ec")
	srv := &server{}
	srv.set(http.StatusOK, doc(t, ec), "max-age=60")
	at := start
	s := newSet(t, srv, &at)
	var wg sync.WaitGroup
	for range 20 {
		wg.Go(func() {
			if _, err := s.key(context.Background(), "ec"); err != nil {
				t.Error(err)
			}
		})
	}
	wg.Wait()
	if n := srv.hits.Load(); n != 1 {
		t.Fatalf("parallel lookups fetched %d times", n)
	}
}
```

- [ ] **Step 2: Run and watch them fail**

Run: `go test -count=1 ./internal/provider/firebase/ 2>&1 | tail -5`
Expected: build failure, `undefined: keySet`.

- [ ] **Step 3: Implement**

In `internal/platform/apperr/apperr.go` add after `KindTooLarge`:

```go
	KindUnavailable                      // 503: a service this request needs is down; try again
```

In `internal/platform/httpx/respond.go` add to `statusOf`:

```go
	apperr.KindUnavailable:          http.StatusServiceUnavailable,
```

(If `respond_test.go` has a table over the kinds, add the row.)

`internal/provider/firebase/keys.go`:

```go
// Package firebase checks the phone tokens Firebase issues: ID tokens of
// Firebase Authentication after an SMS code, and Phone Number Verification
// tokens from the SIM.
package firebase

import (
	"context"
	"crypto"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"slices"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/shopnexus/server2/internal/platform/apperr"
)

const (
	// refetchGap is the least time between two fetches of one key set.
	refetchGap   = time.Minute
	fetchTimeout = 5 * time.Second
	maxJWKS      = 1 << 20
)

// ErrUnavailable is a token whose keys could not be fetched yet. The app
// tries again instead of asking for a new code.
var ErrUnavailable = apperr.New(apperr.KindUnavailable, "unavailable", "phone tokens cannot be checked right now; try again")

var errUnknownKey = errors.New("firebase: no key with this kid")

// keySet holds the public keys published at one JWKS URL. Lookups share one
// mutex, so requests that arrive during a fetch wait for it.
type keySet struct {
	url  string
	http *http.Client
	now  func() time.Time
	log  *slog.Logger

	mu        sync.Mutex
	keys      map[string]crypto.PublicKey // nil until a fetch succeeds
	freshTill time.Time                   // zero when the response gave no max-age
	tried     time.Time                   // the last fetch, successful or not
}

// key returns the key named kid. It fetches when no keys are held, when
// max-age has passed or when kid is unknown, at most once a minute. A failed
// fetch keeps the keys held.
func (s *keySet) key(ctx context.Context, kid string) (crypto.PublicKey, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	now := s.now()
	k, held := s.keys[kid]
	expired := !s.freshTill.IsZero() && !now.Before(s.freshTill)
	if (!held || expired) && (s.tried.IsZero() || now.Sub(s.tried) >= refetchGap) {
		s.tried = now
		keys, freshTill, err := s.fetch(ctx)
		if err != nil {
			s.log.WarnContext(ctx, "fetch phone token keys", "url", s.url, "err", err)
		} else {
			s.keys, s.freshTill = keys, freshTill
			k, held = s.keys[kid]
		}
	}
	switch {
	case s.keys == nil:
		return nil, ErrUnavailable
	case !held:
		return nil, errUnknownKey
	default:
		return k, nil
	}
}

// fetch reads the JWKS document and the time its keys stay fresh until.
func (s *keySet) fetch(ctx context.Context) (map[string]crypto.PublicKey, time.Time, error) {
	ctx, cancel := context.WithTimeout(ctx, fetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, s.url, http.NoBody)
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("build request: %w", err)
	}
	res, err := s.http.Do(req)
	if err != nil {
		return nil, time.Time{}, fmt.Errorf("get keys: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, time.Time{}, fmt.Errorf("get keys: status %d", res.StatusCode)
	}
	var doc struct {
		Keys []jwk `json:"keys"`
	}
	if err = json.NewDecoder(io.LimitReader(res.Body, maxJWKS)).Decode(&doc); err != nil {
		return nil, time.Time{}, fmt.Errorf("decode keys: %w", err)
	}
	keys := make(map[string]crypto.PublicKey, len(doc.Keys))
	for _, j := range doc.Keys {
		if pub := j.public(); pub != nil && j.Kid != "" {
			keys[j.Kid] = pub
		}
	}
	var freshTill time.Time
	for d := range strings.SplitSeq(res.Header.Get("Cache-Control"), ",") {
		if v, ok := strings.CutPrefix(strings.TrimSpace(d), "max-age="); ok {
			if secs, convErr := strconv.Atoi(v); convErr == nil && secs >= 0 {
				freshTill = s.now().Add(time.Duration(secs) * time.Second)
			}
		}
	}
	return keys, freshTill, nil
}

// jwk is one key of a JWKS document, as RFC 7517 writes it.
type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Use string `json:"use"`
	Crv string `json:"crv"`
	X   string `json:"x"`
	Y   string `json:"y"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// public is the signing key j describes: a P-256 point on the curve, or an
// RSA key of at least 2048 bits. Anything else is nil.
func (j jwk) public() crypto.PublicKey {
	if j.Use != "" && j.Use != "sig" {
		return nil
	}
	switch j.Kty {
	case "EC":
		x, errX := base64.RawURLEncoding.DecodeString(j.X)
		y, errY := base64.RawURLEncoding.DecodeString(j.Y)
		if j.Crv != "P-256" || errX != nil || errY != nil || len(x) != 32 || len(y) != 32 {
			return nil
		}
		pub, err := ecdsa.ParseUncompressedPublicKey(elliptic.P256(), slices.Concat([]byte{4}, x, y))
		if err != nil {
			return nil
		}
		return pub
	case "RSA":
		n, errN := base64.RawURLEncoding.DecodeString(j.N)
		e, errE := base64.RawURLEncoding.DecodeString(j.E)
		if errN != nil || errE != nil || len(e) == 0 || len(e) > 4 {
			return nil
		}
		pub := &rsa.PublicKey{N: new(big.Int).SetBytes(n), E: int(new(big.Int).SetBytes(e).Int64())}
		if pub.N.BitLen() < 2048 || pub.E < 3 {
			return nil
		}
		return pub
	default:
		return nil
	}
}
```

- [ ] **Step 4: Run**

Run: `go test -count=1 -race ./internal/provider/firebase/ ./internal/platform/httpx/ ./internal/platform/apperr/ 2>&1 | tail -5`
Expected: `ok` for each.

- [ ] **Step 5: Commit**

```bash
git add internal/provider/firebase internal/platform/apperr internal/platform/httpx
git commit -m "feat: key sets read from a JWKS URL

A key set caches for the response's max-age, fetches at most once a minute
for an unknown kid or after a failure, and keeps its keys when a fetch
fails. apperr gains KindUnavailable, answered with 503.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: The phone token verifier and its test issuer

**Files:**
- Create: `internal/provider/firebase/verifier.go`, `internal/provider/firebase/firebasetest/firebasetest.go`
- Test: `internal/provider/firebase/verifier_test.go` (package `firebase_test`)

**Interfaces:**
- Consumes: `keySet`, `ErrUnavailable` (Task 3), `config.FirebaseConfig` (Task 2).
- Produces:
  - `firebase.NewPhoneVerifier(cfg config.FirebaseConfig, now func() time.Time, log *slog.Logger) *PhoneVerifier`
  - `func (v *PhoneVerifier) Verify(ctx context.Context, token string) (contact.Address, error)`
  - `firebase.ErrInvalidToken` (401 `invalid_phone_token`)
  - `firebasetest.New(t testing.TB) *Issuer`, `firebasetest.NewForMain() (*Issuer, func(), error)`, `(*Issuer).Config(testNumbers bool) config.FirebaseConfig`, `(*Issuer).SMSToken(phone string, opts ...Option) string`, `(*Issuer).PNVToken(phone string, opts ...Option) string`, `(*Issuer).SetPNVDown(bool)`, field `Now func() time.Time`, options `Claim(name, value)`, `Drop(name)`, `Header(name, value)`, `SignedWith(method jwt.SigningMethod, key any)`; constants `ProjectID`, `ProjectNumber`.

- [ ] **Step 1: Write the test issuer**

`internal/provider/firebase/firebasetest/firebasetest.go`:

```go
// Package firebasetest signs phone tokens the way Firebase does, with keys
// it serves from httptest JWKS endpoints, for tests of the sign-in path.
package firebasetest

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"maps"
	"math/big"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/shopnexus/server2/internal/platform/config"
)

const (
	ProjectID     = "shopnexus-test"
	ProjectNumber = "123456789"
	rsaKid        = "rsa-1"
	ecKid         = "ec-1"
)

// Issuer holds an RSA key for Firebase Authentication tokens and an EC key
// for PNV tokens, and serves each from its own JWKS URL.
type Issuer struct {
	// Now is the time tokens are issued at; time.Now unless a test sets it.
	Now     func() time.Time
	rsa     *rsa.PrivateKey
	ec      *ecdsa.PrivateKey
	auth    *httptest.Server
	pnv     *httptest.Server
	pnvDown atomic.Bool
}

// New starts the key servers; t's cleanup stops them.
func New(t testing.TB) *Issuer {
	t.Helper()
	i, stop, err := NewForMain()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(stop)
	return i
}

// NewForMain is New for TestMain, which has no t; call stop when done.
func NewForMain() (i *Issuer, stop func(), err error) {
	rk, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		return nil, nil, fmt.Errorf("rsa key: %w", err)
	}
	ek, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, nil, fmt.Errorf("ec key: %w", err)
	}
	enc := base64.RawURLEncoding.EncodeToString
	i = &Issuer{Now: time.Now, rsa: rk, ec: ek}
	i.auth = httptest.NewServer(serve(func() bool { return false }, map[string]string{
		"kty": "RSA", "alg": "RS256", "use": "sig", "kid": rsaKid,
		"n": enc(rk.N.Bytes()), "e": enc(big.NewInt(int64(rk.E)).Bytes()),
	}))
	pub, err := ek.PublicKey.Bytes() // 0x04 || X || Y
	if err != nil {
		i.auth.Close()
		return nil, nil, fmt.Errorf("ec point: %w", err)
	}
	i.pnv = httptest.NewServer(serve(i.pnvDown.Load, map[string]string{
		"kty": "EC", "crv": "P-256", "alg": "ES256", "use": "sig", "kid": ecKid, "x": enc(pub[1:33]), "y": enc(pub[33:]),
	}))
	return i, func() { i.auth.Close(); i.pnv.Close() }, nil
}

func serve(down func() bool, key map[string]string) http.Handler {
	body, _ := json.Marshal(map[string]any{"keys": []any{key}}) //nolint:errchkjson // a map of strings marshals
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		if down() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "public, max-age=3600")
		_, _ = w.Write(body)
	})
}

// Config points a server at these keys.
func (i *Issuer) Config(testNumbers bool) config.FirebaseConfig {
	return config.FirebaseConfig{
		ProjectID: ProjectID, ProjectNumber: ProjectNumber, AuthJWKSURL: i.auth.URL, PNVJWKSURL: i.pnv.URL,
		TestNumbers: testNumbers,
	}
}

// SetPNVDown makes the PNV key URL answer 503.
func (i *Issuer) SetPNVDown(down bool) { i.pnvDown.Store(down) }

// Token is what SMSToken and PNVToken sign; each Option changes it first.
type Token struct {
	Method jwt.SigningMethod
	Key    any
	Header map[string]any
	Claims jwt.MapClaims
}

type Option func(*Token)

func Claim(name string, value any) Option { return func(t *Token) { t.Claims[name] = value } }
func Drop(name string) Option             { return func(t *Token) { delete(t.Claims, name) } }
func Header(name string, value any) Option {
	return func(t *Token) { t.Header[name] = value }
}

// SignedWith signs with another method and key, keeping the kid.
func SignedWith(method jwt.SigningMethod, key any) Option {
	return func(t *Token) { t.Method, t.Key = method, key }
}

// SMSToken is a Firebase Authentication ID token for phone, verified now.
func (i *Issuer) SMSToken(phone string, opts ...Option) string {
	now := i.Now()
	return sign(Token{
		Method: jwt.SigningMethodRS256, Key: i.rsa, Header: map[string]any{"kid": rsaKid},
		Claims: jwt.MapClaims{
			"iss": "https://securetoken.google.com/" + ProjectID, "aud": ProjectID, "sub": "uid-" + phone,
			"iat": now.Unix(), "exp": now.Add(time.Hour).Unix(), "auth_time": now.Unix(), "phone_number": phone,
			"firebase": map[string]any{"sign_in_provider": "phone", "identities": map[string]any{"phone": []string{phone}}},
		},
	}, opts)
}

// PNVToken is a Phone Number Verification token for phone, issued now.
func (i *Issuer) PNVToken(phone string, opts ...Option) string {
	now := i.Now()
	return sign(Token{
		Method: jwt.SigningMethodES256, Key: i.ec, Header: map[string]any{"kid": ecKid, "typ": "JWT"},
		Claims: jwt.MapClaims{
			"iss": "https://fpnv.googleapis.com/projects/" + ProjectNumber,
			"aud": []string{
				"https://fpnv.googleapis.com/projects/" + ProjectNumber, "https://fpnv.googleapis.com/projects/" + ProjectID,
			},
			"sub": phone, "iat": now.Unix(), "exp": now.Add(time.Hour).Unix(),
		},
	}, opts)
}

func sign(t Token, opts []Option) string {
	for _, o := range opts {
		o(&t)
	}
	tok := jwt.NewWithClaims(t.Method, t.Claims)
	maps.Copy(tok.Header, t.Header)
	s, err := tok.SignedString(t.Key)
	if err != nil {
		panic(fmt.Sprintf("firebasetest: sign: %v", err)) // an option built a token no key signs: a test bug
	}
	return s
}
```

(`SignedWith(jwt.SigningMethodNone, jwt.UnsafeAllowNoneSignatureType)` signs an `alg: none` token.)

- [ ] **Step 2: Write the failing verifier tests**

`internal/provider/firebase/verifier_test.go`:

```go
package firebase_test

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"errors"
	"log/slog"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/shopnexus/server2/internal/platform/contact"
	"github.com/shopnexus/server2/internal/provider/firebase"
	"github.com/shopnexus/server2/internal/provider/firebase/firebasetest"
)

var at = time.Date(2026, 10, 28, 9, 0, 0, 0, time.UTC)

const phone = "+84901234567"

func verifier(i *firebasetest.Issuer, testNumbers bool) *firebase.PhoneVerifier {
	return firebase.NewPhoneVerifier(i.Config(testNumbers), func() time.Time { return at }, slog.New(slog.DiscardHandler))
}

func newIssuer(t *testing.T) *firebasetest.Issuer {
	t.Helper()
	i := firebasetest.New(t)
	i.Now = func() time.Time { return at }
	return i
}

func TestVerifyAcceptsBothIssuers(t *testing.T) {
	t.Parallel()
	i := newIssuer(t)
	v := verifier(i, false)
	for name, token := range map[string]string{
		"sms":             i.SMSToken(phone),
		"sim":             i.PNVToken(phone),
		"iat 20 s ahead":  i.SMSToken(phone, firebasetest.Claim("iat", at.Add(20*time.Second).Unix())),
		"verified 4m ago": i.SMSToken(phone, firebasetest.Claim("auth_time", at.Add(-4*time.Minute).Unix())),
	} {
		if got, err := v.Verify(context.Background(), token); err != nil || got.Value() != phone {
			t.Errorf("%s: %v %v", name, got, err)
		}
	}
}

func TestVerifyRefuses(t *testing.T) {
	t.Parallel()
	i := newIssuer(t)
	v := verifier(i, false)
	stranger, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	for name, token := range map[string]string{
		"not a jwt":         "abc.def",
		"unknown issuer":    i.SMSToken(phone, firebasetest.Claim("iss", "https://securetoken.google.com/other")),
		"wrong audience":    i.SMSToken(phone, firebasetest.Claim("aud", "other")),
		"expired":           i.SMSToken(phone, firebasetest.Claim("exp", at.Add(-time.Minute).Unix())),
		"no exp":            i.SMSToken(phone, firebasetest.Drop("exp")),
		"iat 60 s ahead":    i.SMSToken(phone, firebasetest.Claim("iat", at.Add(time.Minute).Unix())),
		"verified 6m ago":   i.SMSToken(phone, firebasetest.Claim("auth_time", at.Add(-6*time.Minute).Unix())),
		"no auth_time":      i.SMSToken(phone, firebasetest.Drop("auth_time")),
		"another provider":  i.SMSToken(phone, firebasetest.Claim("firebase", map[string]any{"sign_in_provider": "password"})),
		"no phone_number":   i.SMSToken(phone, firebasetest.Drop("phone_number")),
		"signed by another": i.SMSToken(phone, firebasetest.SignedWith(jwt.SigningMethodRS256, stranger)),
		"unknown kid":       i.SMSToken(phone, firebasetest.Header("kid", "rsa-9")),
		"sim typ":           i.PNVToken(phone, firebasetest.Header("typ", "at+jwt")),
		"sim audience":      i.PNVToken(phone, firebasetest.Claim("aud", []string{"https://fpnv.googleapis.com/projects/other"})),
		"sim issued 6m ago": i.PNVToken(phone, firebasetest.Claim("iat", at.Add(-6*time.Minute).Unix())),
		"sim no iat":        i.PNVToken(phone, firebasetest.Drop("iat")),
		"sim test number":   i.PNVToken("+840000000000", firebasetest.Claim("test_number", true)),
	} {
		if _, err := v.Verify(context.Background(), token); !errors.Is(err, firebase.ErrInvalidToken) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

// A token must use its issuer's algorithm, so none of these verify: alg
// none, HS256 keyed with the public key, and each issuer's token signed with
// the other's algorithm.
func TestVerifyRefusesAlgorithmSwaps(t *testing.T) {
	t.Parallel()
	i := newIssuer(t)
	v := verifier(i, false)
	pub, err := x509.MarshalPKIXPublicKey(&mustRSA(t).PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	for name, token := range map[string]string{
		"none":         i.SMSToken(phone, firebasetest.SignedWith(jwt.SigningMethodNone, jwt.UnsafeAllowNoneSignatureType)),
		"hs256":        i.SMSToken(phone, firebasetest.SignedWith(jwt.SigningMethodHS256, pub)),
		"sms as es256": i.SMSToken(phone, firebasetest.SignedWith(jwt.SigningMethodES256, mustEC(t))),
		"sim as rs256": i.PNVToken(phone, firebasetest.SignedWith(jwt.SigningMethodRS256, mustRSA(t))),
	} {
		if _, err := v.Verify(context.Background(), token); !errors.Is(err, firebase.ErrInvalidToken) {
			t.Errorf("%s: %v", name, err)
		}
	}
}

func TestVerifyTestNumbersWhenAllowed(t *testing.T) {
	t.Parallel()
	i := newIssuer(t)
	got, err := verifier(i, true).Verify(context.Background(), i.PNVToken("+840000000000", firebasetest.Claim("test_number", true)))
	if err != nil || got.Value() != "+840000000000" || got.Kind() != contact.Phone {
		t.Fatalf("%v %v", got, err)
	}
}

func TestVerifyForeignNumber(t *testing.T) {
	t.Parallel()
	i := newIssuer(t)
	if _, err := verifier(i, false).Verify(context.Background(), i.SMSToken("+14155550100")); !errors.Is(err, contact.ErrInvalidPhone) {
		t.Fatalf("%v", err)
	}
}

func TestVerifyWithoutKeysIsUnavailable(t *testing.T) {
	t.Parallel()
	i := newIssuer(t)
	i.SetPNVDown(true)
	if _, err := verifier(i, false).Verify(context.Background(), i.PNVToken(phone)); !errors.Is(err, firebase.ErrUnavailable) {
		t.Fatalf("%v", err)
	}
}
```

Add the two small key helpers at the end of the file:

```go
func mustRSA(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

func mustEC(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}
```

(with `crypto/ecdsa` and `crypto/elliptic` imported).

- [ ] **Step 3: Run and watch them fail**

Run: `go test -count=1 ./internal/provider/firebase/... 2>&1 | tail -5`
Expected: build failure, `undefined: firebase.NewPhoneVerifier`.

- [ ] **Step 4: Implement the verifier**

`internal/provider/firebase/verifier.go`:

```go
package firebase

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/config"
	"github.com/shopnexus/server2/internal/platform/contact"
)

const (
	// freshFor is how long after the verification a token signs in.
	freshFor = 5 * time.Minute
	skew     = 30 * time.Second
)

// ErrInvalidToken is a token that failed a check; the log says which.
var ErrInvalidToken = apperr.New(apperr.KindUnauthenticated, "invalid_phone_token",
	"the phone token is not valid; verify the number again")

// PhoneVerifier checks phone tokens of one Firebase project.
type PhoneVerifier struct {
	cfg  config.FirebaseConfig
	auth *keySet
	pnv  *keySet
	now  func() time.Time
	log  *slog.Logger
}

func NewPhoneVerifier(cfg config.FirebaseConfig, now func() time.Time, log *slog.Logger) *PhoneVerifier {
	client := &http.Client{Timeout: fetchTimeout}
	return &PhoneVerifier{
		cfg: cfg, now: now, log: log,
		auth: &keySet{url: cfg.AuthJWKSURL, http: client, now: now, log: log},
		pnv:  &keySet{url: cfg.PNVJWKSURL, http: client, now: now, log: log},
	}
}

// smsClaims is an ID token of Firebase Authentication.
type smsClaims struct {
	jwt.RegisteredClaims

	AuthTime    int64  `json:"auth_time"`
	PhoneNumber string `json:"phone_number"`
	Firebase    struct {
		SignInProvider string `json:"sign_in_provider"`
	} `json:"firebase"`
}

// simClaims is a Phone Number Verification token.
type simClaims struct {
	jwt.RegisteredClaims

	TestNumber bool `json:"test_number"`
}

// Verify returns the phone number token proves. The token's iss picks the
// key set; the token must then carry that issuer's algorithm, audience and
// a verification less than 5 minutes old. A failed check is ErrInvalidToken,
// keys that cannot be fetched are ErrUnavailable, and a number outside
// Vietnam is contact.ErrInvalidPhone.
func (v *PhoneVerifier) Verify(ctx context.Context, token string) (contact.Address, error) {
	refuse := func(why string, err error) (contact.Address, error) {
		if errors.Is(err, ErrUnavailable) {
			return contact.Address{}, ErrUnavailable
		}
		v.log.InfoContext(ctx, "phone token refused", "why", why, "err", err)
		return contact.Address{}, ErrInvalidToken
	}
	var unverified jwt.RegisteredClaims
	if _, _, err := jwt.NewParser().ParseUnverified(token, &unverified); err != nil {
		return refuse("malformed", err)
	}
	now := v.now()
	keyIn := func(set *keySet) jwt.Keyfunc {
		return func(t *jwt.Token) (any, error) {
			kid, _ := t.Header["kid"].(string) //nolint:revive // a token without a kid finds no key
			return set.key(ctx, kid)
		}
	}
	parser := func(alg, aud string) *jwt.Parser {
		return jwt.NewParser(jwt.WithValidMethods([]string{alg}), jwt.WithIssuer(unverified.Issuer),
			jwt.WithAudience(aud), jwt.WithExpirationRequired(), jwt.WithIssuedAt(), jwt.WithLeeway(skew),
			jwt.WithTimeFunc(v.now))
	}
	switch unverified.Issuer {
	case "https://securetoken.google.com/" + v.cfg.ProjectID:
		var c smsClaims
		if _, err := parser("RS256", v.cfg.ProjectID).ParseWithClaims(token, &c, keyIn(v.auth)); err != nil {
			return refuse("sms", err)
		}
		verified := time.Unix(c.AuthTime, 0)
		switch {
		case c.AuthTime == 0 || now.Sub(verified) > freshFor || verified.After(now.Add(skew)):
			return refuse("sms: not verified in the last 5 minutes", nil)
		case c.Firebase.SignInProvider != "phone" || c.PhoneNumber == "":
			return refuse("sms: not a phone sign-in", nil)
		}
		a, err := contact.ParsePhone(c.PhoneNumber)
		if err != nil {
			return contact.Address{}, fmt.Errorf("the verified number: %w", err)
		}
		return a, nil
	case "https://fpnv.googleapis.com/projects/" + v.cfg.ProjectNumber:
		var c simClaims
		t, err := parser("ES256", "https://fpnv.googleapis.com/projects/"+v.cfg.ProjectID).ParseWithClaims(token, &c, keyIn(v.pnv))
		if err != nil {
			return refuse("sim", err)
		}
		switch {
		case t.Header["typ"] != "JWT":
			return refuse("sim: typ is not JWT", nil)
		case c.IssuedAt == nil || now.Sub(c.IssuedAt.Time) > freshFor:
			return refuse("sim: not issued in the last 5 minutes", nil)
		case c.Subject == "":
			return refuse("sim: no number", nil)
		case c.TestNumber && !v.cfg.TestNumbers:
			return refuse("sim: a test number", nil)
		case c.TestNumber:
			// A test number is the country code and zeros, which no mobile
			// prefix matches; it is kept as it comes.
			return contact.Restore(contact.Phone, c.Subject), nil
		}
		a, err := contact.ParsePhone(c.Subject)
		if err != nil {
			return contact.Address{}, fmt.Errorf("the verified number: %w", err)
		}
		return a, nil
	default:
		return refuse("unknown issuer", fmt.Errorf("iss %q", unverified.Issuer))
	}
}
```

- [ ] **Step 5: Run**

Run: `go test -count=1 -race ./internal/provider/firebase/... 2>&1 | tail -5 && golangci-lint run ./internal/provider/firebase/... 2>&1 | tail -3`
Expected: `ok` for `firebase` (firebasetest has no tests), `0 issues`. Fix each lint finding in the code; add no `nolint` for it.

- [ ] **Step 6: Commit**

```bash
git add internal/provider/firebase
git commit -m "feat: verify Firebase phone tokens

PhoneVerifier picks the key set by iss and checks the algorithm, audience,
expiry and a verification at most 5 minutes old: auth_time for Firebase
Authentication, iat for PNV. firebasetest serves keys and signs tokens for
tests.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: POST /v1/auth/sign-in replaces OTP

**Files:**
- Modify: `api/openapi.yaml` (`/v1/auth/otp` and `/v1/auth/otp/verify` out, `/v1/auth/sign-in` in), `api/paths/auth.yaml` (`otp`, `otpVerify` out, `signIn` in), `api/schemas/auth.yaml` (`OTPSendRequest`, `OTPChallenge`, `OTPVerifyRequest` out, `SignInRequest` in)
- Modify: `internal/auth/auth.go`, `internal/auth/handler/handler.go`, `internal/auth/handler/sign_in.go`, `internal/auth/service/service.go`, `internal/auth/service/views.go`, `internal/auth/service/sign_in.go`, `internal/auth/service/sign_in_durable.go`, `internal/auth/service/metrics.go` (`otpSent` out), `internal/auth/domain/errors.go` (the five OTP errors out)
- Delete: `internal/auth/domain/challenge.go`, `challenge_test.go`, `codes.go`, `codes_test.go`, `quota.go`, `quota_test.go`, `exercise_test.go`; `internal/auth/repository/challenge.go`, `challenge_pg.go`, `challenge_pg_test.go`, `quota.go`, `quota_pg.go`, `quota_pg_test.go`; `internal/auth/service/otp_send.go`, `otp_send_test.go`, `otp_send_durable.go`, `otp_send_durable_test.go`; `internal/auth/handler/otp_send.go`; `internal/provider/sms/`, `internal/provider/email/`; `e2e/auth_otp_test.go`, `e2e/inbox_test.go`
- Modify: `internal/platform/contact/contact.go` (`Parse` out), `internal/platform/config/config.go` and `keys.go` and `config_test.go` (`OTPKey` and `OTP_KEY` out), `cmd/keygen/main.go` (doc comment), `Makefile:13`, `.env.example` (the comment naming `OTP_KEY`)
- Modify: `internal/app/app.go` (`WithSMSSender`, `WithEmailSender`, their options and guard out; the verifier in; the `PNV_TEST_NUMBERS` guard), `internal/app/app_test.go`
- Modify: `e2e/main_test.go`, `e2e/auth_helpers_test.go`; Create: `e2e/auth_sign_in_test.go`
- Test: `internal/auth/service/sign_in_durable_test.go`, `internal/auth/service/helpers_test.go`

**Interfaces:**
- Consumes: `firebase.NewPhoneVerifier`, `firebase.ErrInvalidToken`, `firebase.ErrUnavailable`, `firebasetest.*` (Task 4); `config.FirebaseConfig` (Task 2).
- Produces:
  - `service.PhoneVerifier interface { Verify(ctx context.Context, token string) (contact.Address, error) }`
  - `service.SignInInput{IdempotencyKey, PhoneToken, DeviceName string}`
  - Restate: `service.PhoneSignIn{Phone contact.Address}` → `service.SignInResult{AccountID uuid.UUID; IsNew bool; SessionID uuid.UUID; Refused *apperr.Error}`
  - `auth.Settings{Keys config.AuthConfig; Phones service.PhoneVerifier}`
  - e2e: `tokens *firebasetest.Issuer`, `signInCall(t, token, headers...) Response`, `signInStatus(token) int`, `signInWith(t, phone) signIn`, `newAccount(t) (signIn, string)`.

- [ ] **Step 1: Write the failing e2e tests**

Replace `e2e/auth_helpers_test.go` with:

```go
package e2e

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync/atomic"
	"testing"
	"uuid"

	"github.com/jackc/pgx/v5"
)

// seq numbers the phones and addresses tests make up, so no two tests share
// one. The database is new each run.
var seq atomic.Int64

// newPhone returns a fresh mobile number.
func newPhone() string { return fmt.Sprintf("+8499%07d", seq.Add(1)) }

type signIn struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	Account      struct {
		ID    string `json:"id"`
		IsNew bool   `json:"is_new"`
	} `json:"account"`
}

// suspend marks an account suspended, as an admin would.
func suspend(t *testing.T, accountID string) {
	t.Helper()
	if _, err := db.Exec(context.Background(),
		`UPDATE accounts SET status = 'suspended', suspend_reason = 'e2e' WHERE id = @id`,
		pgx.StrictNamedArgs{"id": accountID}); err != nil {
		t.Fatal(err)
	}
}

// signInCall signs in with a phone token and a fresh key unless headers
// carry one.
func signInCall(t *testing.T, token string, headers ...[2]string) Response {
	t.Helper()
	return call(t, server, "POST", "/v1/auth/sign-in",
		map[string]string{"phone_token": token, "device_name": "e2e"}, append([][2]string{newKey()}, headers...)...)
}

// signInStatus signs in and returns the status without touching t, so
// goroutines can call it. It records the status for the coverage check as
// call does and skips response validation, so its caller checks statuses.
func signInStatus(token string) int {
	body, _ := json.Marshal(map[string]string{"phone_token": token})
	req, _ := http.NewRequestWithContext(context.Background(), http.MethodPost, server+"/v1/auth/sign-in", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", uuid.NewV7().String())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0
	}
	res.Body.Close()
	record("signIn", res.StatusCode)
	return res.StatusCode
}

func signInWith(t *testing.T, phone string) signIn {
	t.Helper()
	res := signInCall(t, tokens.SMSToken(phone))
	if res.Status != http.StatusOK {
		t.Fatalf("sign in: %d %s", res.Status, res.Body)
	}
	return decode[signIn](t, res)
}

func newAccount(t *testing.T) (account signIn, phone string) {
	t.Helper()
	phone = newPhone()
	return signInWith(t, phone), phone
}
```

Create `e2e/auth_sign_in_test.go`:

```go
package e2e

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"slices"
	"sync"
	"testing"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/jackc/pgx/v5"

	"github.com/shopnexus/server2/internal/provider/firebase/firebasetest"
)

func TestSignUpThenSignIn(t *testing.T) {
	t.Parallel()
	first, phone := newAccount(t)
	if !first.Account.IsNew || first.TokenType != "Bearer" || first.AccessToken == "" || first.RefreshToken == "" {
		t.Fatalf("%+v", first)
	}
	if second := signInWith(t, phone); second.Account.ID != first.Account.ID || second.Account.IsNew {
		t.Fatalf("second %+v", second.Account)
	}
}

func TestSignInReplayedKeyGetsTheSameSession(t *testing.T) {
	t.Parallel()
	token, key := tokens.SMSToken(newPhone()), newKey()
	a, b := signInCall(t, token, key), signInCall(t, token, key)
	sa, sb := decode[signIn](t, a), decode[signIn](t, b)
	if a.Status != 200 || b.Status != 200 || sa.Account != sb.Account || sb.RefreshToken == sa.RefreshToken {
		t.Fatalf("a %d %s, b %d %s", a.Status, a.Body, b.Status, b.Body)
	}
	if res := refresh(t, sb.RefreshToken); res.Status != 200 {
		t.Fatalf("the replay's refresh token: %d %s", res.Status, res.Body)
	}
}

// A key someone else used, sent with a token for another number, runs on
// its own and never returns the first number's session.
func TestSignInKeyIsBoundToTheNumber(t *testing.T) {
	t.Parallel()
	key := newKey()
	victim := decode[signIn](t, signInCall(t, tokens.SMSToken(newPhone()), key))
	res := signInCall(t, tokens.SMSToken(newPhone()), key)
	if res.Status != 200 || decode[signIn](t, res).Account.ID == victim.Account.ID {
		t.Fatalf("%d %s", res.Status, res.Body)
	}
}

// Replaying the sign-in of a signed-out session must not bring it back.
func TestSignInReplayAfterLogoutIsRefused(t *testing.T) {
	t.Parallel()
	token, key := tokens.SMSToken(newPhone()), newKey()
	first := decode[signIn](t, signInCall(t, token, key))
	if res := call(t, server, "POST", "/v1/auth/logout", nil, bearer(first.AccessToken)); res.Status != 204 {
		t.Fatalf("logout %d", res.Status)
	}
	if res := signInCall(t, token, key); res.Status != 401 || errorOf(t, res).Code != "session_revoked" {
		t.Fatalf("%d %s", res.Status, res.Body)
	}
}

func TestSignInSuspendedAccount(t *testing.T) {
	t.Parallel()
	a, phone := newAccount(t)
	suspend(t, a.Account.ID)
	if res := signInCall(t, tokens.SMSToken(phone)); res.Status != 403 || errorOf(t, res).Code != "account_suspended" {
		t.Fatalf("%d %s", res.Status, res.Body)
	}
}

func TestSignInRefusals(t *testing.T) {
	t.Parallel()
	stranger, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	phone := newPhone()
	for name, c := range map[string]struct {
		body   map[string]string
		status int
		code   string
	}{
		"forged":         {map[string]string{"phone_token": tokens.SMSToken(phone, firebasetest.SignedWith(jwt.SigningMethodRS256, stranger))}, 401, "invalid_phone_token"},
		"stale":          {map[string]string{"phone_token": tokens.SMSToken(phone, firebasetest.Claim("auth_time", time.Now().Add(-6*time.Minute).Unix()))}, 401, "invalid_phone_token"},
		"foreign number": {map[string]string{"phone_token": tokens.SMSToken("+14155550100")}, 422, "invalid_phone"},
		"pnv keys down":  {map[string]string{"phone_token": tokens.PNVToken(phone)}, 503, "unavailable"},
		"empty token":    {map[string]string{"phone_token": ""}, 400, "invalid_request"},
		"unknown field":  {map[string]string{"phone_token": "x", "code": "123456"}, 400, "invalid_request"},
	} {
		if res := call(t, server, "POST", "/v1/auth/sign-in", c.body, newKey()); res.Status != c.status || errorOf(t, res).Code != c.code {
			t.Errorf("%s: %d %s", name, res.Status, res.Body)
		}
	}
	if res := call(t, server, "POST", "/v1/auth/sign-in", map[string]string{"phone_token": tokens.SMSToken(phone)}); res.Status != 400 {
		t.Errorf("no Idempotency-Key: %d %s", res.Status, res.Body)
	}
}

// Parallel first sign-ins of one number race to create its account: one
// wins, the others get try_again, and the number ends with one account.
func TestSignInRace(t *testing.T) {
	t.Parallel()
	for range 10 {
		phone := newPhone()
		token := tokens.SMSToken(phone)
		statuses := make([]int, 16)
		var wg sync.WaitGroup
		for i := range statuses {
			wg.Go(func() { statuses[i] = signInStatus(token) })
		}
		wg.Wait()
		for _, s := range statuses {
			if s != 200 && s != 409 {
				t.Fatalf("statuses %v", statuses)
			}
		}
		var n int
		if err := db.QueryRow(context.Background(), `SELECT count(*) FROM identities WHERE identifier = @phone`,
			pgx.StrictNamedArgs{"phone": phone}).Scan(&n); err != nil || n != 1 {
			t.Fatalf("identities of %s: %d %v", phone, n, err)
		}
		if slices.Contains(statuses, 409) {
			return
		}
	}
	t.Fatal("ten rounds of 16 parallel sign-ins never raced")
}
```

In `e2e/main_test.go`:
- replace `box = newInbox()` with `tokens *firebasetest.Issuer // signs the phone tokens; the server's key URLs point at it`;
- before `cfg := config.Config{`, add:

```go
	issuer, stopIssuer, err := firebasetest.NewForMain()
	if err != nil {
		fmt.Fprintln(os.Stderr, "e2e:", err)
		return 1
	}
	defer stopIssuer()
	tokens = issuer
	// PNV's keys stay down for the whole run, so a PNV token observes the
	// 503 the spec declares; the firebase tests check PNV tokens.
	tokens.SetPNVDown(true)
```

- add `Firebase: tokens.Config(false),` to `cfg`, and change the `TrustedProxies` comment to `// Tests may set X-Forwarded-For.`;
- `app.New(..., app.WithPushSender(phones), app.WithPasswordHasher(staffdomain.Fast))`.

Delete `e2e/auth_otp_test.go` and `e2e/inbox_test.go`.

- [ ] **Step 2: Run e2e and watch it fail**

Run: `go vet ./e2e/ 2>&1 | head; go test -count=1 ./e2e/ -run 'TestSignIn|TestSignUp' 2>&1 | grep -E '^(---|ok|FAIL)|sign-in' | head -20`
Expected: the e2e package builds only after `app.WithSMSSender` is gone from `main_test.go`; the run fails because `POST /v1/auth/sign-in` is not in the spec (the request validator answers 404 or the coverage list names it). Record the actual failure in the ledger.

- [ ] **Step 3: Write the spec**

`api/openapi.yaml`: replace the `/v1/auth/otp` and `/v1/auth/otp/verify` entries with

```yaml
  /v1/auth/sign-in:
    $ref: "paths/auth.yaml#/signIn"
```

`api/paths/auth.yaml`: replace `otp:` and `otpVerify:` with

```yaml
signIn:
  post:
    operationId: signIn
    summary: Sign in, or sign up on first use, with a phone number Firebase verified.
    description: |
      phone_token is what Firebase returned for the number: the ID token of
      Firebase Authentication after an SMS code, or the Phone Number
      Verification token of the SIM. The verification must be at most 5
      minutes old. A repeated Idempotency-Key with a token for the same
      number returns the first sign-in's session with a new refresh token.
    tags: [auth]
    parameters:
      - $ref: "../parameters/common.yaml#/IdempotencyKey"
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/auth.yaml#/SignInRequest"
    responses:
      "200":
        description: Signed in.
        content:
          application/json:
            schema:
              $ref: "../schemas/auth.yaml#/SignIn"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "401":
        description: The token failed a check (invalid_phone_token), or a repeated Idempotency-Key's session was signed out since (session_revoked, session_expired).
        content:
          application/json:
            schema:
              $ref: "../schemas/error.yaml#/Error"
      "403":
        $ref: "../responses/common.yaml#/Forbidden"
      "409":
        $ref: "../responses/common.yaml#/Conflict"
      "422":
        description: The verified number is not a Vietnamese mobile number (invalid_phone).
        content:
          application/json:
            schema:
              $ref: "../schemas/error.yaml#/Error"
      "503":
        description: The keys that sign phone tokens could not be fetched yet (unavailable); try again.
        content:
          application/json:
            schema:
              $ref: "../schemas/error.yaml#/Error"
```

`api/schemas/auth.yaml`: delete `OTPSendRequest`, `OTPChallenge`, `OTPVerifyRequest`; add

```yaml
SignInRequest:
  type: object
  additionalProperties: false
  required: [phone_token]
  properties:
    phone_token:
      type: string
      minLength: 1
      maxLength: 8192
      description: The token Firebase returned for the verified number.
    device_name:
      type: string
      maxLength: 100
      description: Shown in the list of signed-in devices.
```

- [ ] **Step 4: Rewrite module auth around the verifier**

`internal/auth/service/sign_in_durable.go` becomes (the challenge half goes; the identity half stays as it is):

```go
package service

import (
	"errors"
	"fmt"
	"time"
	"uuid"

	restate "github.com/restatedev/sdk-go"

	accountdomain "github.com/shopnexus/server2/internal/account/domain"
	accountsvc "github.com/shopnexus/server2/internal/account/service"
	"github.com/shopnexus/server2/internal/auth/domain"
	"github.com/shopnexus/server2/internal/auth/repository"
	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/contact"
	"github.com/shopnexus/server2/internal/platform/restatex"
)

// PhoneSignIn is a number Firebase proved. The token that proved it stays
// out of Restate, whose journal the admin API can read.
type PhoneSignIn struct {
	Phone contact.Address `json:"phone"`
}

// SignInResult names the account and the session Auth.SignIn issues tokens
// for. Tokens never enter Restate. A refusal travels as data.
type SignInResult struct {
	AccountID uuid.UUID     `json:"account_id"`
	IsNew     bool          `json:"is_new"`
	SessionID uuid.UUID     `json:"session_id"`
	Refused   *apperr.Error `json:"refused,omitempty"`
}

func (r SignInResult) Refusal() *apperr.Error { return r.Refused }

// SignIn finds or creates the account of a proven number. Creating one is a
// saga: Account, then Credentials, and the account is deleted when another
// sign-up took the number in between. Any other failure is retried.
type SignIn struct {
	Prefix      string
	Credentials repository.Credentials
	Accounts    accountsvc.Service
	Now         func() time.Time
}
```

followed by `signInService`, `ServiceName`, `foundIdentity` as they are, and `Run(ctx restate.Context, in PhoneSignIn) (SignInResult, error)` whose body is today's body from `f, err := restate.Run(ctx, func(rc restate.RunContext) (foundIdentity, error) {` to the end, with `dest` replaced by `in.Phone`, `domain.KindOf(dest)` by `domain.KindPhone`, `VerifyResult` by `SignInResult` and the `ChallengeID: in.ChallengeID, ` fields removed; it starts with

```go
func (s SignIn) Run(ctx restate.Context, in PhoneSignIn) (SignInResult, error) {
	at, err := restatex.Now(ctx, s.Now)
	if err != nil {
		return SignInResult{}, err
	}
```

`internal/auth/service/sign_in.go`:

```go
package service

import (
	"context"
	"fmt"
)

// SignIn checks the phone token, has the SignIn service find or create the
// account, then starts the session it named.
func (a *Auth) SignIn(ctx context.Context, in SignInInput) (SignedIn, error) {
	phone, err := a.phones.Verify(ctx, in.PhoneToken)
	if err != nil {
		return SignedIn{}, fmt.Errorf("verify phone token: %w", err)
	}
	// Restate answers a repeated key with the first run's result. The number
	// in the key sends another number's token to a run of its own.
	res, err := a.signIn.Call(ctx, phone.Value()+"/"+in.IdempotencyKey, PhoneSignIn{Phone: phone})
	if err != nil {
		return SignedIn{}, err
	}
	tokens, err := a.IssueSession(ctx, res.SessionID, res.AccountID, in.DeviceName)
	if err != nil {
		return SignedIn{}, err
	}
	return SignedIn{Tokens: tokens, Account: SignedInAccount{ID: res.AccountID, IsNew: res.IsNew}}, nil
}
```

`internal/auth/service/views.go`: delete `SendOTPInput` and `OTPSent`; `SignInInput` becomes

```go
// SignInInput is a phone token from Firebase. A repeated IdempotencyKey with
// a token for the same number gets the first request's account.
type SignInInput struct {
	IdempotencyKey string
	PhoneToken     string
	DeviceName     string
}
```

`internal/auth/service/service.go`:
- package comment: `// Package service holds module auth's use cases: signing in with a phone number Firebase verified, sessions and their tokens, and the identities other modules read. Signing in runs on Restate, in sign_in_durable.go; Auth reaches it through restatex.Caller.`
- delete `SendOTP` from `Service`; the `SignIn` comment becomes `// SignIn checks a phone token, finds or creates the account and starts a session.`
- add

```go
// PhoneVerifier checks a token from Firebase and returns the phone number it
// proves: provider/firebase in the app, a fake in tests.
type PhoneVerifier interface {
	Verify(ctx context.Context, token string) (contact.Address, error)
}
```

- `Deps` and `Auth` lose `Challenges`, `Quotas`, `Codes`, `SMS`, `Email` (and `otp`); both gain `Phones PhoneVerifier` / `phones PhoneVerifier`; `signIn` becomes `restatex.Caller[PhoneSignIn, SignInResult]`; `Durable` returns only `restate.Reflect(SignIn{Prefix: a.prefix, Credentials: a.credentials, Accounts: a.accounts, Now: a.now})`.

`internal/auth/service/metrics.go`: delete `otpSent`.
`internal/auth/domain/errors.go`: delete `ErrInvalidCode`, `ErrCodeExpired`, `ErrCodeLocked`, `ErrOTPTooSoon`, `ErrOTPLimit`.

`internal/auth/handler/sign_in.go`:

```go
type signInRequest struct {
	IdempotencyKey string `header:"Idempotency-Key" json:"-"`
	PhoneToken     string `json:"phone_token"`
	DeviceName     string `json:"device_name"`
}

// SignIn serves POST /v1/auth/sign-in. Every request counts in login_total,
// a malformed one as a failure.
func (h *Handler) SignIn(w http.ResponseWriter, r *http.Request) {
	result := "failure"
	defer func() {
		logins.Add(r.Context(), 1, metric.WithAttributes(attribute.String("method", "phone"), attribute.String("result", result)))
	}()
	var in signInRequest
	if err := httpx.Bind(r, &in); err != nil {
		httpx.WriteError(w, r, h.log, err)
		return
	}
	res, err := h.svc.SignIn(r.Context(), service.SignInInput{
		IdempotencyKey: in.IdempotencyKey, PhoneToken: in.PhoneToken, DeviceName: in.DeviceName,
	})
	if err != nil {
		httpx.WriteError(w, r, h.log, err)
		return
	}
	result = "success"
	httpx.Respond(w, http.StatusOK, res)
}
```

(drop the `uuid` import). `handler.go`: the two OTP routes become `r.Handle("POST /v1/auth/sign-in", http.HandlerFunc(h.SignIn))`.

`internal/auth/auth.go`: package comment `// Package auth proves who a person is: sign-in with a phone number Firebase verified, sessions and tokens.`; `Settings` becomes

```go
// Settings is what auth's Mount takes beyond module.Deps.
type Settings struct {
	Keys   config.AuthConfig
	Phones service.PhoneVerifier
}
```

and `Mount` builds `service.Deps{Credentials: ..., Sessions: ..., Signer: domain.NewSigner(s.Keys), Accounts: accounts, Phones: s.Phones, Ingress: d.Ingress, Prefix: d.ServicePrefix, Now: d.Now, Log: d.Log}`.

Delete the files listed under Delete above, and `contact.Parse` (its only caller was the OTP handler).

`OTP_KEY`: delete `AuthConfig.OTPKey`, its `decodeKey("OTP_KEY", ...)` line, `otpKey` in `config.NewAuthKeys`, the `OTP_KEY` line of `AuthConfig.Env()` (in `keys.go`), and the `OTP_KEY` entries and table rows in `config_test.go`. `cmd/keygen/main.go` doc: `// Command keygen prints a fresh JWT key as .env lines.` `Makefile:13` checks `^JWT_KEY_ID=` instead of `^OTP_KEY=`. `.env.example`'s last comment names `JWT_KEY_ID, JWT_PRIVATE_KEY, STAFF_KEY and RESTATE_IDENTITY_KEY`. Remove the stale `OTP_KEY=` line from the local `.env`: `sed -i '/^OTP_KEY=/d' .env`.

`internal/app/app.go`:
- delete `WithSMSSender`, `WithEmailSender`, `options.sms`, `options.email`, their defaults in `o := options{...}`, and the `smsLogs`/`emailLogs` guard;
- after the push guard add

```go
	if cfg.Env == config.EnvProd && cfg.Firebase.TestNumbers {
		return nil, errors.New("APP_ENV=prod with PNV_TEST_NUMBERS=true; test numbers would sign in")
	}
```

- mount auth with `auth.Mount(d, auth.Settings{Keys: cfg.Auth, Phones: firebase.NewPhoneVerifier(cfg.Firebase, time.Now, log)}, accounts)`.

`internal/app/app_test.go`: add `Firebase: firebasetest.New(t).Config(false),` to `testConfig`; delete `TestNewRefusesLogSendersInProd`, `quietSMS` and `quietEmail`; `TestNewRefusesLogPushInProd` calls `New(context.Background(), cfg, discard())`; add

```go
type quietPush struct{}

func (quietPush) Send(context.Context, string, push.Message) error { return nil }

// Test numbers of PNV sign anyone in as the zero number, so production
// refuses them.
func TestNewRefusesPNVTestNumbersInProd(t *testing.T) {
	t.Parallel()
	cfg := testConfig(t)
	cfg.Env, cfg.Firebase.TestNumbers = "prod", true
	_, err := New(context.Background(), cfg, discard(), WithPushSender(quietPush{}))
	if err == nil || !strings.Contains(err.Error(), "PNV_TEST_NUMBERS") {
		t.Fatalf("err %v", err)
	}
}
```

- [ ] **Step 5: Rewrite the SignIn service tests**

In `internal/auth/service/helpers_test.go` delete `codes`, `netipOf`, `clientIP`, `message`, `inbox`, `emailInbox`, `stored`, `hashOf`, `wrong` and the imports they used. In `sign_in_durable_test.go`:

```go
type signInEnv struct {
	run   ingress.Requester[service.PhoneSignIn, service.SignInResult]
	db    *pgxpool.Pool
	clock *restatetest.Clock
}

// startSignIn serves the SignIn service on Postgres stores; each change may
// wrap a store before the service is registered.
func startSignIn(t *testing.T, changes ...func(*service.SignIn)) *signInEnv {
	t.Helper()
	db := pgtest.New(t)
	clock := restatetest.NewClock(now)
	svc := service.SignIn{
		Prefix: restatetest.Prefix(), Credentials: repository.NewCredentials(db),
		Accounts: accountsvc.New(accountrepo.NewAccounts(db), nil, time.Now), Now: clock.Now,
	}
	for _, change := range changes {
		change(&svc)
	}
	client := restatetest.Start(t, restate.Reflect(svc))
	return &signInEnv{run: ingress.Service[service.PhoneSignIn, service.SignInResult](client, svc.ServiceName(), "Run"), db: db, clock: clock}
}

// signIn signs raw in under a fresh key.
func (e *signInEnv) signIn(t *testing.T, raw string) service.SignInResult {
	t.Helper()
	res, err := e.run.Request(context.Background(), service.PhoneSignIn{Phone: phone(t, raw)},
		restate.WithIdempotencyKey(uuid.NewV7().String()))
	if err != nil {
		t.Fatal(err)
	}
	return res
}
```

Keep `count`, `refused` (with `service.SignInResult`), `TestSignInCreatesThenFindsTheAccount`, `TestSignInRefusesASuspendedAccount`, `TestSignInMarksTheIdentityUsed`, `accountCommitThenFail` with `TestSignInSurvivesCommitThenFail`, `takenCredentials` with `TestSignInCompensatesWhenTheIdentityIsTaken`, `TestSignInMintsV7IDs`. `TestSignInReplayedKey` sends `service.PhoneSignIn{Phone: phone(t, "0901234567")}` twice with one key. Delete the challenge tests: `TestSignInCodeWorksOnce`, `TestSignInWrongCodeIsCounted`, `TestSignInLocksAfterFiveWrongCodes`, `TestSignInRefusesStaleChallenges`, `racingChallenges`, `TestSignInLostRaceSaysTryAgainForAnyCode`, `TestSignInUnderParallelGuesses`, `verifyCommitThenFail`, `TestSignInSurvivesVerifyCommitThenFail`, `TestSignInWrongCodeOnAUsedChallenge`.

Fix any other test in `internal/auth/service` that built `service.Deps` with the removed fields (`grep -n 'Challenges\|Quotas\|Codes:\|SMS:\|Email:' internal/auth/service/*_test.go`).

- [ ] **Step 6: Run everything**

Run:
```bash
grep -rn 'otp\|OTP\|provider/sms\|provider/email\|WithSMSSender\|WithEmailSender' --include='*.go' --include='*.yaml' internal api e2e cmd | grep -vi 'totp'
docker compose -f docker-compose.test.yml up -d --wait --force-recreate restate >tmp/restate.log 2>&1
GOFLAGS=-count=1 make test > tmp/make-test.log 2>&1; echo exit $?; grep -E '^(FAIL|--- FAIL)' tmp/make-test.log; tail -3 tmp/make-test.log
```
Expected: the grep prints nothing (staff TOTP stays); `exit 0`, no FAIL lines, `0 issues.`, and the e2e coverage check names no `signIn` status.

- [ ] **Step 7: Commit**

```bash
git add -A api internal e2e cmd Makefile .env.example
git commit -m "feat!: sign in with a phone token from Firebase

POST /v1/auth/sign-in takes the token Firebase returned for a verified
number. The handler checks it, then the SignIn service finds or creates
the account under the key <phone>/<Idempotency-Key>. The OTP endpoints,
challenges, quotas, OTP_KEY and the SMS and email senders are gone.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Phone-only identities and migration 0022

**Files:**
- Create: `migrations/0022_phone_sign_in.sql`
- Modify: `internal/auth/domain/credentials.go` (`KindEmail`, `KindGoogle` out), `internal/auth/service/identity.go` (`FindAccount` phones only), `internal/auth/service/service.go` (its comment), `api/schemas/staff.yaml:188` (`enum: [phone]`)
- Test: `internal/auth/repository/credentials_pg_test.go`, `internal/auth/service/identity_test.go`, any staff e2e that searches accounts by email

**Interfaces:**
- Produces: `identities.kind` holds `phone` only; `FindAccount(ctx, q)` matches phone numbers only.

- [ ] **Step 1: Write the failing tests**

In `internal/auth/repository/credentials_pg_test.go`, delete the email identity the tests build (`email, _ := contact.ParseEmail("linh@gmail.com")` at line 38 and its uses at 111, which become a second phone such as `contact.ParsePhone("0912345678")`), change line 77's `domain.KindEmail` lookup to `domain.Kind("email")`, and add:

```go
// Sign-in proves phone numbers only, so the table holds nothing else.
func TestIdentitiesArePhones(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	ctx := context.Background()
	acc := uuid.NewV7()
	if _, err := db.Exec(ctx, `INSERT INTO accounts (id, write_id) VALUES (@id, @id)`, pgx.StrictNamedArgs{"id": acc}); err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(ctx, `INSERT INTO credentials (account_id, write_id) VALUES (@id, @id)`, pgx.StrictNamedArgs{"id": acc}); err != nil {
		t.Fatal(err)
	}
	for _, tables := range []string{"otp_challenges", "otp_quotas"} {
		var exists bool
		if err := db.QueryRow(ctx, `SELECT to_regclass(@t) IS NOT NULL`, pgx.StrictNamedArgs{"t": tables}).Scan(&exists); err != nil || exists {
			t.Errorf("%s still exists: %v", tables, err)
		}
	}
	_, err := db.Exec(ctx, `INSERT INTO identities (id, account_id, kind, identifier) VALUES (@id, @acc, 'email', 'linh@gmail.com')`,
		pgx.StrictNamedArgs{"id": uuid.NewV7(), "acc": acc})
	if err == nil {
		t.Fatal("an email identity was stored")
	}
}
```

In `internal/auth/service/identity_test.go`, change any `FindAccount` case that looks up an email so it expects `false` with no error.

- [ ] **Step 2: Run and watch them fail**

Run: `go test -count=1 ./internal/auth/... 2>&1 | grep -E '^(---|ok|FAIL)|still exists|email' | head`
Expected: `TestIdentitiesArePhones` fails on `otp_challenges still exists` and `an email identity was stored`.

- [ ] **Step 3: Implement**

`migrations/0022_phone_sign_in.sql`:

```sql
-- Sign-in goes through Firebase: server2 sends no codes and knows phone
-- numbers only.
DROP TABLE otp_challenges, otp_quotas;

DELETE FROM identities WHERE kind <> 'phone';
DELETE FROM credentials c
WHERE NOT EXISTS (SELECT 1 FROM identities i WHERE i.account_id = c.account_id);
-- An account left without credentials that owns rows elsewhere stops the
-- migration on that foreign key; no other row is deleted with it.
DELETE FROM accounts a
WHERE NOT EXISTS (SELECT 1 FROM credentials c WHERE c.account_id = a.id);

ALTER TABLE identities
    DROP CONSTRAINT identities_kind_check,
    ADD CONSTRAINT identities_kind_check CHECK (kind = 'phone');
```

Check the constraint's name first: `docker exec shopnexus-server2-test-postgres-1 psql -U postgres -lqt` is not needed; run `grep -n 'CHECK (kind' migrations/0002_auth.sql` (an inline column check is named `identities_kind_check`), and if `make test` reports the constraint missing, read its name from `\d identities` in a pgtest database.

`internal/auth/domain/credentials.go`: the kinds become

```go
const KindPhone Kind = "phone"
```

and `NewIdentity`'s comment: `// NewIdentity builds the identity of a phone number Firebase just verified; it counts as used at now.`

`internal/auth/service/identity.go`'s `FindAccount`:

```go
// FindAccount returns the account holding the phone number q, in any form a
// person types. A q that is no Vietnamese mobile number, or that no account
// holds, reports false.
func (a *Auth) FindAccount(ctx context.Context, q string) (uuid.UUID, bool, error) {
	addr, err := contact.ParsePhone(q)
	if err != nil {
		return uuid.UUID{}, false, nil //nolint:nilerr // A q that is no phone number matches no account.
	}
	ref, err := a.credentials.FindIdentity(ctx, domain.KindPhone, addr.Value())
	...unchanged...
}
```

(drop the `strings` import). The `FindAccount` comment in `service.go` becomes `// FindAccount returns the account holding the phone number q.`

`api/schemas/staff.yaml:188`: `enum: [phone]`.

Run `grep -rn 'KindEmail\|KindGoogle\|"email"' internal/auth internal/staff e2e --include='*.go'` and fix what is left: staff member emails (`internal/staff`) stay; account searches by email in `e2e/staff_accounts_test.go`, if any, expect an empty list.

- [ ] **Step 4: Run everything**

Run:
```bash
docker compose -f docker-compose.test.yml up -d --wait --force-recreate restate >tmp/restate.log 2>&1
GOFLAGS=-count=1 make test > tmp/make-test.log 2>&1; echo exit $?; grep -E '^(FAIL|--- FAIL)' tmp/make-test.log; tail -3 tmp/make-test.log
```
Expected: `exit 0`, no FAIL lines, `0 issues.`

Then apply the migration to the development database: `make run` in the background until the server logs it is listening (or `go run ./cmd/server` with `.env`), and confirm `SELECT kind, count(*) FROM identities GROUP BY kind` shows `phone` only, then stop the server.

- [ ] **Step 5: Commit**

```bash
git add -A migrations internal api e2e
git commit -m "feat: phone identities only

Migration 0022 drops the OTP tables, deletes identities that are not
phones with the credentials and accounts they leave empty, and limits
identities.kind to phone. Staff account search matches phone numbers only.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: ARCHITECTURE.md

**Files:**
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Rewrite the auth sections**

- Replace "### OTP send" and "### OTP verify and sign-up" with one section "### Phone sign-in" that states: the endpoint and its body; the decision date 2026-10-28 and the spec path; the handler verifies with `provider/firebase` and passes only the number to `SignIn` under `<phone>/<Idempotency-Key>`; the token checks of both issuers (the table of the spec, as prose or a table); freshness 5 minutes, skew 30 seconds, `exp` accepted as the only replay bound beyond freshness, as the user chose; key sets (max-age, one fetch a minute, failed fetch keeps keys, 503 with none); test numbers only with `PNV_TEST_NUMBERS=true` and prod refusing it; Firebase user records left alone; no quota on the endpoint; e2e serving its own keys with PNV down.
- "### Idempotency-Key": add that the sign-in key is scoped by the number, as listing posts are scoped by the seller.
- "### Aggregates in auth and account": delete the `Challenge` line; `Credentials` holds phone identities.
- The tables list: delete `otp_challenges`/`otp_quotas` rows and the `Challenge` mapping.
- The catalog bullet about `ListingPost` checks: delete "no verified phone (...)"; do the same wherever deal and chat list `phone_required`.
- Configuration: `FIREBASE_*`, `PNV_*` and the removal of `OTP_KEY`, `FCM_PROJECT_ID`, and the SMS and email senders.

Run `grep -n -i 'otp\|sms\|phone_required\|email' ARCHITECTURE.md` and settle each remaining hit (staff email sign-in and TOTP stay).

- [ ] **Step 2: Check the prose**

Run: `awk '/^### Phone sign-in/,/^### Idempotency-Key/' ARCHITECTURE.md > tmp/arch-signin.md && python3 ~/.claude/skills/humanizing-writing/ai-tells.py --stats tmp/arch-signin.md | tail -3`
Expected: `0 hits`, or each hit rewritten.

- [ ] **Step 3: Commit**

```bash
git add ARCHITECTURE.md
git commit -m "docs: sign-in through Firebase

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
