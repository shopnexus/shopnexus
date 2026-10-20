# server2 Plan 2: redesign and OTP sign-in Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
>
> Claude implements this plan natively, as the user asked on 2026-10-20 ("chạy native ko hỏi"), so each step carries its code.

**Goal:** Move server2 onto the redesigned architecture (ports, `write_id`, Restate instead of the outbox and NATS) and build OTP sign-in on it: send a code, sign in or up, refresh, sign out, list and remove devices, read and rename the account.

**Architecture:** Use cases are plain functions taking ports; adapters hold one transaction per aggregate and detect concurrent writes with a `write_id` column. OTP send and sign-in run as Restate services called with the client's `Idempotency-Key`; every other use case is called directly from its HTTP handler. Restate runs on the host network so it can call the process's endpoint.

**Tech Stack:** Go 1.27.2, PostgreSQL 19 RC 1, pgx v5.11.0, Restate server 1.8.0 with `github.com/restatedev/sdk-go` v1.1.0, `github.com/golang-jwt/jwt/v5` v5.3.1, kin-openapi v0.151.0, OpenTelemetry.

**Spec:** `~/shopnexus/specs/2026-10-19-server2-foundation-design.md` (umbrella 146d24b) and `~/shopnexus/server2/ARCHITECTURE.md` (server2 802053e). `ARCHITECTURE.md` wins where they differ. Builds on server2 `main` at 802053e.

## Scope

Spec build steps 7 and 8:

| Task | Delivers |
|---|---|
| 1 | Restate in both stacks, `platform/restatex` and `restatetest`, jobs and NATS removed |
| 2 | error details, client IP, auth keys and `make keys`, `authn.ErrUnauthenticated` |
| 3 | squashed migrations with `write_id`, module account rewritten as functions with ports |
| 4 | `platform/contact` |
| 5 | `auth/otp`: challenges, derived codes, quotas |
| 6 | `auth/credentials` |
| 7 | `auth/session`: sessions and EdDSA tokens |
| 8 | `POST /v1/auth/otp` through Restate service `OTP` |
| 9 | `POST /v1/auth/otp/verify` through Restate service `SignIn` |
| 10 | sign-in middleware and `/v1/accounts/me` |
| 11 | `POST /v1/auth/refresh` |
| 12 | logout, logout-all, device list and removal |
| 13 | run by hand, record the rulings in `ARCHITECTURE.md` |

Attack tests here: 50 parallel OTP guesses, parallel OTP sends from one address, refresh replay, parallel refresh, identical OTP-send replies for known and unknown destinations, account B reading account A's sessions. Plan 3 adds passwords, Google, the identity endpoints, the dormant check and the observability exercise.

## Global Constraints

- Module path `github.com/shopnexus/server2`; repository `~/shopnexus/server2`.
- SQL by hand in Go; no sqlc, ORM, query builder or code generation.
- Third-party modules in product code: pgx v5, kin-openapi, golang-jwt v5, go-oidc v3, golang.org/x/crypto, Restate SDK, OpenTelemetry.
- A use case is a plain function that takes ports and parameters. Business code takes no function arguments. Only Restate service files (`*_service.go`) pass closures, to `restate.Run`.
- A transaction lives inside one adapter method and covers one aggregate. `Save(ctx, *agg, writeID)` fails with the module's `ErrConflict` when the row's `write_id` is neither the one read nor `writeID`.
- IDs are stdlib `uuid.UUID`, chosen before the insert: `uuid.UUID(restate.UUID(ctx))` inside a Restate handler, `uuid.NewV7()` elsewhere. `Create` is idempotent (`ON CONFLICT DO NOTHING`).
- Code outside `restate.Run` in a Restate handler is deterministic: no clock, randomness or I/O.
- Tokens and OTP codes never enter Restate (inputs, journal or outputs). Codes are derived from the challenge ID with `OTP_KEY`; the sign-in service receives the code's HMAC, never the code.
- Business refusals cross Restate as a `Refusal` in the result, never as terminal errors, which reach the caller as a bare 500.
- No raw database error reaches an HTTP client. No flow tells a caller who has not proved ownership whether an account exists.
- Passwords, codes and tokens never appear in logs; phones and emails are logged through `contact.Address`.
- Every OpenAPI operation declares only statuses an E2E test observes.
- Tests: no build tags; integration and E2E tests skip under `-short` and fail when the test stack is missing. Run `make test-up` first.

## Decisions this plan makes beyond the spec

| Decision | Why | Cost if wrong |
|---|---|---|
| Restate "workflows" are Restate services invoked with an idempotency key | a repeated key returns the first result (checked against Restate 1.8.0 on 2026-10-20); workflows add attach logic for nothing here | rename to workflows later |
| Restate runs with `network_mode: host` on 127.0.0.1 ports | `ufw` on the dev machine drops container-to-host traffic, and Restate must call the host process | a Compose change when the server moves into Docker |
| Endpoint registered over HTTP/1.1 (`use_http_11`) at server start | the endpoint shares the standard library server; Restate's default HTTP/2 prior knowledge failed in the probe | none |
| Per-test service-name prefix | packages run in parallel against one Restate server, and a service name routes to one endpoint | none |
| OTP code = `HMAC(OTP_KEY, "otp-code:" ‖ challenge_id) mod 10^6` | the send step recomputes the same code on retry, and the code is never journaled | the key now guards codes as well as hashes, as before |
| The verify handler loads the challenge and passes `code_hash` to `SignIn` | the code stays out of Restate; the hash is what the database already holds | one extra read per verify |
| `Save` on a quota retries up to 3 times on conflict inside its step | parallel sends from one address behind NAT should not get spurious 429s | a send counted twice in a crash-and-conflict race |
| A write conflict on a challenge returns 409 `try_again` | the same reply for right and wrong guesses | one more status in the spec |
| Session issue is create-or-rotate by the `session_id` the service chose | a retried sign-in with the same key returns working tokens for the same session | none |

## Review Focus

1. A wrong code: its attempt stays counted after the reply, and 50 parallel guesses never get more than 5 counted. Pinned in Task 9, `TestVerifyChallengeUnderParallelGuesses`.
2. Parallel sends from one address to many numbers: at most 20 codes leave. Pinned in Task 8, `TestOTPSendCapsOneAddress`.
3. A step that commits and then fails with a retryable error: Restate retries it and no row is duplicated. Pinned in Task 8, `TestOTPSendSurvivesCommitThenFail`, and Task 9, `TestSignInSurvivesCommitThenFail`.
4. A retried tap with the same `Idempotency-Key`: the same account and a working token, no second account. Pinned in Task 9, `TestSignInReplayedKey`.
5. A phone typed as `0901234567` and later as `+84 90 123 4567`: one account. Pinned in Task 9, `TestSignInIgnoresPhoneFormat`.

## How each task runs

1. Read the task and the spec or `ARCHITECTURE.md` sections it names.
2. Write the tests, run them and watch them fail for the stated reason.
3. Implement until they pass, then `make lint` and the task's test command.
4. Commit with the task's message. Comments and commit messages go through the `humanizing-writing` checker first.

## File map

```
server2/
  docker-compose.yml, docker-compose.test.yml   - nats, + restate (host network)
  Makefile, .env.example                        + Restate variables, keys target
  cmd/keygen/main.go
  api/                                          + responses/, auth and account operations
  migrations/0001_accounts.sql, 0002_auth.sql   squashed, with write_id
  internal/
    platform/
      restatex/      Serve, Register, Healthy
      restatetest/   Start, URLs, Prefix
      contact/       Address, ParsePhone, ParseEmail
      apperr/ httpx/ authn/ config/             additions
      jobs/, natstest/                          removed
    provider/sms, provider/email                Sender ports and log senders only
    account/         entity, Store, functions, Client adapter, handlers, routes
    auth/
      otp/           Challenge, Codes, Quota, stores
      credentials/   Credentials, Identity, store
      session/       Session, Signer, Verifier, Tokens, store
      refusal.go, restate.go, middleware.go, routes.go
      otp_send.go, otp_service.go, sign_in.go, sign_in_service.go, session_issue.go
      session_refresh.go, session_logout.go, session_logout_all.go, session_list.go, session_delete.go
    app/app.go
  e2e/               + inbox, auth helpers, auth and account tests
```

---

### Task 1: Restate replaces the job pipeline

**Files:**
- Delete: `internal/platform/jobs/`, `internal/platform/natstest/`
- Modify: `internal/provider/sms/sms.go`, `sms_test.go`, `internal/provider/email/email.go`, `email_test.go` (remove `SendCommand`)
- Create: `internal/platform/restatex/restatex.go`, `restatex_test.go`
- Create: `internal/platform/restatetest/restatetest.go`
- Modify: `internal/platform/config/config.go`, `config_test.go`
- Modify: `internal/app/app.go`, `app_test.go`, `routes_test.go`
- Modify: `e2e/main_test.go`, `e2e/system_test.go`
- Modify: `docker-compose.yml`, `docker-compose.test.yml`, `Makefile`, `.env.example`, `go.mod`, `go.sum`

**Interfaces:**
- Produces: `restatex.Serve(addr string, defs ...restate.ServiceDefinition) (*restatex.Endpoint, error)`, `(*Endpoint).URL() string`, `(*Endpoint).Close(ctx) error`, `restatex.Register(ctx, adminURL, endpointURL string) error`, `restatex.Healthy(ctx, adminURL string) error`
- Produces: `restatetest.URLs(t testing.TB) (ingressURL, adminURL string)`, `restatetest.URLsForMain() (string, string, error)`, `restatetest.Prefix() string`, `restatetest.Start(t testing.TB, defs ...restate.ServiceDefinition) *ingress.Client`
- Produces: `config.Config.Restate config.RestateConfig{IngressURL, AdminURL, ListenAddr, EndpointURL string}` (replaces `NATSURL`)
- Produces: `app.Option`, `app.WithSMSSender(sms.Sender)`, `app.WithEmailSender(email.Sender)`, `app.WithRestatePrefix(string)`, `app.New(ctx, cfg, log, opts ...Option)`

- [ ] **Step 1: Remove the job pipeline**

```bash
cd ~/shopnexus/server2
git rm -rq internal/platform/jobs internal/platform/natstest
```

In `internal/provider/sms/sms.go` and `internal/provider/email/email.go`, delete `SendCommand` and its `Subject` method; delete the tests that use them. In `internal/app/app.go` delete `startJobs`, `connectNATS`, the `nc`, `stop`, `wg` and `consumers` fields, `stopBackground`, and their imports. `migrations/0002_outbox.sql` stays until Task 3 squashes the migrations.

- [ ] **Step 2: Add Restate to both stacks**

In `docker-compose.yml`, replace the `nats` service and its volume with:

```yaml
  restate:
    image: restatedev/restate:1.8.0
    # Host network: ufw drops container-to-host traffic, and Restate must
    # call the server's endpoint on the host.
    network_mode: host
    environment:
      RESTATE_BASE_DIR: /restate-data
      RESTATE_INGRESS__BIND_ADDRESS: 127.0.0.1:56580
      RESTATE_ADMIN__BIND_ADDRESS: 127.0.0.1:56570
      RESTATE_BIND_ADDRESS: 127.0.0.1:56560
      RESTATE_ADVERTISED_ADDRESS: http://127.0.0.1:56560
    volumes:
      - restate:/restate-data
```

and add `restate:` under `volumes:`. In `docker-compose.test.yml` add:

```yaml
  restate:
    image: restatedev/restate:1.8.0
    network_mode: host
    environment:
      RESTATE_BASE_DIR: /restate-data
      RESTATE_INGRESS__BIND_ADDRESS: 127.0.0.1:56581
      RESTATE_ADMIN__BIND_ADDRESS: 127.0.0.1:56571
      RESTATE_BIND_ADDRESS: 127.0.0.1:56561
      RESTATE_ADVERTISED_ADDRESS: http://127.0.0.1:56561
    tmpfs:
      - /restate-data:size=512m
    mem_limit: 768m
```

In the `Makefile`, next to `TEST_DATABASE_URL`:

```make
TEST_RESTATE_INGRESS_URL ?= http://127.0.0.1:56581
TEST_RESTATE_ADMIN_URL ?= http://127.0.0.1:56571
export TEST_RESTATE_INGRESS_URL TEST_RESTATE_ADMIN_URL
```

In `.env.example`, replace `NATS_URL=...` with:

```
RESTATE_INGRESS_URL=http://127.0.0.1:56580
RESTATE_ADMIN_URL=http://127.0.0.1:56570
RESTATE_LISTEN_ADDR=127.0.0.1:9080
RESTATE_ENDPOINT_URL=http://127.0.0.1:9080
```

Run: `go get github.com/restatedev/sdk-go@v1.1.0 && make down && make up && make test-down && make test-up && curl -s 127.0.0.1:56571/health -o /dev/null -w '%{http_code}\n'`
Expected: `200`. If `go list -m -versions github.com/restatedev/sdk-go` or Docker Hub shows a newer release, take it and ledger the change.

- [ ] **Step 3: Write the failing tests**

Create `internal/platform/restatex/restatex_test.go`:

```go
package restatex_test

import (
	"context"
	"sync/atomic"
	"testing"

	restate "github.com/restatedev/sdk-go"
	"github.com/restatedev/sdk-go/ingress"

	"github.com/shopnexus/server2/internal/platform/restatetest"
)

// counter counts how many times its step body really ran.
type counter struct {
	prefix string
	runs   *atomic.Int32
}

func (c counter) ServiceName() string { return c.prefix + "Counter" }

func (c counter) Bump(ctx restate.Context, label string) (string, error) {
	n, err := restate.Run(ctx, func(restate.RunContext) (int32, error) { return c.runs.Add(1), nil })
	if err != nil {
		return "", err
	}
	return label + "-" + string(rune('0'+n)), nil
}

func TestServeRegisterAndCall(t *testing.T) {
	runs := &atomic.Int32{}
	svc := counter{prefix: restatetest.Prefix(), runs: runs}
	client := restatetest.Start(t, restate.Reflect(svc))
	bump := ingress.Service[string, string](client, svc.ServiceName(), "Bump")
	ctx := context.Background()

	first, err := bump.Request(ctx, "a", restate.WithIdempotencyKey("key-1"))
	if err != nil {
		t.Fatal(err)
	}
	again, err := bump.Request(ctx, "a", restate.WithIdempotencyKey("key-1"))
	if err != nil || again != first {
		t.Fatalf("same key: %q %v, first %q", again, err, first)
	}
	if runs.Load() != 1 {
		t.Fatalf("the step ran %d times for one key", runs.Load())
	}
	if _, err := bump.Request(ctx, "b", restate.WithIdempotencyKey("key-2")); err != nil || runs.Load() != 2 {
		t.Fatalf("new key: %v, runs %d", err, runs.Load())
	}
}

func TestHealthy(t *testing.T) {
	_, admin := restatetest.URLs(t)
	if err := restatex.Healthy(context.Background(), admin); err != nil {
		t.Fatal(err)
	}
	if err := restatex.Healthy(context.Background(), "http://127.0.0.1:1"); err == nil {
		t.Fatal("a closed port reported healthy")
	}
}
```

Add `"github.com/shopnexus/server2/internal/platform/restatex"` to the imports.

In `internal/platform/config/config_test.go`: `required()` returns `DATABASE_URL`, `RESTATE_INGRESS_URL: "http://restate:8080"` and `RESTATE_ADMIN_URL: "http://restate:9070"` instead of `NATS_URL`; `TestLoadAllSet` sets `RESTATE_INGRESS_URL`, `RESTATE_ADMIN_URL`, `RESTATE_LISTEN_ADDR: "127.0.0.1:9999"`, `RESTATE_ENDPOINT_URL: "http://host:9999"` and expects them in `Restate`; `TestLoadDefaults` checks `got.Restate.ListenAddr == "127.0.0.1:9080" && got.Restate.EndpointURL == ""`; the missing-variable list is `DATABASE_URL`, `RESTATE_INGRESS_URL`, `RESTATE_ADMIN_URL`.

In `internal/app/app_test.go`: `testConfig` becomes

```go
func testConfig(t *testing.T) config.Config {
	t.Helper()
	ingressURL, adminURL := restatetest.URLs(t)
	return config.Config{
		DatabaseURL: pgtest.New(t).Config().ConnString(),
		Restate:     config.RestateConfig{IngressURL: ingressURL, AdminURL: adminURL, ListenAddr: "127.0.0.1:0"},
	}
}
```

`newAppWithLog` passes `WithRestatePrefix(restatetest.Prefix())`. Delete `TestSMSJobReachesSender`. Replace `TestReadyzNATSDown` with:

```go
func TestReadyzRestateDown(t *testing.T) {
	cfg := testConfig(t)
	cfg.Restate.AdminURL = "http://127.0.0.1:1"
	a, err := New(context.Background(), cfg, discard())
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { a.Close(context.Background()) })
	if code, body := get(a, "/readyz"); code != http.StatusServiceUnavailable {
		t.Fatalf("got %d %q", code, body)
	}
}
```

- [ ] **Step 4: Run them and watch them fail**

Run: `go test ./internal/platform/restatex/ ./internal/platform/config/ ./internal/app/`
Expected: build failures naming `restatex`, `restatetest`, `RestateConfig`, `WithRestatePrefix`.

- [ ] **Step 5: Implement `restatex`, `restatetest`, config and app**

Create `internal/platform/restatex/restatex.go`:

```go
// Package restatex serves this process's Restate services and registers them
// with the Restate server.
package restatex

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"time"

	restate "github.com/restatedev/sdk-go"
	"github.com/restatedev/sdk-go/server"
)

// Endpoint is the HTTP/1.1 server Restate calls to run handlers.
type Endpoint struct {
	srv *http.Server
	ln  net.Listener
}

// Serve binds defs and serves them on addr; "127.0.0.1:0" picks a free port.
func Serve(addr string, defs ...restate.ServiceDefinition) (*Endpoint, error) {
	r := server.NewRestate().Bidirectional(false)
	for _, d := range defs {
		r = r.Bind(d)
	}
	h, err := r.Handler()
	if err != nil {
		return nil, err
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, err
	}
	e := &Endpoint{srv: &http.Server{Handler: h, ReadHeaderTimeout: 5 * time.Second}, ln: ln}
	go e.srv.Serve(ln)
	return e, nil
}

// URL is the address Restate calls when RESTATE_ENDPOINT_URL is empty.
func (e *Endpoint) URL() string { return "http://" + e.ln.Addr().String() }

func (e *Endpoint) Close(ctx context.Context) error { return e.srv.Shutdown(ctx) }

// Register asks the Restate server at adminURL to discover the services
// served at endpointURL, replacing an earlier registration of the same names.
// HTTP/1.1 is used because the endpoint is a standard library server.
func Register(ctx context.Context, adminURL, endpointURL string) error {
	body, err := json.Marshal(map[string]any{"uri": endpointURL, "force": true, "use_http_11": true})
	if err != nil {
		return err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(adminURL, "/")+"/deployments", bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("register restate endpoint: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode/100 != 2 {
		msg, _ := io.ReadAll(io.LimitReader(res.Body, 4<<10))
		return fmt.Errorf("register restate endpoint: %s: %s", res.Status, msg)
	}
	return nil
}

// Healthy reports whether the Restate admin API answers.
func Healthy(ctx context.Context, adminURL string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(adminURL, "/")+"/health", nil)
	if err != nil {
		return err
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("restate admin health: %s", res.Status)
	}
	return nil
}
```

Create `internal/platform/restatetest/restatetest.go`:

```go
// Package restatetest connects tests to the test stack's Restate server.
package restatetest

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"os"
	"testing"
	"time"

	restate "github.com/restatedev/sdk-go"
	"github.com/restatedev/sdk-go/ingress"

	"github.com/shopnexus/server2/internal/platform/restatex"
)

// URLsForMain returns the test stack's ingress and admin URLs.
func URLsForMain() (string, string, error) {
	ingressURL, adminURL := os.Getenv("TEST_RESTATE_INGRESS_URL"), os.Getenv("TEST_RESTATE_ADMIN_URL")
	if ingressURL == "" || adminURL == "" {
		return "", "", errors.New("TEST_RESTATE_INGRESS_URL and TEST_RESTATE_ADMIN_URL are not set: run `make test-up` and use make")
	}
	return ingressURL, adminURL, nil
}

// URLs skips the test under -short and fails it when the test stack's URLs
// are missing.
func URLs(t testing.TB) (string, string) {
	t.Helper()
	if testing.Short() {
		t.Skip("needs Restate")
	}
	ingressURL, adminURL, err := URLsForMain()
	if err != nil {
		t.Fatal(err)
	}
	return ingressURL, adminURL
}

// Prefix returns a fresh service-name prefix. Test packages run in parallel
// against one Restate server, and a service name routes to one endpoint, so
// every registration needs names of its own.
func Prefix() string {
	b := make([]byte, 4)
	rand.Read(b)
	return "t" + hex.EncodeToString(b) + "_"
}

// Start serves defs on a free local port, registers them with the test
// stack's Restate and returns an ingress client.
func Start(t testing.TB, defs ...restate.ServiceDefinition) *ingress.Client {
	t.Helper()
	ingressURL, adminURL := URLs(t)
	ep, err := restatex.Serve("127.0.0.1:0", defs...)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ep.Close(context.Background()) })
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := restatex.Register(ctx, adminURL, ep.URL()); err != nil {
		t.Fatal(err)
	}
	return ingress.NewClient(ingressURL)
}
```

In `internal/platform/config/config.go`, replace the `NATSURL` field with `Restate RestateConfig` and add:

```go
// RestateConfig says where the Restate server is and how it reaches this
// process.
type RestateConfig struct {
	IngressURL  string // RESTATE_INGRESS_URL
	AdminURL    string // RESTATE_ADMIN_URL
	ListenAddr  string // RESTATE_LISTEN_ADDR: where this process serves its Restate endpoint
	EndpointURL string // RESTATE_ENDPOINT_URL: how Restate reaches it; empty means http://ListenAddr
}
```

and in `Load`, replace `NATSURL: need("NATS_URL"),` with:

```go
		Restate: RestateConfig{
			IngressURL:  need("RESTATE_INGRESS_URL"),
			AdminURL:    need("RESTATE_ADMIN_URL"),
			ListenAddr:  get("RESTATE_LISTEN_ADDR", "127.0.0.1:9080"),
			EndpointURL: get("RESTATE_ENDPOINT_URL", ""),
		},
```

In `internal/app/app.go`:

```go
// Option changes how New builds the app.
type Option func(*options)

type options struct {
	sms           sms.Sender
	email         email.Sender
	restatePrefix string
}

// WithSMSSender replaces the log sender; E2E tests read codes from theirs.
func WithSMSSender(s sms.Sender) Option { return func(o *options) { o.sms = s } }

// WithEmailSender replaces the log sender.
func WithEmailSender(s email.Sender) Option { return func(o *options) { o.email = s } }

// WithRestatePrefix prefixes every Restate service name, so tests sharing one
// Restate server do not route to each other's endpoints.
func WithRestatePrefix(p string) Option { return func(o *options) { o.restatePrefix = p } }
```

`App` gains fields `cfg config.Config`, `endpoint *restatex.Endpoint`, `ingress *ingress.Client`, `opts options`. `New(ctx, cfg, log, opts ...Option)` builds `options{sms: sms.LogSender{Log: log}, email: email.LogSender{Log: log}}`, applies `opts`, sets `a.ingress = ingress.NewClient(cfg.Restate.IngressURL)`, and after the routes calls `a.startRestate(ctx, cfg, log, nil)`; Task 8 passes the auth services. `/readyz` uses `a.ready`:

```go
// startRestate serves defs and registers them, retrying for up to 30 s while
// the Restate server starts. With no services there is nothing to serve.
func (a *App) startRestate(ctx context.Context, cfg config.Config, log *slog.Logger, defs []restate.ServiceDefinition) error {
	if len(defs) == 0 {
		return nil
	}
	ep, err := restatex.Serve(cfg.Restate.ListenAddr, defs...)
	if err != nil {
		return fmt.Errorf("restate endpoint: %w", err)
	}
	a.endpoint = ep
	url := cfg.Restate.EndpointURL
	if url == "" {
		url = ep.URL()
	}
	for attempt := range 15 {
		if err = restatex.Register(ctx, cfg.Restate.AdminURL, url); err == nil {
			return nil
		}
		log.WarnContext(ctx, "restate not reachable yet", "attempt", attempt+1, "err", err)
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(2 * time.Second):
		}
	}
	return err
}

func (a *App) ready(ctx context.Context) error {
	if err := a.pool.Ping(ctx); err != nil {
		return err
	}
	return restatex.Healthy(ctx, a.cfg.Restate.AdminURL)
}

// Close stops the Restate endpoint and closes the pool.
func (a *App) Close(ctx context.Context) error {
	if a.endpoint != nil {
		a.endpoint.Close(ctx)
	}
	a.pool.Close()
	return nil
}
```

In `e2e/main_test.go`, replace the NATS start with:

```go
	ingressURL, adminURL, err := restatetest.URLsForMain()
	if err != nil {
		fmt.Fprintln(os.Stderr, "e2e:", err)
		return 1
	}
	cfg := config.Config{
		DatabaseURL: pool.Config().ConnString(),
		Restate:     config.RestateConfig{IngressURL: ingressURL, AdminURL: adminURL, ListenAddr: "127.0.0.1:0"},
	}
	a, err := app.New(context.Background(), cfg, discard, app.WithRestatePrefix(restatetest.Prefix()))
```

In `e2e/system_test.go`, `TestReadyzDown` builds its config the same way with `restatetest.URLs(t)` and `pgtest.New(t)`.

- [ ] **Step 6: Run the suite**

Run: `go mod tidy && make lint && make test`
Expected: PASS. `go.mod` no longer lists `nats.go` or `nats-server`. `TestServeRegisterAndCall` shows one step run for two calls with one key.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: replace the outbox, relay and NATS with Restate"
```

### Task 2: Platform additions for auth

**Files:**
- Modify: `internal/platform/apperr/apperr.go`, `apperr_test.go`, `internal/platform/httpx/respond.go`, `respond_test.go`, `api/schemas/error.yaml`
- Create: `internal/platform/httpx/clientip.go`, `clientip_test.go`
- Modify: `internal/platform/authn/authn.go`, `authn_test.go`
- Modify: `internal/platform/config/config.go`, `config_test.go`; Create: `internal/platform/config/keys.go`, `cmd/keygen/main.go`
- Modify: `internal/account/errors.go`, `account_get.go`, `account_rename.go`, `internal/app/app.go`, `app_test.go`, `e2e/main_test.go`, `e2e/system_test.go`, `Makefile`, `.env.example`

**Interfaces:**
- Produces: `apperr.Error.Details map[string]any`, `(*apperr.Error).WithDetail(name string, value any) *apperr.Error`
- Produces: `httpx.ClientIP(r *http.Request, trusted []netip.Prefix) netip.Addr`
- Produces: `authn.ErrUnauthenticated` (401 `unauthenticated`)
- Produces: `config.Config.TrustedProxies []netip.Prefix`, `config.Config.Auth config.AuthConfig{OTPKey []byte; JWTKeyID string; JWTKey ed25519.PrivateKey; JWTPrevKeyID string; JWTPrevKey ed25519.PublicKey; Issuer, Audience string}`, `config.NewAuthKeys() AuthConfig`, `(AuthConfig).Env() string`

- [ ] **Step 1: Write the failing tests**

Append to `internal/platform/apperr/apperr_test.go`:

```go
func TestWithDetailCopies(t *testing.T) {
	base := apperr.New(apperr.KindInvalid, "invalid_code", "the code does not match")
	got := base.WithDetail("attempts_left", 4)
	if got.Details["attempts_left"] != 4 || base.Details != nil || !errors.Is(got, base) {
		t.Fatalf("copy %v, base %v", got.Details, base.Details)
	}
	if again := got.WithDetail("retry_after", 9); len(got.Details) != 1 || len(again.Details) != 2 {
		t.Fatalf("got %v, again %v", got.Details, again.Details)
	}
}
```

Append to `internal/platform/httpx/respond_test.go`:

```go
func TestWriteErrorIncludesDetails(t *testing.T) {
	rec, _ := failWith(t, apperr.New(apperr.KindInvalid, "invalid_code", "no match").WithDetail("attempts_left", 4))
	var body struct {
		Error struct {
			Details map[string]any `json:"details"`
		} `json:"error"`
	}
	if err := json.Unmarshal(rec.Body.Bytes(), &body); err != nil || body.Error.Details["attempts_left"] != float64(4) {
		t.Fatalf("%s %v", rec.Body.String(), err)
	}
	if rec, _ := failWith(t, apperr.New(apperr.KindInvalid, "x", "y")); strings.Contains(rec.Body.String(), "details") {
		t.Fatalf("empty details written: %s", rec.Body.String())
	}
}
```

Create `internal/platform/httpx/clientip_test.go`:

```go
package httpx

import (
	"net/http/httptest"
	"net/netip"
	"testing"
)

func TestClientIP(t *testing.T) {
	proxies := []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8")}
	cases := []struct {
		name    string
		remote  string
		xff     []string
		trusted []netip.Prefix
		want    string
	}{
		{"direct, header ignored", "203.0.113.7:5000", []string{"198.51.100.1"}, nil, "203.0.113.7"},
		{"untrusted remote, header ignored", "203.0.113.7:5000", []string{"198.51.100.1"}, proxies, "203.0.113.7"},
		{"trusted proxy", "10.0.0.1:5000", []string{"198.51.100.1"}, proxies, "198.51.100.1"},
		{"spoofed left entry ignored", "10.0.0.1:5000", []string{"6.6.6.6, 198.51.100.1, 10.0.0.2"}, proxies, "198.51.100.1"},
		{"two headers joined", "10.0.0.1:5000", []string{"6.6.6.6", "198.51.100.1"}, proxies, "198.51.100.1"},
		{"no header", "10.0.0.1:5000", nil, proxies, "10.0.0.1"},
		{"garbage hop", "10.0.0.1:5000", []string{"nonsense"}, proxies, "10.0.0.1"},
		{"ipv6", "[2001:db8::1]:443", nil, nil, "2001:db8::1"},
		{"ipv4-mapped ipv6", "[::ffff:203.0.113.7]:80", nil, nil, "203.0.113.7"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := httptest.NewRequest("GET", "/", nil)
			r.RemoteAddr = c.remote
			for _, v := range c.xff {
				r.Header.Add("X-Forwarded-For", v)
			}
			if got := ClientIP(r, c.trusted); got.String() != c.want {
				t.Fatalf("got %s, want %s", got, c.want)
			}
		})
	}
}
```

Append to `internal/platform/authn/authn_test.go` (imports `errors`, `apperr`):

```go
func TestErrUnauthenticated(t *testing.T) {
	var e *apperr.Error
	if !errors.As(authn.ErrUnauthenticated, &e) || e.Kind != apperr.KindUnauthenticated || e.Code != "unauthenticated" {
		t.Fatalf("%+v", authn.ErrUnauthenticated)
	}
}
```

In `internal/platform/config/config_test.go` (imports `bytes`, `crypto/ed25519`, `encoding/base64`, `maps`, `net/netip`, `reflect`): add

```go
var testKeys = NewAuthKeys()

func b64(b []byte) string { return base64.StdEncoding.EncodeToString(b) }
```

`required()` also returns `OTP_KEY: b64(testKeys.OTPKey)`, `JWT_KEY_ID: testKeys.JWTKeyID`, `JWT_PRIVATE_KEY: b64(testKeys.JWTKey.Seed())`. `TestLoadAllSet` compares with `reflect.DeepEqual` (a `Config` holding slices is not comparable with `!=`), also sets `TRUSTED_PROXIES: "10.0.0.0/8, 192.168.1.7/32"`, `JWT_PREVIOUS_KEY_ID: "old"`, `JWT_PREVIOUS_PUBLIC_KEY: b64(prev.JWTKey.Public().(ed25519.PublicKey))` with `prev := NewAuthKeys()`, `JWT_ISSUER: "iss"`, `JWT_AUDIENCE: "aud"`, and expects `TrustedProxies: []netip.Prefix{netip.MustParsePrefix("10.0.0.0/8"), netip.MustParsePrefix("192.168.1.7/32")}` and `Auth: AuthConfig{OTPKey: testKeys.OTPKey, JWTKeyID: testKeys.JWTKeyID, JWTKey: testKeys.JWTKey, JWTPrevKeyID: "old", JWTPrevKey: prev.JWTKey.Public().(ed25519.PublicKey), Issuer: "iss", Audience: "aud"}`. `TestLoadDefaults` also checks `got.Auth.Issuer == "server2" && got.Auth.Audience == "shopnexus-app" && got.TrustedProxies == nil`. The missing-variable list adds `OTP_KEY`, `JWT_KEY_ID`, `JWT_PRIVATE_KEY`. Append:

```go
func TestLoadRejectsBadKeys(t *testing.T) {
	cases := []struct {
		name    string
		set     map[string]string
		mention string
	}{
		{"short otp key", map[string]string{"OTP_KEY": b64(make([]byte, 16))}, "OTP_KEY"},
		{"otp key not base64", map[string]string{"OTP_KEY": "%%%"}, "OTP_KEY"},
		{"seed of the wrong size", map[string]string{"JWT_PRIVATE_KEY": b64(make([]byte, 31))}, "JWT_PRIVATE_KEY"},
		{"previous id without key", map[string]string{"JWT_PREVIOUS_KEY_ID": "old"}, "JWT_PREVIOUS_PUBLIC_KEY"},
		{"previous key without id", map[string]string{"JWT_PREVIOUS_PUBLIC_KEY": b64(make([]byte, 32))}, "JWT_PREVIOUS_KEY_ID"},
		{"previous id equals current", map[string]string{
			"JWT_PREVIOUS_KEY_ID": testKeys.JWTKeyID, "JWT_PREVIOUS_PUBLIC_KEY": b64(make([]byte, 32)),
		}, "must differ"},
		{"bad proxy", map[string]string{"TRUSTED_PROXIES": "10.0.0.0/8,nope"}, "TRUSTED_PROXIES"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			env := required()
			maps.Copy(env, c.set)
			if _, err := Load(lookup(env)); err == nil || !strings.Contains(err.Error(), c.mention) {
				t.Fatalf("err %v, want a mention of %q", err, c.mention)
			}
		})
	}
}

func TestNewAuthKeysRoundTrip(t *testing.T) {
	keys := NewAuthKeys()
	env := required()
	for line := range strings.Lines(keys.Env()) {
		k, v, _ := strings.Cut(strings.TrimSpace(line), "=")
		env[k] = v
	}
	got, err := Load(lookup(env))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got.Auth.OTPKey, keys.OTPKey) || !got.Auth.JWTKey.Equal(keys.JWTKey) || got.Auth.JWTKeyID != keys.JWTKeyID {
		t.Fatalf("got %+v", got.Auth)
	}
}
```

Run: `go test -short ./internal/platform/...`
Expected: build failures naming `WithDetail`, `Details`, `ClientIP`, `ErrUnauthenticated`, `NewAuthKeys`, `AuthConfig`, `TrustedProxies`.

- [ ] **Step 2: Implement**

`internal/platform/apperr/apperr.go`: add `Details map[string]any // values the client acts on: attempts_left, retry_after` after `Fields`, and:

```go
// WithDetail returns a copy of e with one more detail.
func (e *Error) WithDetail(name string, value any) *Error {
	c := *e
	c.Details = maps.Clone(e.Details)
	if c.Details == nil {
		c.Details = map[string]any{}
	}
	c.Details[name] = value
	return &c
}
```

`internal/platform/httpx/respond.go`: add ``Details map[string]any `json:"details,omitempty"` `` to `errorPayload` after `Fields`, and `Details: ae.Details` in the `apperr` branch of `WriteError`. `api/schemas/error.yaml`, under `error.properties` after `fields`:

```yaml
        details:
          type: object
          description: Values a client acts on, such as attempts_left or retry_after.
          additionalProperties: true
```

Create `internal/platform/httpx/clientip.go`:

```go
package httpx

import (
	"net/http"
	"net/netip"
	"strings"
)

// ClientIP returns the caller's address. A request from a trusted proxy is
// traced back through X-Forwarded-For from the right, and the first address
// that is not a trusted proxy is the client. Entries left of it are whatever
// the client sent and are ignored.
func ClientIP(r *http.Request, trusted []netip.Prefix) netip.Addr {
	remote, err := netip.ParseAddrPort(r.RemoteAddr)
	if err != nil {
		return netip.Addr{}
	}
	addr := remote.Addr().Unmap()
	if !isTrusted(addr, trusted) {
		return addr
	}
	hops := strings.Split(strings.Join(r.Header.Values("X-Forwarded-For"), ","), ",")
	for i := len(hops) - 1; i >= 0; i-- {
		hop, err := netip.ParseAddr(strings.TrimSpace(hops[i]))
		if err != nil {
			return addr
		}
		hop = hop.Unmap()
		if !isTrusted(hop, trusted) {
			return hop
		}
		addr = hop
	}
	return addr
}

func isTrusted(a netip.Addr, trusted []netip.Prefix) bool {
	for _, p := range trusted {
		if p.Contains(a) {
			return true
		}
	}
	return false
}
```

`internal/platform/authn/authn.go` (import `apperr`):

```go
// ErrUnauthenticated answers a request that needs a signed-in caller and has
// none.
var ErrUnauthenticated = apperr.New(apperr.KindUnauthenticated, "unauthenticated", "sign in first")
```

In `internal/account`, delete `ErrNoPrincipal` from `errors.go` and use `authn.ErrUnauthenticated` in `account_get.go` and `account_rename.go`.

`internal/platform/config/config.go`: add to `Config`:

```go
	TrustedProxies []netip.Prefix // TRUSTED_PROXIES: CIDRs whose X-Forwarded-For is believed
	Auth           AuthConfig
```

and the type:

```go
// AuthConfig holds the auth module's keys and token settings. No key is ever
// logged.
type AuthConfig struct {
	OTPKey       []byte             // OTP_KEY: base64, at least 32 bytes
	JWTKeyID     string             // JWT_KEY_ID: the kid of JWTKey
	JWTKey       ed25519.PrivateKey // JWT_PRIVATE_KEY: base64 of the 32-byte seed
	JWTPrevKeyID string             // JWT_PREVIOUS_KEY_ID: set during a key change
	JWTPrevKey   ed25519.PublicKey  // JWT_PREVIOUS_PUBLIC_KEY: base64
	Issuer       string             // JWT_ISSUER
	Audience     string             // JWT_AUDIENCE
}
```

In `Load`, after the `oneOf` helper add:

```go
	decodeKey := func(key string, size int, exact bool) []byte {
		v := getenv(key)
		if v == "" {
			errs = append(errs, fmt.Errorf("%s is required; run make keys", key))
			return nil
		}
		b, err := base64.StdEncoding.DecodeString(v)
		if err != nil || len(b) < size || (exact && len(b) != size) {
			want := fmt.Sprintf("at least %d", size)
			if exact {
				want = fmt.Sprint(size)
			}
			errs = append(errs, fmt.Errorf("%s: want base64 of %s bytes", key, want))
			return nil
		}
		return b
	}
```

add to the `cfg` literal:

```go
		Auth: AuthConfig{
			OTPKey:       decodeKey("OTP_KEY", 32, false),
			JWTKeyID:     need("JWT_KEY_ID"),
			JWTPrevKeyID: getenv("JWT_PREVIOUS_KEY_ID"),
			Issuer:       get("JWT_ISSUER", "server2"),
			Audience:     get("JWT_AUDIENCE", "shopnexus-app"),
		},
```

and before `return`:

```go
	for _, s := range strings.Split(getenv("TRUSTED_PROXIES"), ",") {
		if s = strings.TrimSpace(s); s == "" {
			continue
		}
		p, err := netip.ParsePrefix(s)
		if err != nil {
			errs = append(errs, fmt.Errorf("TRUSTED_PROXIES: %q is not a CIDR", s))
			continue
		}
		cfg.TrustedProxies = append(cfg.TrustedProxies, p.Masked())
	}

	if seed := decodeKey("JWT_PRIVATE_KEY", ed25519.SeedSize, true); seed != nil {
		cfg.Auth.JWTKey = ed25519.NewKeyFromSeed(seed)
	}
	prevKey := getenv("JWT_PREVIOUS_PUBLIC_KEY")
	switch {
	case prevKey == "" && cfg.Auth.JWTPrevKeyID == "":
	case prevKey == "" || cfg.Auth.JWTPrevKeyID == "":
		errs = append(errs, errors.New("JWT_PREVIOUS_KEY_ID and JWT_PREVIOUS_PUBLIC_KEY are set together or not at all"))
	case cfg.Auth.JWTPrevKeyID == cfg.Auth.JWTKeyID:
		errs = append(errs, errors.New("JWT_PREVIOUS_KEY_ID must differ from JWT_KEY_ID"))
	default:
		cfg.Auth.JWTPrevKey = decodeKey("JWT_PREVIOUS_PUBLIC_KEY", ed25519.PublicKeySize, true)
	}
```

Create `internal/platform/config/keys.go`:

```go
package config

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"fmt"
	"time"
)

// NewAuthKeys returns fresh random keys. `make keys` prints them for .env;
// tests use them directly.
func NewAuthKeys() AuthConfig {
	otpKey := make([]byte, 32)
	rand.Read(otpKey)
	_, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		panic(err) // crypto/rand does not fail on supported platforms
	}
	return AuthConfig{
		OTPKey:   otpKey,
		JWTKeyID: "k" + time.Now().UTC().Format("20060102150405"),
		JWTKey:   priv,
		Issuer:   "server2",
		Audience: "shopnexus-app",
	}
}

// Env renders the keys as .env lines that Load reads back.
func (a AuthConfig) Env() string {
	enc := base64.StdEncoding.EncodeToString
	return fmt.Sprintf("OTP_KEY=%s\nJWT_KEY_ID=%s\nJWT_PRIVATE_KEY=%s\n", enc(a.OTPKey), a.JWTKeyID, enc(a.JWTKey.Seed()))
}
```

Create `cmd/keygen/main.go`:

```go
// Command keygen prints fresh OTP and JWT keys as .env lines.
package main

import (
	"fmt"

	"github.com/shopnexus/server2/internal/platform/config"
)

func main() { fmt.Print(config.NewAuthKeys().Env()) }
```

`Makefile`: add `keys` to `.PHONY` and

```make
keys:
	@grep -q '^OTP_KEY=' .env 2>/dev/null && { echo ".env already has keys"; exit 1; } || go run ./cmd/keygen >> .env
```

`.env.example` appends `TRUSTED_PROXIES=`, `JWT_ISSUER=server2`, `JWT_AUDIENCE=shopnexus-app` and the comment `# OTP_KEY, JWT_KEY_ID and JWT_PRIVATE_KEY: run make keys to append fresh ones to .env`.

`internal/app/app.go`, at the top of `New`:

```go
	if len(cfg.Auth.JWTKey) != ed25519.PrivateKeySize || len(cfg.Auth.OTPKey) < 32 {
		return nil, errors.New("auth keys missing from config; run make keys")
	}
```

`internal/app/app_test.go`: `testConfig` sets `Auth: config.NewAuthKeys()`; add

```go
func TestNewRefusesMissingKeys(t *testing.T) {
	cfg := testConfig(t)
	cfg.Auth = config.AuthConfig{}
	if _, err := New(context.Background(), cfg, discard()); err == nil || !strings.Contains(err.Error(), "make keys") {
		t.Fatalf("err %v", err)
	}
}
```

`e2e/main_test.go` gains package variables `keys = config.NewAuthKeys()` (tests mint tokens with them) and `db *pgxpool.Pool` (setup a test cannot do over HTTP), sets `db = pool`, and adds `Auth: keys` and `TrustedProxies: []netip.Prefix{netip.MustParsePrefix("127.0.0.0/8"), netip.MustParsePrefix("::1/128")}` to its config, so each test sets its own `X-Forwarded-For`. `e2e/system_test.go` adds `Auth: keys` to `TestReadyzDown`'s config.

- [ ] **Step 3: Run and commit**

Run: `make lint && make test && make keys`
Expected: PASS; `make keys` appends three lines to `.env` (a second run prints `.env already has keys`).

```bash
git add -A
git commit -m "feat(platform): error details, client IP behind proxies, auth keys"
```

### Task 3: Account rewrite on squashed migrations

**Files:**
- Delete: `migrations/0001_accounts.sql`, `migrations/0002_outbox.sql`, `internal/account/account_rename_pg_test.go`, `internal/account/account_view.go`, `internal/account/helpers_test.go`
- Create: `migrations/0001_accounts.sql`, `migrations/0002_auth.sql`
- Rewrite: `internal/account/` (files below), `internal/account/accounttest/`

**Interfaces:**
- Produces: `account.New(id uuid.UUID, displayName string, now time.Time) (Account, error)`; `account.Restore(id uuid.UUID, displayName string, status Status, suspendedUntil *time.Time, suspendReason string, writeID uuid.UUID, createdAt, updatedAt time.Time) Account`; `(Account).WriteID() uuid.UUID`
- Produces: `account.Store{Create(ctx, Account) error; Get(ctx, uuid.UUID) (Account, error); Save(ctx, *Account, uuid.UUID) error; Delete(ctx, uuid.UUID) error}`, `account.NewPGStore(db *pgxpool.Pool) Store`, `account.ErrConflict` (409 `conflict`)
- Produces: `account.Create(ctx, Store, id uuid.UUID, displayName string, now time.Time) error`, `account.Delete(ctx, Store, id) error`, `account.StatusOf(ctx, Store, id, now) (Status, error)`, `account.Get(ctx, Store, id, now) (View, error)`, `account.Rename(ctx, Store, id uuid.UUID, name string, now time.Time) (View, error)`
- Produces: `account.View{ID; DisplayName; Status; CreatedAt}`, `account.GetHandler(Store, now func() time.Time, log) http.Handler`, `account.RenameHandler(Store, now func() time.Time, log) http.Handler`, `account.Routes(r *httpx.Router, accounts Store, now func() time.Time, log *slog.Logger, protect func(http.Handler) http.Handler)`
- Produces: `account.Client{Store Store; Now func() time.Time}` with `Create(ctx, id, displayName) error`, `Delete(ctx, id) error`, `Status(ctx, id) (Status, error)`
- Produces: `accounttest.NewMemStore() *MemStore`, `accounttest.RunStoreContract(t, newStore func(t *testing.T) account.Store)`

- [ ] **Step 1: Squash the migrations**

```bash
cd ~/shopnexus/server2
git rm -q migrations/0001_accounts.sql migrations/0002_outbox.sql
```

Create `migrations/0001_accounts.sql`:

```sql
-- Who a person is. How they sign in lives in the auth tables.
CREATE TABLE accounts (
    id              uuid PRIMARY KEY DEFAULT uuidv7(),
    display_name    text CHECK (char_length(display_name) BETWEEN 1 AND 50),
    status          text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended')),
    suspended_until timestamptz,
    suspend_reason  text,
    -- The ID of the last write. Save matches it to detect a concurrent
    -- change, and a retried Save with the same ID matches again.
    write_id        uuid NOT NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CHECK (status = 'suspended' OR (suspended_until IS NULL AND suspend_reason IS NULL))
);
```

Create `migrations/0002_auth.sql`:

```sql
-- How a person signs in. Foreign keys point at accounts and never the other
-- way. Every aggregate root carries write_id, the ID of its last write.

-- Aggregate root for an account's sign-in methods; password_hash arrives
-- with plan 3.
CREATE TABLE credentials (
    account_id    uuid PRIMARY KEY REFERENCES accounts,
    password_hash text,
    write_id      uuid NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- A verified phone, email or Google account, owned by one credentials row.
CREATE TABLE identities (
    id           uuid PRIMARY KEY,
    account_id   uuid NOT NULL REFERENCES credentials ON DELETE CASCADE,
    kind         text NOT NULL CHECK (kind IN ('phone', 'email', 'google')),
    value        text NOT NULL,
    last_used_at timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    UNIQUE (kind, value)
);
CREATE INDEX identities_account_id ON identities (account_id);

CREATE TABLE sessions (
    id                uuid PRIMARY KEY,
    account_id        uuid NOT NULL REFERENCES accounts,
    refresh_hash      bytea NOT NULL UNIQUE,
    prev_refresh_hash bytea,
    device_name       text CHECK (char_length(device_name) <= 100),
    -- When the person last proved who they are; refresh copies it into each
    -- access token.
    auth_time         timestamptz NOT NULL,
    created_at        timestamptz NOT NULL,
    last_used_at      timestamptz NOT NULL,
    expires_at        timestamptz NOT NULL,
    revoked_at        timestamptz,
    write_id          uuid NOT NULL
);
CREATE INDEX sessions_account_id ON sessions (account_id);
CREATE INDEX sessions_prev_refresh_hash ON sessions (prev_refresh_hash) WHERE prev_refresh_hash IS NOT NULL;

-- code_hash is HMAC-SHA256(OTP_KEY, ...); the key is not in the database.
CREATE TABLE otp_challenges (
    id          uuid PRIMARY KEY,
    purpose     text NOT NULL CHECK (purpose IN ('login', 'add_identity', 'reset_password')),
    kind        text NOT NULL CHECK (kind IN ('phone', 'email')),
    destination text NOT NULL,
    account_id  uuid REFERENCES accounts,
    code_hash   bytea NOT NULL,
    attempts    int NOT NULL DEFAULT 0,
    ip          inet NOT NULL,
    expires_at  timestamptz NOT NULL,
    created_at  timestamptz NOT NULL,
    consumed_at timestamptz,
    write_id    uuid NOT NULL
);
CREATE INDEX otp_challenges_destination ON otp_challenges (destination, purpose, created_at);

-- Sends inside the longest window, one row per "dest:..." or "ip:..." key.
CREATE TABLE otp_quotas (
    key      text PRIMARY KEY,
    sent_at  timestamptz[] NOT NULL,
    write_id uuid NOT NULL
);
```

Run: `make down && docker volume rm shopnexus-server2_postgres 2>/dev/null; make up && make migrate`
Expected: `0001_accounts.sql` and `0002_auth.sql` applied. The volume name comes from `docker volume ls`; check it before removing.

- [ ] **Step 2: Write the failing contract and use case tests**

Rewrite `internal/account/accounttest/contract.go`:

```go
// Package accounttest holds the in-memory account store and the contract
// suite every account.Store implementation must pass.
package accounttest

import (
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
)

// RunStoreContract checks that a store behaves as account.Store promises.
func RunStoreContract(t *testing.T, newStore func(t *testing.T) account.Store) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	fresh := func(t *testing.T, s account.Store) account.Account {
		t.Helper()
		a, err := account.New(uuid.NewV7(), "Linh", now)
		if err != nil {
			t.Fatal(err)
		}
		if err := s.Create(ctx, a); err != nil {
			t.Fatal(err)
		}
		return a
	}

	t.Run("create then get", func(t *testing.T) {
		s := newStore(t)
		a := fresh(t, s)
		got, err := s.Get(ctx, a.ID())
		if err != nil || got.ID() != a.ID() || got.DisplayName() != "Linh" || got.Status(now) != account.StatusActive ||
			got.WriteID() != a.WriteID() || !got.CreatedAt().Equal(now) {
			t.Fatalf("got %+v %v", got, err)
		}
	})

	t.Run("create twice keeps the first", func(t *testing.T) {
		s := newStore(t)
		a := fresh(t, s)
		again, _ := account.New(a.ID(), "Other", now)
		if err := s.Create(ctx, again); err != nil {
			t.Fatal(err)
		}
		if got, _ := s.Get(ctx, a.ID()); got.DisplayName() != "Linh" {
			t.Fatalf("name %q", got.DisplayName())
		}
	})

	t.Run("get unknown", func(t *testing.T) {
		if _, err := newStore(t).Get(ctx, uuid.NewV7()); !errors.Is(err, account.ErrNotFound) {
			t.Fatalf("err %v", err)
		}
	})

	t.Run("save sets the write id", func(t *testing.T) {
		s := newStore(t)
		a := fresh(t, s)
		a.SetDisplayName("Minh", now)
		w := uuid.NewV7()
		if err := s.Save(ctx, &a, w); err != nil || a.WriteID() != w {
			t.Fatalf("save: %v, write id %s", err, a.WriteID())
		}
		if got, _ := s.Get(ctx, a.ID()); got.DisplayName() != "Minh" || got.WriteID() != w {
			t.Fatalf("got %+v", got)
		}
	})

	t.Run("a stale write conflicts", func(t *testing.T) {
		s := newStore(t)
		a := fresh(t, s)
		b, _ := s.Get(ctx, a.ID())
		a.SetDisplayName("First", now)
		if err := s.Save(ctx, &a, uuid.NewV7()); err != nil {
			t.Fatal(err)
		}
		b.SetDisplayName("Second", now)
		if err := s.Save(ctx, &b, uuid.NewV7()); !errors.Is(err, account.ErrConflict) {
			t.Fatalf("stale save: %v", err)
		}
	})

	t.Run("a retried write with the same id succeeds", func(t *testing.T) {
		s := newStore(t)
		a := fresh(t, s)
		retry := a
		a.SetDisplayName("Minh", now)
		retry.SetDisplayName("Minh", now)
		w := uuid.NewV7()
		if err := s.Save(ctx, &a, w); err != nil {
			t.Fatal(err)
		}
		if err := s.Save(ctx, &retry, w); err != nil {
			t.Fatalf("retry: %v", err)
		}
	})

	t.Run("delete is idempotent", func(t *testing.T) {
		s := newStore(t)
		a := fresh(t, s)
		for range 2 {
			if err := s.Delete(ctx, a.ID()); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := s.Get(ctx, a.ID()); !errors.Is(err, account.ErrNotFound) {
			t.Fatalf("after delete: %v", err)
		}
	})
}
```

`internal/account/accounttest/memstore_test.go` runs `RunStoreContract(t, func(*testing.T) account.Store { return accounttest.NewMemStore() })`. `internal/account/account_store_pg_test.go` runs it with `account.NewPGStore(pgtest.New(t))`.

In `internal/account/account_test.go`, every `account.New(name, now)` becomes `account.New(uuid.NewV7(), name, now)`, and add:

```go
func TestNewStartsWithItsIDAsWriteID(t *testing.T) {
	id := uuid.NewV7()
	a, _ := account.New(id, "Linh", now)
	if a.ID() != id || a.WriteID() != id {
		t.Fatalf("%+v", a)
	}
}
```

Replace `account_create_test.go`, `account_status_test.go`, `account_get_test.go` and `account_rename_test.go` with `account_usecases_test.go`:

```go
package account_test

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/account/accounttest"
)

func seed(t *testing.T, s account.Store) uuid.UUID {
	t.Helper()
	id := uuid.NewV7()
	if err := account.Create(context.Background(), s, id, "Linh", now); err != nil {
		t.Fatal(err)
	}
	return id
}

func TestCreateIsIdempotent(t *testing.T) {
	s := accounttest.NewMemStore()
	id := seed(t, s)
	if err := account.Create(context.Background(), s, id, "Linh", now); err != nil {
		t.Fatal(err)
	}
	if v, err := account.Get(context.Background(), s, id, now); err != nil || v.DisplayName != "Linh" || v.Status != account.StatusActive {
		t.Fatalf("%+v %v", v, err)
	}
}

func TestCreateRejectsLongName(t *testing.T) {
	err := account.Create(context.Background(), accounttest.NewMemStore(), uuid.NewV7(), strings.Repeat("a", 51), now)
	if !errors.Is(err, account.ErrInvalidName) {
		t.Fatalf("err %v", err)
	}
}

func TestStatusFollowsTheClock(t *testing.T) {
	s := accounttest.NewMemStore()
	id := seed(t, s)
	a, _ := s.Get(context.Background(), id)
	until := now.Add(time.Hour)
	if err := a.Suspend("spam", &until, now); err != nil {
		t.Fatal(err)
	}
	if err := s.Save(context.Background(), &a, uuid.NewV7()); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		at   time.Time
		want account.Status
	}{{now, account.StatusSuspended}, {until.Add(time.Second), account.StatusActive}} {
		if st, err := account.StatusOf(context.Background(), s, id, c.at); err != nil || st != c.want {
			t.Fatalf("at %s: %s %v", c.at, st, err)
		}
	}
}

func TestRename(t *testing.T) {
	s := accounttest.NewMemStore()
	id := seed(t, s)
	if v, err := account.Rename(context.Background(), s, id, " Minh ", now); err != nil || v.DisplayName != "Minh" {
		t.Fatalf("%+v %v", v, err)
	}
}

func TestRenameRefusedWhileSuspended(t *testing.T) {
	s := accounttest.NewMemStore()
	id := seed(t, s)
	a, _ := s.Get(context.Background(), id)
	a.Suspend("spam", nil, now)
	s.Save(context.Background(), &a, uuid.NewV7())
	if _, err := account.Rename(context.Background(), s, id, "Minh", now); !errors.Is(err, account.ErrSuspended) {
		t.Fatalf("err %v", err)
	}
}

// conflicting is a store whose Save always loses a race.
type conflicting struct{ account.Store }

func (conflicting) Save(context.Context, *account.Account, uuid.UUID) error { return account.ErrConflict }

func TestRenameReportsAConflict(t *testing.T) {
	s := accounttest.NewMemStore()
	id := seed(t, s)
	if _, err := account.Rename(context.Background(), conflicting{s}, id, "Minh", now); !errors.Is(err, account.ErrConflict) {
		t.Fatalf("err %v", err)
	}
}

func TestClientDelegates(t *testing.T) {
	s := accounttest.NewMemStore()
	c := account.Client{Store: s, Now: func() time.Time { return now }}
	id := uuid.NewV7()
	if err := c.Create(context.Background(), id, ""); err != nil {
		t.Fatal(err)
	}
	if st, err := c.Status(context.Background(), id); err != nil || st != account.StatusActive {
		t.Fatalf("%s %v", st, err)
	}
	if err := c.Delete(context.Background(), id); err != nil {
		t.Fatal(err)
	}
	if _, err := c.Status(context.Background(), id); !errors.Is(err, account.ErrNotFound) {
		t.Fatalf("after delete: %v", err)
	}
}
```

Run: `go test ./internal/account/...`
Expected: build failures (new `New` signature, `WriteID`, `Save` with a write ID, `Delete`, the functions).

- [ ] **Step 3: Implement**

`internal/account/account.go`: add the field `writeID uuid.UUID`, the accessor `func (a Account) WriteID() uuid.UUID { return a.writeID }`, change `New` to take the ID and start with it as the write ID, and add `writeID` to `Restore`:

```go
// New builds an active account with the caller's id. Its first write ID is
// its id.
func New(id uuid.UUID, displayName string, now time.Time) (Account, error) {
	name, err := cleanName(displayName, true)
	if err != nil {
		return Account{}, err
	}
	return Account{id: id, displayName: name, status: StatusActive, writeID: id, createdAt: now, updatedAt: now}, nil
}

// Restore rebuilds a stored account. Stores only.
func Restore(id uuid.UUID, displayName string, status Status, suspendedUntil *time.Time, suspendReason string,
	writeID uuid.UUID, createdAt, updatedAt time.Time) Account {
	return Account{id: id, displayName: displayName, status: status, suspendedUntil: suspendedUntil,
		suspendReason: suspendReason, writeID: writeID, createdAt: createdAt, updatedAt: updatedAt}
}
```

`internal/account/errors.go` adds:

```go
	ErrConflict = apperr.New(apperr.KindConflict, "conflict", "the account changed meanwhile; try again")
```

Rewrite `internal/account/account_store.go`:

```go
package account

import (
	"context"
	"uuid"
)

// Store persists accounts. Each method is its own transaction.
type Store interface {
	// Create inserts a; inserting the same id again does nothing, so a retried
	// step is safe.
	Create(ctx context.Context, a Account) error
	// Get returns ErrNotFound for an unknown id.
	Get(ctx context.Context, id uuid.UUID) (Account, error)
	// Save writes a when its row still has a.WriteID() or already has
	// writeID, then sets a's write ID to writeID. Otherwise ErrConflict.
	Save(ctx context.Context, a *Account, writeID uuid.UUID) error
	// Delete removes the account; deleting a missing one does nothing. Only
	// the sign-up compensation calls it.
	Delete(ctx context.Context, id uuid.UUID) error
}
```

Rewrite `internal/account/account_store_pg.go`:

```go
package account

import (
	"context"
	"errors"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type pgStore struct{ db *pgxpool.Pool }

// NewPGStore returns the Postgres Store.
func NewPGStore(db *pgxpool.Pool) Store { return pgStore{db} }

const createAccount = `
INSERT INTO accounts (id, display_name, status, write_id, created_at, updated_at)
VALUES ($1, NULLIF($2, ''), $3, $4, $5, $5)
ON CONFLICT (id) DO NOTHING`

func (s pgStore) Create(ctx context.Context, a Account) error {
	_, err := s.db.Exec(ctx, createAccount, a.id, a.displayName, a.status, a.writeID, a.createdAt)
	return err
}

const getAccount = `
SELECT id, coalesce(display_name, ''), status, suspended_until, coalesce(suspend_reason, ''), write_id, created_at, updated_at
FROM accounts WHERE id = $1`

func (s pgStore) Get(ctx context.Context, id uuid.UUID) (Account, error) {
	var a Account
	err := s.db.QueryRow(ctx, getAccount, id).Scan(&a.id, &a.displayName, &a.status, &a.suspendedUntil,
		&a.suspendReason, &a.writeID, &a.createdAt, &a.updatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Account{}, ErrNotFound
	}
	return a, err
}

const saveAccount = `
UPDATE accounts
SET display_name = NULLIF($3, ''), status = $4, suspended_until = $5, suspend_reason = NULLIF($6, ''),
    updated_at = $7, write_id = $8
WHERE id = $1 AND (write_id = $2 OR write_id = $8)`

func (s pgStore) Save(ctx context.Context, a *Account, writeID uuid.UUID) error {
	tag, err := s.db.Exec(ctx, saveAccount, a.id, a.writeID, a.displayName, a.status, a.suspendedUntil,
		a.suspendReason, a.updatedAt, writeID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	a.writeID = writeID
	return nil
}

func (s pgStore) Delete(ctx context.Context, id uuid.UUID) error {
	_, err := s.db.Exec(ctx, `DELETE FROM accounts WHERE id = $1`, id)
	return err
}
```

Rewrite `internal/account/accounttest/memstore.go`:

```go
package accounttest

import (
	"context"
	"sync"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
)

// MemStore is an in-memory account.Store for use case tests.
type MemStore struct {
	mu   sync.Mutex
	rows map[uuid.UUID]account.Account
}

func NewMemStore() *MemStore { return &MemStore{rows: map[uuid.UUID]account.Account{}} }

func us(t time.Time) time.Time { return t.Truncate(time.Microsecond) }

func withWriteID(a account.Account, w uuid.UUID) account.Account {
	return account.Restore(a.ID(), a.DisplayName(), a.Status(time.Time{}), a.SuspendedUntil(), a.SuspendReason(), w,
		us(a.CreatedAt()), us(a.UpdatedAt()))
}

func (s *MemStore) Create(_ context.Context, a account.Account) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.rows[a.ID()]; !ok {
		s.rows[a.ID()] = withWriteID(a, a.WriteID())
	}
	return nil
}

func (s *MemStore) Get(_ context.Context, id uuid.UUID) (account.Account, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	a, ok := s.rows[id]
	if !ok {
		return account.Account{}, account.ErrNotFound
	}
	return a, nil
}

func (s *MemStore) Save(_ context.Context, a *account.Account, writeID uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur, ok := s.rows[a.ID()]
	if !ok || (cur.WriteID() != a.WriteID() && cur.WriteID() != writeID) {
		return account.ErrConflict
	}
	*a = withWriteID(*a, writeID)
	s.rows[a.ID()] = *a
	return nil
}

func (s *MemStore) Delete(_ context.Context, id uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	delete(s.rows, id)
	return nil
}
```

`Status(time.Time{})` in `withWriteID` reads the stored status: `Status(now)` only lapses a suspension whose end has passed, and the zero time is before every end. Check that against `account.go`; if `Status` behaves otherwise, add a `StoredStatus()` accessor and use it here and in `account_store_pg.go`.

Delete `account_create.go`, `account_status.go`, `account_get.go`, `account_rename.go`, `account_view.go`, `routes.go` and write the functions:

`internal/account/account_create.go`:

```go
package account

import (
	"context"
	"time"
	"uuid"
)

// Create inserts an active account with the caller's id. Creating the same
// id twice does nothing, so a retried Restate step is safe.
func Create(ctx context.Context, accounts Store, id uuid.UUID, displayName string, now time.Time) error {
	a, err := New(id, displayName, now)
	if err != nil {
		return err
	}
	return accounts.Create(ctx, a)
}

// Delete removes an account. The sign-up compensation is its only caller.
func Delete(ctx context.Context, accounts Store, id uuid.UUID) error { return accounts.Delete(ctx, id) }

// StatusOf returns the status in force at now.
func StatusOf(ctx context.Context, accounts Store, id uuid.UUID, now time.Time) (Status, error) {
	a, err := accounts.Get(ctx, id)
	if err != nil {
		return "", err
	}
	return a.Status(now), nil
}
```

`internal/account/account_get.go`:

```go
package account

import (
	"context"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/httpx"
)

// View is the Account schema in api/schemas/account.yaml.
type View struct {
	ID          uuid.UUID `json:"id"`
	DisplayName string    `json:"display_name"`
	Status      Status    `json:"status"`
	CreatedAt   time.Time `json:"created_at"`
}

func viewOf(a Account, now time.Time) View {
	return View{ID: a.ID(), DisplayName: a.DisplayName(), Status: a.Status(now), CreatedAt: a.CreatedAt()}
}

// Get reads an account.
func Get(ctx context.Context, accounts Store, id uuid.UUID, now time.Time) (View, error) {
	a, err := accounts.Get(ctx, id)
	if err != nil {
		return View{}, err
	}
	return viewOf(a, now), nil
}

// GET /v1/accounts/me
func GetHandler(accounts Store, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, ok := authn.From(r.Context())
		if !ok {
			httpx.WriteError(w, r, log, authn.ErrUnauthenticated)
			return
		}
		v, err := Get(r.Context(), accounts, p.AccountID, now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, r, http.StatusOK, v)
	})
}
```

`internal/account/account_rename.go`:

```go
package account

import (
	"context"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/httpx"
)

// Rename sets the display name. It is a write, so a suspended account gets
// ErrSuspended even while its access token is still valid.
func Rename(ctx context.Context, accounts Store, id uuid.UUID, name string, now time.Time) (View, error) {
	a, err := accounts.Get(ctx, id)
	if err != nil {
		return View{}, err
	}
	if err := a.CanWrite(now); err != nil {
		return View{}, err
	}
	if err := a.SetDisplayName(name, now); err != nil {
		return View{}, err
	}
	if err := accounts.Save(ctx, &a, uuid.NewV7()); err != nil {
		return View{}, err
	}
	return viewOf(a, now), nil
}

type RenameRequest struct {
	DisplayName string `json:"display_name"`
}

// PATCH /v1/accounts/me
func RenameHandler(accounts Store, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, ok := authn.From(r.Context())
		if !ok {
			httpx.WriteError(w, r, log, authn.ErrUnauthenticated)
			return
		}
		in, err := httpx.Decode[RenameRequest](r)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		v, err := Rename(r.Context(), accounts, p.AccountID, in.DisplayName, now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, r, http.StatusOK, v)
	})
}
```

`internal/account/client.go`:

```go
package account

import (
	"context"
	"time"
	"uuid"
)

// Client implements the ports other modules declare for accounts.
type Client struct {
	Store Store
	Now   func() time.Time
}

func (c Client) Create(ctx context.Context, id uuid.UUID, displayName string) error {
	return Create(ctx, c.Store, id, displayName, c.Now())
}

func (c Client) Delete(ctx context.Context, id uuid.UUID) error { return Delete(ctx, c.Store, id) }

func (c Client) Status(ctx context.Context, id uuid.UUID) (Status, error) {
	return StatusOf(ctx, c.Store, id, c.Now())
}
```

`internal/account/routes.go`:

```go
package account

import (
	"log/slog"
	"net/http"
	"time"

	"github.com/shopnexus/server2/internal/platform/httpx"
)

// Routes registers the account endpoints behind protect, which requires a
// signed-in caller.
func Routes(r *httpx.Router, accounts Store, now func() time.Time, log *slog.Logger, protect func(http.Handler) http.Handler) {
	r.Handle("GET /v1/accounts/me", protect(GetHandler(accounts, now, log)))
	r.Handle("PATCH /v1/accounts/me", protect(RenameHandler(accounts, now, log)))
}
```

Task 10 registers these routes, once the OpenAPI operations and the middleware exist.

- [ ] **Step 4: Run and commit**

Run: `make lint && make test`
Expected: PASS, the account contract green on the fake and on Postgres.

```bash
git add -A
git commit -m "refactor(account): functions with ports, write_id, squashed migrations"
```

### Task 4: `platform/contact`

**Files:**
- Create: `internal/platform/contact/contact.go`, `contact_test.go`

**Interfaces:**
- Produces: `contact.Kind` (`contact.Phone`, `contact.Email`), `contact.Address` with `Kind()`, `Value()`, `Masked()`, `IsZero()`, `String()` (masked), `LogValue()`
- Produces: `contact.ParsePhone`, `contact.ParseEmail`, `contact.Parse(kind, raw) (Address, error)`, `contact.Restore(kind, value) Address`, `contact.ErrInvalidPhone` (422 `invalid_phone`), `contact.ErrInvalidEmail` (422 `invalid_email`)

- [ ] **Step 1: Write the failing test**

Create `internal/platform/contact/contact_test.go`:

```go
package contact_test

import (
	"bytes"
	"errors"
	"log/slog"
	"strings"
	"testing"

	"github.com/shopnexus/server2/internal/platform/contact"
)

func TestParsePhone(t *testing.T) {
	for _, in := range []string{
		"0901234567", "+84901234567", "84901234567", "+84 90 123 4567", "090.123.4567", "090-123-4567", " 0901234567 ",
	} {
		a, err := contact.ParsePhone(in)
		if err != nil || a.Value() != "+84901234567" || a.Kind() != contact.Phone {
			t.Errorf("%q → %q %v", in, a.Value(), err)
		}
	}
}

func TestParsePhoneRejects(t *testing.T) {
	for _, in := range []string{"", "0201234567", "090123456", "09012345678", "+14155550100", "+84901234567x", "+84 1234", "phone"} {
		if _, err := contact.ParsePhone(in); !errors.Is(err, contact.ErrInvalidPhone) {
			t.Errorf("%q: %v", in, err)
		}
	}
}

func TestParseEmail(t *testing.T) {
	if a, err := contact.ParseEmail("  Linh.Nguyen@Gmail.COM "); err != nil || a.Value() != "linh.nguyen@gmail.com" || a.Kind() != contact.Email {
		t.Fatalf("%q %v", a.Value(), err)
	}
	for _, in := range []string{
		"", "linh", "linh@", "@gmail.com", "Linh <linh@gmail.com>", "linh@gmail", "linh@@gmail.com", "linh@.com",
		strings.Repeat("a", 250) + "@x.com",
	} {
		if _, err := contact.ParseEmail(in); !errors.Is(err, contact.ErrInvalidEmail) {
			t.Errorf("%q: %v", in, err)
		}
	}
}

func TestParseByKind(t *testing.T) {
	if a, err := contact.Parse(contact.Email, "A@B.co"); err != nil || a.Value() != "a@b.co" {
		t.Fatalf("%q %v", a.Value(), err)
	}
	if _, err := contact.Parse("fax", "1"); err == nil {
		t.Fatal("unknown kind accepted")
	}
}

func TestMaskingAndLogs(t *testing.T) {
	phone, _ := contact.ParsePhone("0901234567")
	email, _ := contact.ParseEmail("linh@gmail.com")
	if phone.Masked() != "+8490****567" || email.Masked() != "l***@gmail.com" {
		t.Fatalf("%q %q", phone.Masked(), email.Masked())
	}
	var buf bytes.Buffer
	slog.New(slog.NewTextHandler(&buf, nil)).Info("x", "to", phone)
	if strings.Contains(buf.String(), "1234567") || !strings.Contains(buf.String(), "+8490****567") {
		t.Fatalf("log %q", buf.String())
	}
	var zero contact.Address
	if !zero.IsZero() || phone.IsZero() {
		t.Fatal("IsZero")
	}
}
```

Run: `go test -short ./internal/platform/contact/`
Expected: FAIL, package `contact` has no non-test files.

- [ ] **Step 2: Implement**

Create `internal/platform/contact/contact.go`:

```go
// Package contact normalises phone numbers and email addresses. Identity and
// OTP rows store the normalised form, so UNIQUE (kind, value) sees one value
// per number however a person typed it.
package contact

import (
	"fmt"
	"log/slog"
	"net/mail"
	"regexp"
	"strings"

	"github.com/shopnexus/server2/internal/platform/apperr"
)

type Kind string

const (
	Phone Kind = "phone"
	Email Kind = "email"
)

var (
	ErrInvalidPhone = apperr.New(apperr.KindInvalid, "invalid_phone", "phone must be a Vietnamese mobile number")
	ErrInvalidEmail = apperr.New(apperr.KindInvalid, "invalid_email", "email address is not valid")
)

// Address is a normalised phone number or email address. Only the Parse
// functions and Restore build one.
type Address struct {
	kind  Kind
	value string
}

// vnMobile is +84, a mobile prefix (3, 5, 7, 8, 9) and eight digits. Other
// countries arrive in a later phase.
var vnMobile = regexp.MustCompile(`^\+84[35789][0-9]{8}$`)

// ParsePhone accepts 0901234567, 84901234567 and +84 90 123 4567, ignoring
// spaces, dots and dashes, and returns +84901234567.
func ParsePhone(raw string) (Address, error) {
	s := strings.Map(func(r rune) rune {
		if r == ' ' || r == '.' || r == '-' {
			return -1
		}
		return r
	}, strings.TrimSpace(raw))
	switch {
	case strings.HasPrefix(s, "+"):
	case strings.HasPrefix(s, "84") && len(s) == 11:
		s = "+" + s
	case strings.HasPrefix(s, "0") && len(s) == 10:
		s = "+84" + s[1:]
	}
	if !vnMobile.MatchString(s) {
		return Address{}, ErrInvalidPhone
	}
	return Address{Phone, s}, nil
}

// ParseEmail lower-cases the address and rejects display names and domains
// without a dot.
func ParseEmail(raw string) (Address, error) {
	s := strings.ToLower(strings.TrimSpace(raw))
	a, err := mail.ParseAddress(s)
	if err != nil || a.Name != "" || a.Address != s || len(s) > 254 {
		return Address{}, ErrInvalidEmail
	}
	local, domain, _ := strings.Cut(s, "@")
	if local == "" || !strings.Contains(domain, ".") || strings.HasPrefix(domain, ".") || strings.HasSuffix(domain, ".") {
		return Address{}, ErrInvalidEmail
	}
	return Address{Email, s}, nil
}

// Parse dispatches on kind.
func Parse(kind Kind, raw string) (Address, error) {
	switch kind {
	case Phone:
		return ParsePhone(raw)
	case Email:
		return ParseEmail(raw)
	}
	return Address{}, fmt.Errorf("contact: unknown kind %q", kind)
}

// Restore rebuilds an address that was parsed before it was stored or sent.
func Restore(kind Kind, value string) Address { return Address{kind, value} }

func (a Address) Kind() Kind     { return a.kind }
func (a Address) Value() string  { return a.value }
func (a Address) IsZero() bool   { return a.value == "" }
func (a Address) String() string { return a.Masked() }

// Masked shows enough for a person to recognise their own address:
// +8490****567, l***@gmail.com.
func (a Address) Masked() string {
	switch a.kind {
	case Phone:
		return a.value[:5] + "****" + a.value[len(a.value)-3:]
	case Email:
		local, domain, _ := strings.Cut(a.value, "@")
		return local[:1] + "***@" + domain
	}
	return ""
}

// LogValue keeps full addresses out of logs.
func (a Address) LogValue() slog.Value { return slog.StringValue(a.Masked()) }
```

- [ ] **Step 3: Run and commit**

Run: `go test -short ./internal/platform/contact/ && make lint`
Expected: PASS.

```bash
git add internal/platform/contact
git commit -m "feat(contact): normalise Vietnamese mobiles and email addresses"
```

### Task 5: `auth/otp`

**Files:**
- Create: `internal/auth/otp/challenge.go`, `codes.go`, `quota.go`, `challenge_store.go`, `challenge_store_pg.go`, `quota_store.go`, `quota_store_pg.go`
- Create: `internal/auth/otp/challenge_test.go`, `codes_test.go`, `exercise_test.go`, `quota_test.go`, `stores_pg_test.go`
- Create: `internal/auth/otp/otptest/challenges.go`, `quotas.go`, `contract.go`, `memstore_test.go`

**Interfaces:**
- Produces: `otp.Purpose`, `otp.PurposeLogin`, `otp.CodeTTL` (5 min), `otp.MaxAttempts` (5)
- Produces: `otp.Challenge` with `ID()`, `Purpose()`, `Destination() contact.Address`, `AccountID() *uuid.UUID`, `CodeHash()`, `Attempts()`, `IP() netip.Addr`, `ExpiresAt()`, `CreatedAt()`, `ConsumedAt() *time.Time`, `WriteID()`, `(*Challenge).Verify(codeHash []byte, now time.Time) error`; `otp.New(id uuid.UUID, purpose Purpose, dest contact.Address, ip netip.Addr, codeHash []byte, now time.Time) Challenge`; `otp.Restore(...)`
- Produces: `otp.ErrNotFound`, `otp.ErrConflict` (plain), `otp.ErrInvalidCode` (422 `invalid_code`, detail `attempts_left`), `otp.ErrCodeExpired` (422 `code_expired`), `otp.ErrCodeLocked` (422 `code_locked`)
- Produces: `otp.NewCodes(key []byte) Codes`, `(Codes).For(challengeID uuid.UUID) string`, `(Codes).Hash(dest contact.Address, code string) []byte`
- Produces: `otp.Rule{Window time.Duration; Max int}`, `otp.Quota` with `Key()`, `SentAt()`, `WriteID()`, `(*Quota).Admit(now time.Time, rules ...Rule) (Rule, time.Duration, bool)`; `otp.NewQuota(key string) Quota`; `otp.RestoreQuota(key string, sentAt []time.Time, writeID uuid.UUID) Quota`
- Produces: `otp.ChallengeStore{Create(ctx, Challenge) error; Get(ctx, uuid.UUID) (Challenge, error); Save(ctx, *Challenge, uuid.UUID) error; IsNewest(ctx, Challenge) (bool, error)}`, `otp.NewChallengePGStore(*pgxpool.Pool)`
- Produces: `otp.QuotaStore{Get(ctx, key string) (Quota, error); Save(ctx, *Quota, uuid.UUID) error}`, `otp.NewQuotaPGStore(*pgxpool.Pool)`
- Produces: `otptest.NewChallenges() *Challenges`, `otptest.NewQuotas() *Quotas`, `otptest.RunChallengeContract(t, func(*testing.T) otp.ChallengeStore)`, `otptest.RunQuotaContract(t, func(*testing.T) otp.QuotaStore)`

- [ ] **Step 1: Write the failing entity, code, quota and exercise tests**

Create `internal/auth/otp/challenge_test.go`:

```go
package otp_test

import (
	"errors"
	"net/netip"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/contact"
)

var now = time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)

func challenge(t *testing.T) otp.Challenge {
	t.Helper()
	phone, _ := contact.ParsePhone("0901234567")
	return otp.New(uuid.NewV7(), otp.PurposeLogin, phone, netip.MustParseAddr("203.0.113.7"), []byte("right"), now)
}

func TestNewChallenge(t *testing.T) {
	c := challenge(t)
	if !c.ExpiresAt().Equal(now.Add(otp.CodeTTL)) || c.Attempts() != 0 || c.ConsumedAt() != nil || c.WriteID() != c.ID() {
		t.Fatalf("%+v", c)
	}
}

func TestVerifyRightCodeConsumes(t *testing.T) {
	c := challenge(t)
	if err := c.Verify([]byte("right"), now.Add(time.Minute)); err != nil || c.ConsumedAt() == nil {
		t.Fatalf("%v %v", err, c.ConsumedAt())
	}
	if err := c.Verify([]byte("right"), now.Add(time.Minute)); !errors.Is(err, otp.ErrCodeExpired) {
		t.Fatalf("second use: %v", err)
	}
}

func TestVerifyWrongCodeCountsAndLocks(t *testing.T) {
	c := challenge(t)
	err := c.Verify([]byte("wrong"), now)
	var ae *apperr.Error
	if !errors.Is(err, otp.ErrInvalidCode) || !errors.As(err, &ae) || ae.Details["attempts_left"] != otp.MaxAttempts-1 {
		t.Fatalf("err %v", err)
	}
	for i := 2; i < otp.MaxAttempts; i++ {
		c.Verify([]byte("wrong"), now)
	}
	if err := c.Verify([]byte("wrong"), now); !errors.Is(err, otp.ErrCodeLocked) {
		t.Fatalf("last attempt: %v", err)
	}
	if err := c.Verify([]byte("right"), now); !errors.Is(err, otp.ErrCodeLocked) || c.Attempts() != otp.MaxAttempts {
		t.Fatalf("right code after lock: %v, attempts %d", err, c.Attempts())
	}
}

func TestVerifyExpired(t *testing.T) {
	c := challenge(t)
	if err := c.Verify([]byte("wrong"), now.Add(otp.CodeTTL)); !errors.Is(err, otp.ErrCodeExpired) || c.Attempts() != 0 {
		t.Fatalf("%v, attempts %d", err, c.Attempts())
	}
}
```

Create `internal/auth/otp/codes_test.go`:

```go
package otp_test

import (
	"bytes"
	"regexp"
	"testing"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/contact"
)

var key1, key2 = []byte("key-one-key-one-key-one-key-one!"), []byte("key-two-key-two-key-two-key-two!")

func TestCodeIsDerivedFromTheChallenge(t *testing.T) {
	six := regexp.MustCompile(`^[0-9]{6}$`)
	codes := otp.NewCodes(key1)
	id := uuid.NewV7()
	if c := codes.For(id); !six.MatchString(c) || c != codes.For(id) {
		t.Fatalf("code %q is not a stable six-digit code", c)
	}
	same := 0
	for range 100 {
		x := uuid.NewV7()
		if otp.NewCodes(key2).For(x) == codes.For(x) {
			same++
		}
	}
	if same > 2 {
		t.Fatalf("%d of 100 codes equal under two keys", same)
	}
	seen := map[string]bool{}
	for range 1000 {
		seen[codes.For(uuid.NewV7())] = true
	}
	if len(seen) < 990 {
		t.Fatalf("only %d distinct codes in 1000", len(seen))
	}
}

func TestHashBindsKeyAndDestination(t *testing.T) {
	a, _ := contact.ParsePhone("0901234567")
	b, _ := contact.ParsePhone("0907654321")
	h1, h2 := otp.NewCodes(key1), otp.NewCodes(key2)
	if !bytes.Equal(h1.Hash(a, "123456"), h1.Hash(a, "123456")) ||
		bytes.Equal(h1.Hash(a, "123456"), h2.Hash(a, "123456")) ||
		bytes.Equal(h1.Hash(a, "123456"), h1.Hash(b, "123456")) ||
		bytes.Equal(h1.Hash(a, "123456"), h1.Hash(a, "123457")) {
		t.Fatal("hash must be stable and depend on key, destination and code")
	}
}
```

Create `internal/auth/otp/exercise_test.go`:

```go
package otp_test

import (
	"crypto/sha256"
	"fmt"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/contact"
)

// TestSHA256CodesFallToATable is the spec's reason for HMAC: a dump of plain
// SHA-256 code hashes is reversed by hashing all 10^6 codes. The log line
// shows how long that took. The same table finds nothing in HMAC hashes,
// whose key is not in the dump.
func TestSHA256CodesFallToATable(t *testing.T) {
	dest, _ := contact.ParsePhone("0901234567")
	codes := otp.NewCodes([]byte("a-key-that-is-not-in-the-database"))
	plain, keyed := map[[32]byte]bool{}, map[[32]byte]bool{}
	for range 1000 {
		code := codes.For(uuid.NewV7())
		plain[sha256.Sum256([]byte(code))] = true
		keyed[[32]byte(codes.Hash(dest, code))] = true
	}
	start := time.Now()
	crackedPlain, crackedKeyed := 0, 0
	for n := range 1_000_000 {
		h := sha256.Sum256(fmt.Appendf(nil, "%06d", n))
		if plain[h] {
			crackedPlain++
		}
		if keyed[h] {
			crackedKeyed++
		}
	}
	t.Logf("hashed every 6-digit code in %s: %d of %d SHA-256 hashes reversed, %d of %d HMAC hashes",
		time.Since(start), crackedPlain, len(plain), crackedKeyed, len(keyed))
	if crackedPlain != len(plain) || crackedKeyed != 0 {
		t.Fatal("the table should reverse every SHA-256 hash and no HMAC hash")
	}
}
```

Create `internal/auth/otp/quota_test.go`:

```go
package otp_test

import (
	"testing"
	"time"

	"github.com/shopnexus/server2/internal/auth/otp"
)

var destRules = []otp.Rule{{Window: 45 * time.Second, Max: 1}, {Window: time.Hour, Max: 5}}

func TestQuotaSpacing(t *testing.T) {
	q := otp.NewQuota("dest:+84901234567")
	if _, _, ok := q.Admit(now, destRules...); !ok {
		t.Fatal("first send refused")
	}
	rule, wait, ok := q.Admit(now.Add(44*time.Second), destRules...)
	if ok || rule.Window != 45*time.Second || wait != time.Second {
		t.Fatalf("at 44 s: %v %v %v", rule, wait, ok)
	}
	if _, _, ok := q.Admit(now.Add(45*time.Second), destRules...); !ok {
		t.Fatal("at 45 s refused")
	}
}

func TestQuotaHourlyCap(t *testing.T) {
	q := otp.NewQuota("dest:+84901234567")
	at := now
	for i := range 5 {
		if _, _, ok := q.Admit(at, destRules...); !ok {
			t.Fatalf("send %d refused", i+1)
		}
		at = at.Add(45 * time.Second)
	}
	if rule, _, ok := q.Admit(at, destRules...); ok || rule.Window != time.Hour {
		t.Fatalf("sixth send: %v %v", rule, ok)
	}
	if _, _, ok := q.Admit(now.Add(time.Hour+time.Second), destRules...); !ok {
		t.Fatal("an hour after the first send refused")
	}
	if len(q.SentAt()) > 5 {
		t.Fatalf("sends older than the longest window kept: %d", len(q.SentAt()))
	}
}
```

Run: `go test -short ./internal/auth/otp/`
Expected: FAIL, package `otp` has no non-test files.

- [ ] **Step 2: Implement the entities**

Create `internal/auth/otp/challenge.go`:

```go
// Package otp holds one-time code challenges, the derivation of their codes,
// and the send quotas. It sends nothing; the auth use cases do.
package otp

import (
	"crypto/hmac"
	"errors"
	"net/netip"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/contact"
)

type Purpose string

// PurposeLogin signs a person in and creates the account on first use. Plan 3
// adds add_identity and reset_password.
const PurposeLogin Purpose = "login"

const (
	CodeTTL     = 5 * time.Minute
	MaxAttempts = 5
)

var (
	ErrNotFound    = errors.New("otp: not found")
	ErrConflict    = errors.New("otp: changed meanwhile")
	ErrInvalidCode = apperr.New(apperr.KindInvalid, "invalid_code", "the code does not match")
	ErrCodeExpired = apperr.New(apperr.KindInvalid, "code_expired", "the code has expired or was replaced; request a new one")
	ErrCodeLocked  = apperr.New(apperr.KindInvalid, "code_locked", "too many wrong codes; request a new one")
)

// Challenge is one code sent to one destination.
type Challenge struct {
	id         uuid.UUID
	purpose    Purpose
	dest       contact.Address
	accountID  *uuid.UUID
	codeHash   []byte
	attempts   int
	ip         netip.Addr
	expiresAt  time.Time
	createdAt  time.Time
	consumedAt *time.Time
	writeID    uuid.UUID
}

// New starts a challenge that expires CodeTTL after now. Its first write ID is
// its id.
func New(id uuid.UUID, purpose Purpose, dest contact.Address, ip netip.Addr, codeHash []byte, now time.Time) Challenge {
	return Challenge{id: id, purpose: purpose, dest: dest, ip: ip, codeHash: codeHash,
		createdAt: now, expiresAt: now.Add(CodeTTL), writeID: id}
}

// Restore rebuilds a stored challenge. Stores only.
func Restore(id uuid.UUID, purpose Purpose, dest contact.Address, accountID *uuid.UUID, codeHash []byte, attempts int,
	ip netip.Addr, expiresAt, createdAt time.Time, consumedAt *time.Time, writeID uuid.UUID) Challenge {
	return Challenge{id, purpose, dest, accountID, codeHash, attempts, ip, expiresAt, createdAt, consumedAt, writeID}
}

func (c Challenge) ID() uuid.UUID                { return c.id }
func (c Challenge) Purpose() Purpose             { return c.purpose }
func (c Challenge) Destination() contact.Address { return c.dest }
func (c Challenge) AccountID() *uuid.UUID        { return c.accountID }
func (c Challenge) CodeHash() []byte             { return c.codeHash }
func (c Challenge) Attempts() int                { return c.attempts }
func (c Challenge) IP() netip.Addr               { return c.ip }
func (c Challenge) ExpiresAt() time.Time         { return c.expiresAt }
func (c Challenge) CreatedAt() time.Time         { return c.createdAt }
func (c Challenge) ConsumedAt() *time.Time       { return c.consumedAt }
func (c Challenge) WriteID() uuid.UUID           { return c.writeID }

// Verify checks codeHash at now. A wrong code counts an attempt, so the
// caller saves the challenge whether Verify passes or not.
func (c *Challenge) Verify(codeHash []byte, now time.Time) error {
	switch {
	case c.consumedAt != nil, !now.Before(c.expiresAt):
		return ErrCodeExpired
	case c.attempts >= MaxAttempts:
		return ErrCodeLocked
	}
	if !hmac.Equal(codeHash, c.codeHash) {
		c.attempts++
		if c.attempts >= MaxAttempts {
			return ErrCodeLocked
		}
		return ErrInvalidCode.WithDetail("attempts_left", MaxAttempts-c.attempts)
	}
	c.consumedAt = &now
	return nil
}
```

Create `internal/auth/otp/codes.go`:

```go
package otp

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/binary"
	"fmt"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/contact"
)

// Codes derives and hashes OTP codes with OTP_KEY. A code is derived from its
// challenge ID, so a retried send step produces the same code and the code
// is never stored or written to Restate's journal.
type Codes struct{ key []byte }

func NewCodes(key []byte) Codes { return Codes{key: key} }

// For returns the six-digit code of a challenge. Taking 64 bits modulo 10^6
// leaves a bias of under 10^-13.
func (c Codes) For(challengeID uuid.UUID) string {
	m := hmac.New(sha256.New, c.key)
	m.Write([]byte("otp-code:"))
	m.Write(challengeID[:])
	return fmt.Sprintf("%06d", binary.BigEndian.Uint64(m.Sum(nil)[:8])%1_000_000)
}

// Hash is what otp_challenges.code_hash holds. Binding the destination makes
// equal codes for different people hash differently.
func (c Codes) Hash(dest contact.Address, code string) []byte {
	m := hmac.New(sha256.New, c.key)
	fmt.Fprintf(m, "otp-hash:%s:%s:%s", dest.Kind(), dest.Value(), code)
	return m.Sum(nil)
}
```

Create `internal/auth/otp/quota.go`:

```go
package otp

import (
	"slices"
	"time"
	"uuid"
)

// Rule allows at most Max sends within Window.
type Rule struct {
	Window time.Duration
	Max    int
}

// Quota is the recent sends of one destination ("dest:...") or one client
// address ("ip:...").
type Quota struct {
	key     string
	sentAt  []time.Time
	writeID uuid.UUID // zero until first saved
}

func NewQuota(key string) Quota { return Quota{key: key} }

// RestoreQuota rebuilds a stored quota. Stores only.
func RestoreQuota(key string, sentAt []time.Time, writeID uuid.UUID) Quota {
	return Quota{key: key, sentAt: sentAt, writeID: writeID}
}

func (q Quota) Key() string           { return q.key }
func (q Quota) SentAt() []time.Time   { return slices.Clone(q.sentAt) }
func (q Quota) WriteID() uuid.UUID    { return q.writeID }

// Admit records a send at now when every rule allows it. Otherwise it records
// nothing and returns the rule that refused and how long until that rule
// frees a slot. Sends older than the longest window are dropped.
func (q *Quota) Admit(now time.Time, rules ...Rule) (Rule, time.Duration, bool) {
	var longest time.Duration
	for _, r := range rules {
		longest = max(longest, r.Window)
	}
	q.sentAt = slices.DeleteFunc(q.sentAt, func(t time.Time) bool { return !t.After(now.Add(-longest)) })
	for _, r := range rules {
		var inWindow []time.Time
		for _, t := range q.sentAt {
			if t.After(now.Add(-r.Window)) {
				inWindow = append(inWindow, t)
			}
		}
		if len(inWindow) >= r.Max {
			return r, inWindow[0].Add(r.Window).Sub(now), false
		}
	}
	q.sentAt = append(q.sentAt, now)
	return Rule{}, 0, true
}
```

Run: `go test -short ./internal/auth/otp/`
Expected: PASS, the exercise test logging how long the table took.

- [ ] **Step 3: Write the failing store contracts**

Create `internal/auth/otp/otptest/contract.go`:

```go
// Package otptest holds in-memory OTP stores and the contract suites every
// implementation must pass.
package otptest

import (
	"bytes"
	"context"
	"errors"
	"net/netip"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/contact"
)

var ip = netip.MustParseAddr("203.0.113.7")

// RunChallengeContract checks that a store behaves as otp.ChallengeStore
// promises.
func RunChallengeContract(t *testing.T, newStore func(t *testing.T) otp.ChallengeStore) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	phone, _ := contact.ParsePhone("0901234567")
	other, _ := contact.ParsePhone("0907654321")
	create := func(t *testing.T, s otp.ChallengeStore, dest contact.Address, purpose otp.Purpose, at time.Time) otp.Challenge {
		t.Helper()
		c := otp.New(uuid.NewV7(), purpose, dest, ip, []byte("hash-"+at.String()), at)
		if err := s.Create(ctx, c); err != nil {
			t.Fatal(err)
		}
		return c
	}

	t.Run("create then get, twice is a no-op", func(t *testing.T) {
		s := newStore(t)
		c := create(t, s, phone, otp.PurposeLogin, now)
		if err := s.Create(ctx, otp.New(c.ID(), otp.PurposeLogin, other, ip, []byte("x"), now)); err != nil {
			t.Fatal(err)
		}
		got, err := s.Get(ctx, c.ID())
		if err != nil || got.Destination() != phone || got.IP() != ip || !bytes.Equal(got.CodeHash(), c.CodeHash()) ||
			got.Attempts() != 0 || !got.CreatedAt().Equal(now) || !got.ExpiresAt().Equal(now.Add(otp.CodeTTL)) ||
			got.ConsumedAt() != nil || got.WriteID() != c.ID() {
			t.Fatalf("got %+v %v", got, err)
		}
	})

	t.Run("get unknown", func(t *testing.T) {
		if _, err := newStore(t).Get(ctx, uuid.NewV7()); !errors.Is(err, otp.ErrNotFound) {
			t.Fatalf("err %v", err)
		}
	})

	t.Run("save, conflict and retry", func(t *testing.T) {
		s := newStore(t)
		c := create(t, s, phone, otp.PurposeLogin, now)
		stale := c
		c.Verify([]byte("wrong"), now)
		w := uuid.NewV7()
		if err := s.Save(ctx, &c, w); err != nil || c.WriteID() != w {
			t.Fatalf("save: %v", err)
		}
		if got, _ := s.Get(ctx, c.ID()); got.Attempts() != 1 {
			t.Fatalf("attempts %d", got.Attempts())
		}
		stale.Verify([]byte("wrong"), now)
		if err := s.Save(ctx, &stale, uuid.NewV7()); !errors.Is(err, otp.ErrConflict) {
			t.Fatalf("stale save: %v", err)
		}
		if err := s.Save(ctx, &c, w); err != nil {
			t.Fatalf("retry with the same write id: %v", err)
		}
	})

	t.Run("newest per destination and purpose", func(t *testing.T) {
		s := newStore(t)
		first := create(t, s, phone, otp.PurposeLogin, now)
		second := create(t, s, phone, otp.PurposeLogin, now.Add(time.Second))
		elsewhere := create(t, s, other, otp.PurposeLogin, now.Add(2*time.Second))
		create(t, s, phone, otp.Purpose("reset_password"), now.Add(3*time.Second))
		for _, c := range []struct {
			ch   otp.Challenge
			want bool
		}{{first, false}, {second, true}, {elsewhere, true}} {
			if got, err := s.IsNewest(ctx, c.ch); err != nil || got != c.want {
				t.Fatalf("%s: %v %v", c.ch.CreatedAt(), got, err)
			}
		}
	})
}

// RunQuotaContract checks that a store behaves as otp.QuotaStore promises.
func RunQuotaContract(t *testing.T, newStore func(t *testing.T) otp.QuotaStore) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	rule := otp.Rule{Window: time.Hour, Max: 10}

	t.Run("a missing quota is empty", func(t *testing.T) {
		q, err := newStore(t).Get(ctx, "ip:1.2.3.4")
		if err != nil || q.Key() != "ip:1.2.3.4" || len(q.SentAt()) != 0 || q.WriteID() != (uuid.UUID{}) {
			t.Fatalf("%+v %v", q, err)
		}
	})

	t.Run("save then get", func(t *testing.T) {
		s := newStore(t)
		q, _ := s.Get(ctx, "ip:1.2.3.4")
		q.Admit(now, rule)
		w := uuid.NewV7()
		if err := s.Save(ctx, &q, w); err != nil {
			t.Fatal(err)
		}
		got, _ := s.Get(ctx, "ip:1.2.3.4")
		if len(got.SentAt()) != 1 || !got.SentAt()[0].Equal(now) || got.WriteID() != w {
			t.Fatalf("%+v", got)
		}
	})

	t.Run("two first saves conflict", func(t *testing.T) {
		s := newStore(t)
		a, _ := s.Get(ctx, "dest:x")
		b, _ := s.Get(ctx, "dest:x")
		a.Admit(now, rule)
		b.Admit(now, rule)
		if err := s.Save(ctx, &a, uuid.NewV7()); err != nil {
			t.Fatal(err)
		}
		if err := s.Save(ctx, &b, uuid.NewV7()); !errors.Is(err, otp.ErrConflict) {
			t.Fatalf("second first save: %v", err)
		}
	})

	t.Run("a stale save conflicts and a retry succeeds", func(t *testing.T) {
		s := newStore(t)
		q, _ := s.Get(ctx, "dest:x")
		q.Admit(now, rule)
		s.Save(ctx, &q, uuid.NewV7())
		a, _ := s.Get(ctx, "dest:x")
		b, _ := s.Get(ctx, "dest:x")
		a.Admit(now.Add(time.Second), rule)
		b.Admit(now.Add(time.Second), rule)
		w := uuid.NewV7()
		retry := a
		if err := s.Save(ctx, &a, w); err != nil {
			t.Fatal(err)
		}
		if err := s.Save(ctx, &b, uuid.NewV7()); !errors.Is(err, otp.ErrConflict) {
			t.Fatalf("stale: %v", err)
		}
		if err := s.Save(ctx, &retry, w); err != nil {
			t.Fatalf("retry: %v", err)
		}
	})
}
```

Create `internal/auth/otp/otptest/memstore_test.go`:

```go
package otptest_test

import (
	"testing"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/auth/otp/otptest"
)

func TestMemChallenges(t *testing.T) {
	otptest.RunChallengeContract(t, func(*testing.T) otp.ChallengeStore { return otptest.NewChallenges() })
}

func TestMemQuotas(t *testing.T) {
	otptest.RunQuotaContract(t, func(*testing.T) otp.QuotaStore { return otptest.NewQuotas() })
}
```

Create `internal/auth/otp/stores_pg_test.go`:

```go
package otp_test

import (
	"testing"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/auth/otp/otptest"
	"github.com/shopnexus/server2/internal/platform/pgtest"
)

func TestPGChallenges(t *testing.T) {
	otptest.RunChallengeContract(t, func(t *testing.T) otp.ChallengeStore { return otp.NewChallengePGStore(pgtest.New(t)) })
}

func TestPGQuotas(t *testing.T) {
	otptest.RunQuotaContract(t, func(t *testing.T) otp.QuotaStore { return otp.NewQuotaPGStore(pgtest.New(t)) })
}
```

Run: `go test ./internal/auth/otp/...`
Expected: build failure naming `ChallengeStore`, `QuotaStore`, the PG constructors and the fakes.

- [ ] **Step 4: Implement the stores and the fakes**

Create `internal/auth/otp/challenge_store.go`:

```go
package otp

import (
	"context"
	"uuid"
)

// ChallengeStore persists challenges. Each method is its own transaction.
type ChallengeStore interface {
	// Create inserts c; the same id again does nothing.
	Create(ctx context.Context, c Challenge) error
	// Get returns ErrNotFound for an unknown id.
	Get(ctx context.Context, id uuid.UUID) (Challenge, error)
	// Save writes attempts and consumed_at when the row still has c.WriteID()
	// or already has writeID, then sets c's write ID. Otherwise ErrConflict.
	Save(ctx context.Context, c *Challenge, writeID uuid.UUID) error
	// IsNewest reports whether no later challenge exists for c's destination
	// and purpose.
	IsNewest(ctx context.Context, c Challenge) (bool, error)
}
```

Create `internal/auth/otp/challenge_store_pg.go`:

```go
package otp

import (
	"context"
	"errors"
	"net/netip"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/platform/contact"
)

type challengePG struct{ db *pgxpool.Pool }

func NewChallengePGStore(db *pgxpool.Pool) ChallengeStore { return challengePG{db} }

const createChallenge = `
INSERT INTO otp_challenges (id, purpose, kind, destination, account_id, code_hash, ip, expires_at, created_at, write_id)
VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
ON CONFLICT (id) DO NOTHING`

func (s challengePG) Create(ctx context.Context, c Challenge) error {
	_, err := s.db.Exec(ctx, createChallenge, c.id, c.purpose, c.dest.Kind(), c.dest.Value(), c.accountID,
		c.codeHash, c.ip, c.expiresAt, c.createdAt, c.writeID)
	return err
}

const getChallenge = `
SELECT id, purpose, kind, destination, account_id, code_hash, attempts, ip, expires_at, created_at, consumed_at, write_id
FROM otp_challenges WHERE id = $1`

func (s challengePG) Get(ctx context.Context, id uuid.UUID) (Challenge, error) {
	var (
		c    Challenge
		kind contact.Kind
		dest string
		ip   netip.Prefix
	)
	err := s.db.QueryRow(ctx, getChallenge, id).Scan(&c.id, &c.purpose, &kind, &dest, &c.accountID, &c.codeHash,
		&c.attempts, &ip, &c.expiresAt, &c.createdAt, &c.consumedAt, &c.writeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Challenge{}, ErrNotFound
	}
	if err != nil {
		return Challenge{}, err
	}
	c.dest, c.ip = contact.Restore(kind, dest), ip.Addr()
	return c, nil
}

const saveChallenge = `
UPDATE otp_challenges SET attempts = $3, consumed_at = $4, write_id = $5
WHERE id = $1 AND (write_id = $2 OR write_id = $5)`

func (s challengePG) Save(ctx context.Context, c *Challenge, writeID uuid.UUID) error {
	tag, err := s.db.Exec(ctx, saveChallenge, c.id, c.writeID, c.attempts, c.consumedAt, writeID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	c.writeID = writeID
	return nil
}

const isNewest = `
SELECT NOT EXISTS (
    SELECT 1 FROM otp_challenges
    WHERE destination = $1 AND purpose = $2 AND (created_at, id) > ($3, $4))`

func (s challengePG) IsNewest(ctx context.Context, c Challenge) (bool, error) {
	var newest bool
	err := s.db.QueryRow(ctx, isNewest, c.dest.Value(), c.purpose, c.createdAt, c.id).Scan(&newest)
	return newest, err
}
```

Create `internal/auth/otp/quota_store.go`:

```go
package otp

import (
	"context"
	"uuid"
)

// QuotaStore persists quotas. Each method is its own transaction.
type QuotaStore interface {
	// Get returns the quota for key, or an empty one when none is stored.
	Get(ctx context.Context, key string) (Quota, error)
	// Save writes q when its row still has q.WriteID() (no row, for a quota
	// never saved) or already has writeID. Otherwise ErrConflict.
	Save(ctx context.Context, q *Quota, writeID uuid.UUID) error
}
```

Create `internal/auth/otp/quota_store_pg.go`:

```go
package otp

import (
	"context"
	"errors"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type quotaPG struct{ db *pgxpool.Pool }

func NewQuotaPGStore(db *pgxpool.Pool) QuotaStore { return quotaPG{db} }

func (s quotaPG) Get(ctx context.Context, key string) (Quota, error) {
	q := Quota{key: key}
	err := s.db.QueryRow(ctx, `SELECT sent_at, write_id FROM otp_quotas WHERE key = $1`, key).Scan(&q.sentAt, &q.writeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Quota{key: key}, nil
	}
	return q, err
}

// saveQuota inserts a new quota or updates one whose write_id matches. A quota
// never saved carries the zero UUID, which no row holds, so two first saves
// of one key conflict.
const saveQuota = `
INSERT INTO otp_quotas (key, sent_at, write_id) VALUES ($1, $2, $4)
ON CONFLICT (key) DO UPDATE SET sent_at = EXCLUDED.sent_at, write_id = EXCLUDED.write_id
WHERE otp_quotas.write_id = $3 OR otp_quotas.write_id = $4`

func (s quotaPG) Save(ctx context.Context, q *Quota, writeID uuid.UUID) error {
	sentAt := q.sentAt
	if sentAt == nil {
		sentAt = []time.Time{}
	}
	tag, err := s.db.Exec(ctx, saveQuota, q.key, sentAt, q.writeID, writeID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	q.writeID = writeID
	return nil
}
```

Create `internal/auth/otp/otptest/challenges.go`:

```go
package otptest

import (
	"context"
	"sync"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/otp"
)

// Challenges is an in-memory otp.ChallengeStore.
type Challenges struct {
	mu   sync.Mutex
	rows map[uuid.UUID]otp.Challenge
}

func NewChallenges() *Challenges { return &Challenges{rows: map[uuid.UUID]otp.Challenge{}} }

func us(t time.Time) time.Time { return t.Truncate(time.Microsecond) }

func withWriteID(c otp.Challenge, w uuid.UUID) otp.Challenge {
	consumed := c.ConsumedAt()
	if consumed != nil {
		v := us(*consumed)
		consumed = &v
	}
	return otp.Restore(c.ID(), c.Purpose(), c.Destination(), c.AccountID(), c.CodeHash(), c.Attempts(), c.IP(),
		us(c.ExpiresAt()), us(c.CreatedAt()), consumed, w)
}

func (s *Challenges) Create(_ context.Context, c otp.Challenge) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.rows[c.ID()]; !ok {
		s.rows[c.ID()] = withWriteID(c, c.WriteID())
	}
	return nil
}

func (s *Challenges) Get(_ context.Context, id uuid.UUID) (otp.Challenge, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.rows[id]
	if !ok {
		return otp.Challenge{}, otp.ErrNotFound
	}
	return c, nil
}

func (s *Challenges) Save(_ context.Context, c *otp.Challenge, writeID uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur, ok := s.rows[c.ID()]
	if !ok || (cur.WriteID() != c.WriteID() && cur.WriteID() != writeID) {
		return otp.ErrConflict
	}
	*c = withWriteID(*c, writeID)
	s.rows[c.ID()] = *c
	return nil
}

func (s *Challenges) IsNewest(_ context.Context, c otp.Challenge) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, r := range s.rows {
		if r.Destination().Value() != c.Destination().Value() || r.Purpose() != c.Purpose() {
			continue
		}
		if r.CreatedAt().After(c.CreatedAt()) || (r.CreatedAt().Equal(c.CreatedAt()) && r.ID().Compare(c.ID()) > 0) {
			return false, nil
		}
	}
	return true, nil
}
```

Create `internal/auth/otp/otptest/quotas.go`:

```go
package otptest

import (
	"context"
	"sync"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/otp"
)

// Quotas is an in-memory otp.QuotaStore.
type Quotas struct {
	mu   sync.Mutex
	rows map[string]otp.Quota
}

func NewQuotas() *Quotas { return &Quotas{rows: map[string]otp.Quota{}} }

func (s *Quotas) Get(_ context.Context, key string) (otp.Quota, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if q, ok := s.rows[key]; ok {
		return q, nil
	}
	return otp.NewQuota(key), nil
}

func (s *Quotas) Save(_ context.Context, q *otp.Quota, writeID uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur, ok := s.rows[q.Key()]
	if ok && cur.WriteID() != q.WriteID() && cur.WriteID() != writeID {
		return otp.ErrConflict
	}
	if !ok && q.WriteID() != (uuid.UUID{}) {
		return otp.ErrConflict
	}
	sentAt := q.SentAt()
	for i, t := range sentAt {
		sentAt[i] = t.Truncate(time.Microsecond)
	}
	*q = otp.RestoreQuota(q.Key(), sentAt, writeID)
	s.rows[q.Key()] = *q
	return nil
}
```

- [ ] **Step 5: Run and commit**

Run: `go test -race ./internal/auth/otp/... && make lint`
Expected: PASS for the entities, both fakes and both Postgres stores.

```bash
git add internal/auth/otp
git commit -m "feat(auth/otp): challenges with derived codes, send quotas, write_id stores"
```

### Task 6: `auth/credentials`

The aggregate of an account's sign-in methods. Plan 3 adds the password and the last-identity rule's removal path to it.

**Files:**
- Create: `internal/auth/credentials/credentials.go`, `credentials_test.go`, `credentials_store.go`, `credentials_store_pg.go`, `credentials_store_pg_test.go`
- Create: `internal/auth/credentials/credentialstest/memstore.go`, `contract.go`, `memstore_test.go`

**Interfaces:**
- Produces: `credentials.Kind` (`Phone`, `Email`, `Google`), `credentials.KindOf(contact.Address) Kind`
- Produces: `credentials.Identity` with `ID()`, `Kind()`, `Value()`, `LastUsedAt() *time.Time`, `CreatedAt()`; `credentials.NewIdentity(id uuid.UUID, a contact.Address, now time.Time) Identity`; `credentials.RestoreIdentity(id uuid.UUID, kind Kind, value string, lastUsedAt *time.Time, createdAt time.Time) Identity`
- Produces: `credentials.Credentials` with `AccountID()`, `Identities() []Identity`, `WriteID()`, `UpdatedAt()`, `(*Credentials).MarkUsed(identityID uuid.UUID, now time.Time) error`; `credentials.New(accountID uuid.UUID, first Identity, now time.Time) Credentials`; `credentials.Restore(accountID uuid.UUID, identities []Identity, writeID uuid.UUID, updatedAt time.Time) Credentials`
- Produces: `credentials.ErrNotFound`, `credentials.ErrConflict` (plain), `credentials.ErrTaken` (409 `identity_taken`)
- Produces: `credentials.Store{Create(ctx, Credentials) error; Get(ctx, accountID) (Credentials, error); FindAccount(ctx, kind Kind, value string) (accountID, identityID uuid.UUID, err error); Save(ctx, *Credentials, writeID) error}`, `credentials.NewPGStore(*pgxpool.Pool) Store`, `credentialstest.NewMemStore()`, `credentialstest.RunStoreContract(t, func(t *testing.T) (credentials.Store, func() uuid.UUID))`

- [ ] **Step 1: Write the failing tests**

Create `internal/auth/credentials/credentials_test.go`:

```go
package credentials_test

import (
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/platform/contact"
)

var now = time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)

func TestNewCredentials(t *testing.T) {
	acc, idID := uuid.NewV7(), uuid.NewV7()
	phone, _ := contact.ParsePhone("0901234567")
	c := credentials.New(acc, credentials.NewIdentity(idID, phone, now), now)
	ids := c.Identities()
	if c.AccountID() != acc || c.WriteID() != acc || len(ids) != 1 || ids[0].ID() != idID ||
		ids[0].Kind() != credentials.Phone || ids[0].Value() != "+84901234567" || !ids[0].LastUsedAt().Equal(now) {
		t.Fatalf("%+v", c)
	}
}

func TestMarkUsed(t *testing.T) {
	phone, _ := contact.ParsePhone("0901234567")
	id := uuid.NewV7()
	c := credentials.New(uuid.NewV7(), credentials.NewIdentity(id, phone, now), now)
	if err := c.MarkUsed(id, now.Add(time.Hour)); err != nil || !c.Identities()[0].LastUsedAt().Equal(now.Add(time.Hour)) {
		t.Fatalf("%v %v", err, c.Identities()[0].LastUsedAt())
	}
	if err := c.MarkUsed(uuid.NewV7(), now); !errors.Is(err, credentials.ErrNotFound) {
		t.Fatalf("unknown identity: %v", err)
	}
}
```

Create `internal/auth/credentials/credentialstest/contract.go`:

```go
// Package credentialstest holds the in-memory credentials store and the
// contract suite every credentials.Store implementation must pass.
package credentialstest

import (
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/platform/contact"
)

// RunStoreContract checks that a store behaves as credentials.Store promises.
// newStore also returns a function that creates an account to own rows.
func RunStoreContract(t *testing.T, newStore func(t *testing.T) (credentials.Store, func() uuid.UUID)) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	phone, _ := contact.ParsePhone("0901234567")
	email, _ := contact.ParseEmail("linh@gmail.com")
	fresh := func(t *testing.T, s credentials.Store, acc uuid.UUID, a contact.Address) credentials.Credentials {
		t.Helper()
		c := credentials.New(acc, credentials.NewIdentity(uuid.NewV7(), a, now), now)
		if err := s.Create(ctx, c); err != nil {
			t.Fatal(err)
		}
		return c
	}

	t.Run("create, get and find", func(t *testing.T) {
		s, newAccount := newStore(t)
		acc := newAccount()
		c := fresh(t, s, acc, phone)
		got, err := s.Get(ctx, acc)
		if err != nil || got.WriteID() != acc || len(got.Identities()) != 1 || got.Identities()[0].Value() != "+84901234567" {
			t.Fatalf("got %+v %v", got, err)
		}
		gotAcc, gotID, err := s.FindAccount(ctx, credentials.Phone, "+84901234567")
		if err != nil || gotAcc != acc || gotID != c.Identities()[0].ID() {
			t.Fatalf("find: %s %s %v", gotAcc, gotID, err)
		}
		if _, _, err := s.FindAccount(ctx, credentials.Email, "+84901234567"); !errors.Is(err, credentials.ErrNotFound) {
			t.Fatalf("find by the wrong kind: %v", err)
		}
	})

	t.Run("create twice is a no-op", func(t *testing.T) {
		s, newAccount := newStore(t)
		acc := newAccount()
		c := fresh(t, s, acc, phone)
		if err := s.Create(ctx, c); err != nil {
			t.Fatalf("retry: %v", err)
		}
	})

	t.Run("another account's identity is taken", func(t *testing.T) {
		s, newAccount := newStore(t)
		first := fresh(t, s, newAccount(), phone)
		second := credentials.New(newAccount(), credentials.NewIdentity(uuid.NewV7(), phone, now), now)
		if err := s.Create(ctx, second); !errors.Is(err, credentials.ErrTaken) {
			t.Fatalf("duplicate: %v", err)
		}
		if got, _ := s.Get(ctx, first.AccountID()); !got.Identities()[0].LastUsedAt().Equal(now) {
			t.Fatal("the losing create touched the owner's identity")
		}
		if _, err := s.Get(ctx, second.AccountID()); !errors.Is(err, credentials.ErrNotFound) {
			t.Fatalf("the losing create left a row: %v", err)
		}
	})

	t.Run("save, conflict and retry", func(t *testing.T) {
		s, newAccount := newStore(t)
		acc := newAccount()
		fresh(t, s, acc, email)
		a, _ := s.Get(ctx, acc)
		b, _ := s.Get(ctx, acc)
		a.MarkUsed(a.Identities()[0].ID(), now.Add(time.Hour))
		retry := a
		w := uuid.NewV7()
		if err := s.Save(ctx, &a, w); err != nil || a.WriteID() != w {
			t.Fatalf("save: %v", err)
		}
		if got, _ := s.Get(ctx, acc); !got.Identities()[0].LastUsedAt().Equal(now.Add(time.Hour)) {
			t.Fatalf("last used %v", got.Identities()[0].LastUsedAt())
		}
		b.MarkUsed(b.Identities()[0].ID(), now)
		if err := s.Save(ctx, &b, uuid.NewV7()); !errors.Is(err, credentials.ErrConflict) {
			t.Fatalf("stale: %v", err)
		}
		if err := s.Save(ctx, &retry, w); err != nil {
			t.Fatalf("retry: %v", err)
		}
	})

	t.Run("get unknown", func(t *testing.T) {
		s, _ := newStore(t)
		if _, err := s.Get(ctx, uuid.NewV7()); !errors.Is(err, credentials.ErrNotFound) {
			t.Fatalf("err %v", err)
		}
	})
}
```

Create `internal/auth/credentials/credentialstest/memstore_test.go`:

```go
package credentialstest_test

import (
	"testing"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/auth/credentials/credentialstest"
)

func TestMemStore(t *testing.T) {
	credentialstest.RunStoreContract(t, func(*testing.T) (credentials.Store, func() uuid.UUID) {
		return credentialstest.NewMemStore(), uuid.NewV7
	})
}
```

Create `internal/auth/credentials/credentials_store_pg_test.go`:

```go
package credentials_test

import (
	"context"
	"testing"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/auth/credentials/credentialstest"
	"github.com/shopnexus/server2/internal/platform/pgtest"
)

func TestPGStore(t *testing.T) {
	credentialstest.RunStoreContract(t, func(t *testing.T) (credentials.Store, func() uuid.UUID) {
		pool := pgtest.New(t)
		newAccount := func() uuid.UUID {
			id := uuid.NewV7()
			if _, err := pool.Exec(context.Background(), `INSERT INTO accounts (id, write_id) VALUES ($1, $1)`, id); err != nil {
				t.Fatal(err)
			}
			return id
		}
		return credentials.NewPGStore(pool), newAccount
	})
}
```

Run: `go test ./internal/auth/credentials/...`
Expected: build failure, package `credentials` has no non-test files.

- [ ] **Step 2: Implement**

Create `internal/auth/credentials/credentials.go`:

```go
// Package credentials holds the aggregate of an account's sign-in methods:
// its verified identities and, from plan 3, its password.
package credentials

import (
	"errors"
	"slices"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/contact"
)

type Kind string

const (
	Phone  Kind = "phone"
	Email  Kind = "email"
	Google Kind = "google"
)

var (
	ErrNotFound = errors.New("credentials: not found")
	ErrConflict = errors.New("credentials: changed meanwhile")
	ErrTaken    = apperr.New(apperr.KindConflict, "identity_taken", "this sign-in method belongs to another account")
)

// KindOf maps a contact kind to the identity kind of the same name.
func KindOf(a contact.Address) Kind { return Kind(a.Kind()) }

// Identity is one verified way to sign in.
type Identity struct {
	id         uuid.UUID
	kind       Kind
	value      string
	lastUsedAt *time.Time
	createdAt  time.Time
}

// NewIdentity builds the identity for a phone or email whose code was just
// verified; it counts as used at now.
func NewIdentity(id uuid.UUID, a contact.Address, now time.Time) Identity {
	return Identity{id: id, kind: KindOf(a), value: a.Value(), lastUsedAt: &now, createdAt: now}
}

// RestoreIdentity rebuilds a stored identity. Stores only.
func RestoreIdentity(id uuid.UUID, kind Kind, value string, lastUsedAt *time.Time, createdAt time.Time) Identity {
	return Identity{id, kind, value, lastUsedAt, createdAt}
}

func (i Identity) ID() uuid.UUID          { return i.id }
func (i Identity) Kind() Kind             { return i.kind }
func (i Identity) Value() string          { return i.value }
func (i Identity) LastUsedAt() *time.Time { return i.lastUsedAt }
func (i Identity) CreatedAt() time.Time   { return i.createdAt }

// Credentials is every sign-in method of one account.
type Credentials struct {
	accountID  uuid.UUID
	identities []Identity
	writeID    uuid.UUID
	updatedAt  time.Time
}

// New starts the credentials of a new account with its first identity. The
// first write ID is the account ID.
func New(accountID uuid.UUID, first Identity, now time.Time) Credentials {
	return Credentials{accountID: accountID, identities: []Identity{first}, writeID: accountID, updatedAt: now}
}

// Restore rebuilds stored credentials. Stores only.
func Restore(accountID uuid.UUID, identities []Identity, writeID uuid.UUID, updatedAt time.Time) Credentials {
	return Credentials{accountID, identities, writeID, updatedAt}
}

func (c Credentials) AccountID() uuid.UUID     { return c.accountID }
func (c Credentials) Identities() []Identity   { return slices.Clone(c.identities) }
func (c Credentials) WriteID() uuid.UUID       { return c.writeID }
func (c Credentials) UpdatedAt() time.Time     { return c.updatedAt }

// MarkUsed records a sign-in with the identity at now.
func (c *Credentials) MarkUsed(identityID uuid.UUID, now time.Time) error {
	for n, i := range c.identities {
		if i.id == identityID {
			c.identities[n].lastUsedAt = &now
			c.updatedAt = now
			return nil
		}
	}
	return ErrNotFound
}
```

Create `internal/auth/credentials/credentials_store.go`:

```go
package credentials

import (
	"context"
	"uuid"
)

// Store persists credentials. Each method is its own transaction.
type Store interface {
	// Create inserts c with its identities. The same credentials again do
	// nothing; an identity another account holds is ErrTaken and nothing is
	// written.
	Create(ctx context.Context, c Credentials) error
	// Get returns ErrNotFound for an account without credentials.
	Get(ctx context.Context, accountID uuid.UUID) (Credentials, error)
	// FindAccount returns the account and identity holding kind and value,
	// or ErrNotFound. It is a query, not an aggregate load.
	FindAccount(ctx context.Context, kind Kind, value string) (accountID, identityID uuid.UUID, err error)
	// Save writes c and replaces its identities when the root still has
	// c.WriteID() or already has writeID. Otherwise ErrConflict; an identity
	// another account holds is ErrTaken.
	Save(ctx context.Context, c *Credentials, writeID uuid.UUID) error
}
```

Create `internal/auth/credentials/credentials_store_pg.go`:

```go
package credentials

import (
	"context"
	"errors"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type pgStore struct{ db *pgxpool.Pool }

func NewPGStore(db *pgxpool.Pool) Store { return pgStore{db} }

// upsertIdentity inserts an identity or refreshes its last_used_at. The WHERE
// keeps another account's identity untouched, and then no row comes back.
const upsertIdentity = `
INSERT INTO identities (id, account_id, kind, value, last_used_at, created_at)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (kind, value) DO UPDATE SET last_used_at = EXCLUDED.last_used_at
WHERE identities.account_id = EXCLUDED.account_id
RETURNING account_id`

func upsertIdentities(ctx context.Context, tx pgx.Tx, accountID uuid.UUID, ids []Identity) error {
	for _, i := range ids {
		var owner uuid.UUID
		err := tx.QueryRow(ctx, upsertIdentity, i.id, accountID, i.kind, i.value, i.lastUsedAt, i.createdAt).Scan(&owner)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrTaken
		}
		if err != nil {
			return err
		}
	}
	return nil
}

func (s pgStore) Create(ctx context.Context, c Credentials) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `
INSERT INTO credentials (account_id, write_id, updated_at) VALUES ($1, $2, $3)
ON CONFLICT (account_id) DO NOTHING`, c.accountID, c.writeID, c.updatedAt); err != nil {
		return err
	}
	if err := upsertIdentities(ctx, tx, c.accountID, c.identities); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func (s pgStore) Get(ctx context.Context, accountID uuid.UUID) (Credentials, error) {
	c := Credentials{accountID: accountID}
	err := s.db.QueryRow(ctx, `SELECT write_id, updated_at FROM credentials WHERE account_id = $1`, accountID).
		Scan(&c.writeID, &c.updatedAt)
	if errors.Is(err, pgx.ErrNoRows) {
		return Credentials{}, ErrNotFound
	}
	if err != nil {
		return Credentials{}, err
	}
	rows, err := s.db.Query(ctx, `
SELECT id, kind, value, last_used_at, created_at FROM identities WHERE account_id = $1 ORDER BY created_at, id`, accountID)
	if err != nil {
		return Credentials{}, err
	}
	defer rows.Close()
	for rows.Next() {
		var i Identity
		if err := rows.Scan(&i.id, &i.kind, &i.value, &i.lastUsedAt, &i.createdAt); err != nil {
			return Credentials{}, err
		}
		c.identities = append(c.identities, i)
	}
	return c, rows.Err()
}

func (s pgStore) FindAccount(ctx context.Context, kind Kind, value string) (uuid.UUID, uuid.UUID, error) {
	var accountID, identityID uuid.UUID
	err := s.db.QueryRow(ctx, `SELECT account_id, id FROM identities WHERE kind = $1 AND value = $2`, kind, value).
		Scan(&accountID, &identityID)
	if errors.Is(err, pgx.ErrNoRows) {
		return uuid.UUID{}, uuid.UUID{}, ErrNotFound
	}
	return accountID, identityID, err
}

func (s pgStore) Save(ctx context.Context, c *Credentials, writeID uuid.UUID) error {
	tx, err := s.db.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	tag, err := tx.Exec(ctx, `
UPDATE credentials SET write_id = $3, updated_at = $4
WHERE account_id = $1 AND (write_id = $2 OR write_id = $3)`, c.accountID, c.writeID, writeID, c.updatedAt)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	keep := make([]uuid.UUID, len(c.identities))
	for n, i := range c.identities {
		keep[n] = i.id
	}
	if _, err := tx.Exec(ctx, `DELETE FROM identities WHERE account_id = $1 AND NOT (id = ANY($2))`, c.accountID, keep); err != nil {
		return err
	}
	if err := upsertIdentities(ctx, tx, c.accountID, c.identities); err != nil {
		return err
	}
	if err := tx.Commit(ctx); err != nil {
		return err
	}
	c.writeID = writeID
	return nil
}
```

Create `internal/auth/credentials/credentialstest/memstore.go`:

```go
package credentialstest

import (
	"context"
	"sync"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/credentials"
)

// MemStore is an in-memory credentials.Store.
type MemStore struct {
	mu   sync.Mutex
	rows map[uuid.UUID]credentials.Credentials
}

func NewMemStore() *MemStore { return &MemStore{rows: map[uuid.UUID]credentials.Credentials{}} }

func normalise(c credentials.Credentials, w uuid.UUID) credentials.Credentials {
	var ids []credentials.Identity
	for _, i := range c.Identities() {
		used := i.LastUsedAt()
		if used != nil {
			v := used.Truncate(time.Microsecond)
			used = &v
		}
		ids = append(ids, credentials.RestoreIdentity(i.ID(), i.Kind(), i.Value(), used, i.CreatedAt().Truncate(time.Microsecond)))
	}
	return credentials.Restore(c.AccountID(), ids, w, c.UpdatedAt().Truncate(time.Microsecond))
}

func (s *MemStore) takenByOther(c credentials.Credentials) bool {
	for acc, other := range s.rows {
		if acc == c.AccountID() {
			continue
		}
		for _, oi := range other.Identities() {
			for _, i := range c.Identities() {
				if oi.Kind() == i.Kind() && oi.Value() == i.Value() {
					return true
				}
			}
		}
	}
	return false
}

func (s *MemStore) Create(_ context.Context, c credentials.Credentials) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.takenByOther(c) {
		return credentials.ErrTaken
	}
	if _, ok := s.rows[c.AccountID()]; !ok {
		s.rows[c.AccountID()] = normalise(c, c.WriteID())
	}
	return nil
}

func (s *MemStore) Get(_ context.Context, accountID uuid.UUID) (credentials.Credentials, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	c, ok := s.rows[accountID]
	if !ok {
		return credentials.Credentials{}, credentials.ErrNotFound
	}
	return c, nil
}

func (s *MemStore) FindAccount(_ context.Context, kind credentials.Kind, value string) (uuid.UUID, uuid.UUID, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for acc, c := range s.rows {
		for _, i := range c.Identities() {
			if i.Kind() == kind && i.Value() == value {
				return acc, i.ID(), nil
			}
		}
	}
	return uuid.UUID{}, uuid.UUID{}, credentials.ErrNotFound
}

func (s *MemStore) Save(_ context.Context, c *credentials.Credentials, writeID uuid.UUID) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	cur, ok := s.rows[c.AccountID()]
	if !ok || (cur.WriteID() != c.WriteID() && cur.WriteID() != writeID) {
		return credentials.ErrConflict
	}
	if s.takenByOther(*c) {
		return credentials.ErrTaken
	}
	*c = normalise(*c, writeID)
	s.rows[c.AccountID()] = *c
	return nil
}
```

- [ ] **Step 3: Run and commit**

Run: `go test -race ./internal/auth/credentials/... && make lint`
Expected: PASS on the fake and on Postgres.

```bash
git add internal/auth/credentials
git commit -m "feat(auth/credentials): identities as one aggregate per account"
```

### Task 7: `auth/session`

**Files:**
- Modify: `go.mod`, `go.sum` (`github.com/golang-jwt/jwt/v5`)
- Create: `internal/auth/session/session.go`, `session_test.go`, `token.go`, `token_test.go`, `session_store.go`, `session_store_pg.go`, `session_store_pg_test.go`
- Create: `internal/auth/session/sessiontest/memstore.go`, `contract.go`, `memstore_test.go`

**Interfaces:**
- Produces: `session.AccessTTL`, `session.MaxAge`, `session.IdleLimit`
- Produces: `session.Session` with `ID()`, `AccountID()`, `RefreshHash()`, `PrevRefreshHash()`, `DeviceName()`, `AuthTime()`, `CreatedAt()`, `LastUsedAt()`, `ExpiresAt()`, `RevokedAt()`, `WriteID()`, `Usable(now) error`, `(*Session).Rotate(now) string`, `(*Session).Revoke(now)`; `session.New(id, accountID uuid.UUID, deviceName string, authTime, now time.Time) (Session, string)`; `session.Restore(...)`; `session.NewRefreshToken() (string, []byte)`, `session.HashRefresh(string) []byte`
- Produces: `session.ErrNotFound`, `session.ErrConflict` (plain), `ErrInvalidRefresh` (401 `invalid_refresh_token`), `ErrRevoked` (401 `session_revoked`), `ErrExpired` (401 `session_expired`), `ErrInvalidToken` (401 `invalid_token`)
- Produces: `session.Claims`, `session.NewSigner(config.AuthConfig) Signer`, `(Signer).Sign(accountID, sessionID uuid.UUID, authTime, now time.Time) (string, time.Time, error)`, `session.NewVerifier(config.AuthConfig) Verifier`, `(Verifier).Verify(token string, now time.Time) (authn.Principal, error)`, `session.Tokens{AccessToken; AccessTokenExpiresAt; RefreshToken; TokenType}`
- Produces: `session.View{ID; DeviceName; CreatedAt; LastUsedAt}`, `session.Store{Create(ctx, Session) (bool, error); Get(ctx, id) (Session, error); FindByRefresh(ctx, []byte) (Session, error); FindByPrevRefresh(ctx, []byte) (Session, error); Save(ctx, *Session, uuid.UUID) error; RevokeAll(ctx, accountID uuid.UUID, now time.Time) error; ListActive(ctx, accountID uuid.UUID, now time.Time, before uuid.UUID, limit int) ([]View, error)}`, `session.NewPGStore(*pgxpool.Pool) Store`, `sessiontest.NewMemStore()`, `sessiontest.RunStoreContract(t, func(t *testing.T) (session.Store, func() uuid.UUID))`

- [ ] **Step 1: Add the JWT library**

Run: `go get github.com/golang-jwt/jwt/v5@v5.3.1`
Expected: `go.mod` lists it. Check `go list -m -versions github.com/golang-jwt/jwt/v5` first and take a newer release if one exists.

- [ ] **Step 2: Write the failing tests**

Create `internal/auth/session/session_test.go`:

```go
package session_test

import (
	"bytes"
	"errors"
	"strings"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/session"
)

var now = time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)

func TestNewSession(t *testing.T) {
	id, acc := uuid.NewV7(), uuid.NewV7()
	s, token := session.New(id, acc, "Pixel 9", now.Add(-time.Minute), now)
	if !strings.HasPrefix(token, "rt_") || len(token) != 3+43 || !bytes.Equal(s.RefreshHash(), session.HashRefresh(token)) {
		t.Fatalf("token %q", token)
	}
	if s.ID() != id || s.WriteID() != id || s.AccountID() != acc || s.DeviceName() != "Pixel 9" ||
		!s.AuthTime().Equal(now.Add(-time.Minute)) || !s.ExpiresAt().Equal(now.Add(session.MaxAge)) || s.PrevRefreshHash() != nil {
		t.Fatalf("%+v", s)
	}
}

func TestRotateKeepsThePreviousHash(t *testing.T) {
	s, first := session.New(uuid.NewV7(), uuid.NewV7(), "", now, now)
	second := s.Rotate(now.Add(time.Hour))
	if second == first || !bytes.Equal(s.RefreshHash(), session.HashRefresh(second)) ||
		!bytes.Equal(s.PrevRefreshHash(), session.HashRefresh(first)) || !s.LastUsedAt().Equal(now.Add(time.Hour)) {
		t.Fatalf("%+v", s)
	}
}

func TestUsable(t *testing.T) {
	s, _ := session.New(uuid.NewV7(), uuid.NewV7(), "", now, now)
	if err := s.Usable(now); err != nil {
		t.Fatal(err)
	}
	if err := s.Usable(now.Add(session.IdleLimit)); !errors.Is(err, session.ErrExpired) {
		t.Fatalf("idle: %v", err)
	}
	s.Rotate(now.Add(50 * 24 * time.Hour))
	if err := s.Usable(now.Add(59 * 24 * time.Hour)); err != nil {
		t.Fatalf("used recently, old: %v", err)
	}
	if err := s.Usable(now.Add(session.MaxAge)); !errors.Is(err, session.ErrExpired) {
		t.Fatalf("max age: %v", err)
	}
	s.Revoke(now)
	if err := s.Usable(now); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("revoked: %v", err)
	}
}
```

Create `internal/auth/session/token_test.go`:

```go
package session_test

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strings"
	"testing"
	"time"
	"uuid"

	"github.com/golang-jwt/jwt/v5"

	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/config"
)

func keys(kid string) config.AuthConfig {
	k := config.NewAuthKeys()
	k.JWTKeyID = kid
	return k
}

func TestSignThenVerify(t *testing.T) {
	k := keys("current")
	acc, sid, authTime := uuid.NewV7(), uuid.NewV7(), now.Add(-time.Hour)
	token, exp, err := session.NewSigner(k).Sign(acc, sid, authTime, now)
	if err != nil || !exp.Equal(now.Add(session.AccessTTL)) {
		t.Fatalf("%v %v", exp, err)
	}
	p, err := session.NewVerifier(k).Verify(token, now.Add(time.Minute))
	if err != nil || p.AccountID != acc || p.SessionID != sid || !p.AuthTime.Equal(authTime) {
		t.Fatalf("%+v %v", p, err)
	}
}

func TestVerifyRejects(t *testing.T) {
	k := keys("current")
	signer, verifier := session.NewSigner(k), session.NewVerifier(k)
	good, _, _ := signer.Sign(uuid.NewV7(), uuid.NewV7(), now, now)
	claims := session.Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer: k.Issuer, Audience: jwt.ClaimStrings{k.Audience}, Subject: uuid.NewV7().String(),
			IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(now.Add(session.AccessTTL)),
		},
		SessionID: uuid.NewV7().String(), AuthTime: now.Unix(),
	}
	none := jwt.NewWithClaims(jwt.SigningMethodNone, claims)
	none.Header["kid"] = k.JWTKeyID
	noneToken, _ := none.SignedString(jwt.UnsafeAllowNoneSignatureType)
	swap := jwt.NewWithClaims(jwt.SigningMethodHS256, claims)
	swap.Header["kid"] = k.JWTKeyID
	swapToken, _ := swap.SignedString([]byte(k.JWTKey.Public().(ed25519.PublicKey)))
	forged, _, _ := session.NewSigner(keys("current")).Sign(uuid.NewV7(), uuid.NewV7(), now, now)
	parts := strings.Split(good, ".")
	parts[1] = base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"` + uuid.NewV7().String() + `"}`))
	wrongAud, wrongIss := k, k
	wrongAud.Audience, wrongIss.Issuer = "another-app", "someone-else"

	cases := []struct {
		name     string
		verifier session.Verifier
		token    string
		at       time.Time
	}{
		{"expired past leeway", verifier, good, now.Add(session.AccessTTL + 31*time.Second)},
		{"alg none", verifier, noneToken, now},
		{"HS256 keyed with the public key", verifier, swapToken, now},
		{"another key with the same kid", verifier, forged, now},
		{"tampered payload", verifier, strings.Join(parts, "."), now},
		{"another audience", session.NewVerifier(wrongAud), good, now},
		{"another issuer", session.NewVerifier(wrongIss), good, now},
		{"garbage", verifier, "not.a.token", now},
		{"empty", verifier, "", now},
	}
	for _, c := range cases {
		if _, err := c.verifier.Verify(c.token, c.at); !errors.Is(err, session.ErrInvalidToken) {
			t.Errorf("%s: %v", c.name, err)
		}
	}
	if _, err := verifier.Verify(good, now.Add(session.AccessTTL+29*time.Second)); err != nil {
		t.Errorf("inside the leeway: %v", err)
	}
}

func TestVerifierKeyRotation(t *testing.T) {
	old, current := keys("old"), keys("new")
	current.JWTPrevKeyID, current.JWTPrevKey = old.JWTKeyID, old.JWTKey.Public().(ed25519.PublicKey)
	oldToken, _, _ := session.NewSigner(old).Sign(uuid.NewV7(), uuid.NewV7(), now, now)
	if _, err := session.NewVerifier(current).Verify(oldToken, now); err != nil {
		t.Fatalf("token from the previous key: %v", err)
	}
	withoutPrev := current
	withoutPrev.JWTPrevKeyID, withoutPrev.JWTPrevKey = "", nil
	if _, err := session.NewVerifier(withoutPrev).Verify(oldToken, now); !errors.Is(err, session.ErrInvalidToken) {
		t.Fatalf("previous key dropped: %v", err)
	}
	ghost, _, _ := session.NewSigner(keys("ghost")).Sign(uuid.NewV7(), uuid.NewV7(), now, now)
	if _, err := session.NewVerifier(current).Verify(ghost, now); !errors.Is(err, session.ErrInvalidToken) {
		t.Fatalf("unknown kid: %v", err)
	}
}
```

Create `internal/auth/session/sessiontest/contract.go`:

```go
// Package sessiontest holds the in-memory session store and the contract
// suite every session.Store implementation must pass.
package sessiontest

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/session"
)

// RunStoreContract checks that a store behaves as session.Store promises.
// newStore also returns a function that creates an account to own rows.
func RunStoreContract(t *testing.T, newStore func(t *testing.T) (session.Store, func() uuid.UUID)) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	create := func(t *testing.T, s session.Store, acc uuid.UUID, at time.Time) (session.Session, string) {
		t.Helper()
		sess, token := session.New(uuid.NewV7(), acc, "Pixel 9", at, at)
		if created, err := s.Create(ctx, sess); err != nil || !created {
			t.Fatalf("create: %v %v", created, err)
		}
		return sess, token
	}

	t.Run("create, get, find", func(t *testing.T) {
		s, newAccount := newStore(t)
		acc := newAccount()
		sess, token := create(t, s, acc, now)
		if created, err := s.Create(ctx, sess); err != nil || created {
			t.Fatalf("second create: %v %v", created, err)
		}
		got, err := s.Get(ctx, sess.ID())
		if err != nil || got.AccountID() != acc || got.DeviceName() != "Pixel 9" || !got.AuthTime().Equal(now) ||
			!got.ExpiresAt().Equal(now.Add(session.MaxAge)) || got.WriteID() != sess.ID() || got.RevokedAt() != nil {
			t.Fatalf("get %+v %v", got, err)
		}
		if f, err := s.FindByRefresh(ctx, session.HashRefresh(token)); err != nil || f.ID() != sess.ID() {
			t.Fatalf("find: %v", err)
		}
		for _, find := range []func(context.Context, []byte) (session.Session, error){s.FindByRefresh, s.FindByPrevRefresh} {
			if _, err := find(ctx, []byte("nope")); !errors.Is(err, session.ErrNotFound) {
				t.Fatalf("unknown hash: %v", err)
			}
		}
		if _, err := s.Get(ctx, uuid.NewV7()); !errors.Is(err, session.ErrNotFound) {
			t.Fatalf("unknown id: %v", err)
		}
	})

	t.Run("rotate, conflict and retry", func(t *testing.T) {
		s, newAccount := newStore(t)
		sess, token := create(t, s, newAccount(), now)
		stale := sess
		next := sess.Rotate(now.Add(time.Minute))
		retry := sess
		w := uuid.NewV7()
		if err := s.Save(ctx, &sess, w); err != nil {
			t.Fatal(err)
		}
		got, _ := s.FindByRefresh(ctx, session.HashRefresh(next))
		if !bytes.Equal(got.PrevRefreshHash(), session.HashRefresh(token)) || !got.LastUsedAt().Equal(now.Add(time.Minute)) {
			t.Fatalf("after rotate %+v", got)
		}
		if prev, err := s.FindByPrevRefresh(ctx, session.HashRefresh(token)); err != nil || prev.ID() != sess.ID() {
			t.Fatalf("by previous: %v", err)
		}
		stale.Rotate(now.Add(time.Minute))
		if err := s.Save(ctx, &stale, uuid.NewV7()); !errors.Is(err, session.ErrConflict) {
			t.Fatalf("stale: %v", err)
		}
		if err := s.Save(ctx, &retry, w); err != nil {
			t.Fatalf("retry: %v", err)
		}
	})

	t.Run("revoke all", func(t *testing.T) {
		s, newAccount := newStore(t)
		acc, other := newAccount(), newAccount()
		a, _ := create(t, s, acc, now)
		b, _ := create(t, s, acc, now)
		c, _ := create(t, s, other, now)
		if err := s.RevokeAll(ctx, acc, now); err != nil {
			t.Fatal(err)
		}
		for _, x := range []struct {
			id      uuid.UUID
			revoked bool
		}{{a.ID(), true}, {b.ID(), true}, {c.ID(), false}} {
			got, _ := s.Get(ctx, x.id)
			if (got.RevokedAt() != nil) != x.revoked {
				t.Fatalf("revoked %v, want %v", got.RevokedAt(), x.revoked)
			}
			if x.revoked && got.WriteID() == x.id {
				t.Fatal("revoke all left the write id, so a racing refresh would not conflict")
			}
		}
	})

	t.Run("list active", func(t *testing.T) {
		s, newAccount := newStore(t)
		acc, other := newAccount(), newAccount()
		first, _ := create(t, s, acc, now)
		revoked, _ := create(t, s, acc, now)
		revoked.Revoke(now)
		s.Save(ctx, &revoked, uuid.NewV7())
		create(t, s, acc, now.Add(-session.MaxAge-time.Hour))
		create(t, s, acc, now.Add(-session.IdleLimit-time.Hour))
		last, _ := create(t, s, acc, now)
		create(t, s, other, now)

		all, err := s.ListActive(ctx, acc, now, uuid.UUID{}, 10)
		if err != nil || len(all) != 2 || all[0].ID != last.ID() || all[1].ID != first.ID() || all[0].DeviceName != "Pixel 9" {
			t.Fatalf("list %+v %v", all, err)
		}
		page, _ := s.ListActive(ctx, acc, now, uuid.UUID{}, 1)
		next, _ := s.ListActive(ctx, acc, now, page[0].ID, 1)
		if len(page) != 1 || page[0].ID != last.ID() || len(next) != 1 || next[0].ID != first.ID() {
			t.Fatalf("pages %+v %+v", page, next)
		}
	})
}
```

In `rotate, conflict and retry`, `stale` is copied before the rotation and `retry` after it, so `retry` carries the rotated hashes with the old write ID, which is what a retried step sends.

Create `internal/auth/session/sessiontest/memstore_test.go` running the contract with `sessiontest.NewMemStore()` and `uuid.NewV7`, and `internal/auth/session/session_store_pg_test.go` running it with `session.NewPGStore(pool)` and a `newAccount` that runs `INSERT INTO accounts (id, write_id) VALUES ($1, $1)`, as in Task 6.

Run: `go test ./internal/auth/session/...`
Expected: build failure, package `session` has no non-test files.

- [ ] **Step 3: Implement**

Create `internal/auth/session/session.go`:

```go
// Package session holds signed-in devices: the session with its rotating
// refresh token, the access tokens signed for it, and the store.
package session

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/platform/apperr"
)

const (
	AccessTTL = 15 * time.Minute
	MaxAge    = 60 * 24 * time.Hour
	IdleLimit = 30 * 24 * time.Hour
)

var (
	ErrNotFound       = errors.New("session: not found")
	ErrConflict       = errors.New("session: changed meanwhile")
	ErrInvalidRefresh = apperr.New(apperr.KindUnauthenticated, "invalid_refresh_token", "the refresh token is not valid")
	ErrRevoked        = apperr.New(apperr.KindUnauthenticated, "session_revoked", "the session was signed out")
	ErrExpired        = apperr.New(apperr.KindUnauthenticated, "session_expired", "the session has expired; sign in again")
	ErrInvalidToken   = apperr.New(apperr.KindUnauthenticated, "invalid_token", "the access token is not valid")
)

// Session is one signed-in device.
type Session struct {
	id              uuid.UUID
	accountID       uuid.UUID
	refreshHash     []byte
	prevRefreshHash []byte
	deviceName      string
	authTime        time.Time
	createdAt       time.Time
	lastUsedAt      time.Time
	expiresAt       time.Time
	revokedAt       *time.Time
	writeID         uuid.UUID
}

// New starts a session and returns it with its refresh token; only the
// token's hash is kept. The first write ID is the session ID.
func New(id, accountID uuid.UUID, deviceName string, authTime, now time.Time) (Session, string) {
	token, hash := NewRefreshToken()
	return Session{id: id, accountID: accountID, refreshHash: hash, deviceName: deviceName, authTime: authTime,
		createdAt: now, lastUsedAt: now, expiresAt: now.Add(MaxAge), writeID: id}, token
}

// Restore rebuilds a stored session. Stores only.
func Restore(id, accountID uuid.UUID, refreshHash, prevRefreshHash []byte, deviceName string,
	authTime, createdAt, lastUsedAt, expiresAt time.Time, revokedAt *time.Time, writeID uuid.UUID) Session {
	return Session{id, accountID, refreshHash, prevRefreshHash, deviceName, authTime, createdAt, lastUsedAt, expiresAt, revokedAt, writeID}
}

func (s Session) ID() uuid.UUID           { return s.id }
func (s Session) AccountID() uuid.UUID    { return s.accountID }
func (s Session) RefreshHash() []byte     { return s.refreshHash }
func (s Session) PrevRefreshHash() []byte { return s.prevRefreshHash }
func (s Session) DeviceName() string      { return s.deviceName }
func (s Session) AuthTime() time.Time     { return s.authTime }
func (s Session) CreatedAt() time.Time    { return s.createdAt }
func (s Session) LastUsedAt() time.Time   { return s.lastUsedAt }
func (s Session) ExpiresAt() time.Time    { return s.expiresAt }
func (s Session) RevokedAt() *time.Time   { return s.revokedAt }
func (s Session) WriteID() uuid.UUID      { return s.writeID }

// Usable returns nil while the session may refresh: not revoked, younger than
// MaxAge, and used within IdleLimit.
func (s Session) Usable(now time.Time) error {
	if s.revokedAt != nil {
		return ErrRevoked
	}
	if !now.Before(s.expiresAt) || !now.Before(s.lastUsedAt.Add(IdleLimit)) {
		return ErrExpired
	}
	return nil
}

// Rotate replaces the refresh token, keeps the old hash to recognise a
// replay, and returns the new token.
func (s *Session) Rotate(now time.Time) string {
	token, hash := NewRefreshToken()
	s.prevRefreshHash, s.refreshHash, s.lastUsedAt = s.refreshHash, hash, now
	return token
}

// Revoke signs the session out; a second call keeps the first time.
func (s *Session) Revoke(now time.Time) {
	if s.revokedAt == nil {
		s.revokedAt = &now
	}
}

// NewRefreshToken returns rt_ plus 32 random bytes in base64url, and its hash.
func NewRefreshToken() (string, []byte) {
	b := make([]byte, 32)
	rand.Read(b)
	token := "rt_" + base64.RawURLEncoding.EncodeToString(b)
	return token, HashRefresh(token)
}

// HashRefresh is plain SHA-256: the token carries 256 random bits, so a slow
// hash would add nothing.
func HashRefresh(token string) []byte {
	h := sha256.Sum256([]byte(token))
	return h[:]
}
```

Create `internal/auth/session/token.go`:

```go
package session

import (
	"crypto/ed25519"
	"errors"
	"fmt"
	"time"
	"uuid"

	"github.com/golang-jwt/jwt/v5"

	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/config"
)

// Claims are the access token's claims. No phone, email or name goes in:
// anyone holding the token can read it.
type Claims struct {
	jwt.RegisteredClaims
	SessionID string `json:"sid"`
	AuthTime  int64  `json:"auth_time"`
}

// Tokens is what a sign-in or a refresh returns.
type Tokens struct {
	AccessToken          string    `json:"access_token"`
	AccessTokenExpiresAt time.Time `json:"access_token_expires_at"`
	RefreshToken         string    `json:"refresh_token"`
	TokenType            string    `json:"token_type"`
}

// Signer signs access tokens with the current Ed25519 key.
type Signer struct {
	kid      string
	key      ed25519.PrivateKey
	issuer   string
	audience string
}

func NewSigner(cfg config.AuthConfig) Signer {
	return Signer{kid: cfg.JWTKeyID, key: cfg.JWTKey, issuer: cfg.Issuer, audience: cfg.Audience}
}

// Sign returns an access token valid AccessTTL from now, and its expiry.
func (s Signer) Sign(accountID, sessionID uuid.UUID, authTime, now time.Time) (string, time.Time, error) {
	exp := now.Add(AccessTTL)
	t := jwt.NewWithClaims(jwt.SigningMethodEdDSA, Claims{
		RegisteredClaims: jwt.RegisteredClaims{
			Issuer: s.issuer, Audience: jwt.ClaimStrings{s.audience}, Subject: accountID.String(),
			IssuedAt: jwt.NewNumericDate(now), ExpiresAt: jwt.NewNumericDate(exp),
		},
		SessionID: sessionID.String(),
		AuthTime:  authTime.Unix(),
	})
	t.Header["kid"] = s.kid
	signed, err := t.SignedString(s.key)
	return signed, exp, err
}

// Verifier checks access tokens against the current key and, during a key
// change, the previous one.
type Verifier struct {
	keys     map[string]ed25519.PublicKey
	issuer   string
	audience string
}

func NewVerifier(cfg config.AuthConfig) Verifier {
	keys := map[string]ed25519.PublicKey{cfg.JWTKeyID: cfg.JWTKey.Public().(ed25519.PublicKey)}
	if cfg.JWTPrevKeyID != "" {
		keys[cfg.JWTPrevKeyID] = cfg.JWTPrevKey
	}
	return Verifier{keys: keys, issuer: cfg.Issuer, audience: cfg.Audience}
}

// Verify returns the principal of a valid token at now. Only EdDSA is
// accepted, which closes alg:none and algorithm-swap attacks. Every failure
// is ErrInvalidToken, carrying the cause for the log.
func (v Verifier) Verify(token string, now time.Time) (authn.Principal, error) {
	var c Claims
	_, err := jwt.ParseWithClaims(token, &c, func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		key, ok := v.keys[kid]
		if !ok {
			return nil, fmt.Errorf("unknown kid %q", kid)
		}
		return key, nil
	},
		jwt.WithValidMethods([]string{jwt.SigningMethodEdDSA.Alg()}),
		jwt.WithIssuer(v.issuer),
		jwt.WithAudience(v.audience),
		jwt.WithLeeway(30*time.Second),
		jwt.WithTimeFunc(func() time.Time { return now }),
		jwt.WithExpirationRequired(),
		jwt.WithIssuedAt(),
	)
	if err != nil {
		return authn.Principal{}, invalidToken(err)
	}
	account, err1 := uuid.Parse(c.Subject)
	sid, err2 := uuid.Parse(c.SessionID)
	if err1 != nil || err2 != nil || c.AuthTime == 0 {
		return authn.Principal{}, invalidToken(errors.New("sub, sid or auth_time missing"))
	}
	return authn.Principal{AccountID: account, SessionID: sid, AuthTime: time.Unix(c.AuthTime, 0).UTC()}, nil
}

func invalidToken(cause error) error {
	e := *ErrInvalidToken
	e.Err = cause
	return &e
}
```

Create `internal/auth/session/session_store.go`:

```go
package session

import (
	"context"
	"time"
	"uuid"
)

// View is one row of the device list.
type View struct {
	ID         uuid.UUID
	DeviceName string
	CreatedAt  time.Time
	LastUsedAt time.Time
}

// Store persists sessions. Each method is its own transaction.
type Store interface {
	// Create inserts s and reports whether it did; false means the id exists.
	Create(ctx context.Context, s Session) (bool, error)
	Get(ctx context.Context, id uuid.UUID) (Session, error)
	FindByRefresh(ctx context.Context, hash []byte) (Session, error)
	// FindByPrevRefresh finds the session a rotated token belonged to.
	FindByPrevRefresh(ctx context.Context, hash []byte) (Session, error)
	// Save writes s when its row still has s.WriteID() or already has
	// writeID, then sets s's write ID. Otherwise ErrConflict.
	Save(ctx context.Context, s *Session, writeID uuid.UUID) error
	// RevokeAll revokes every open session of the account in one statement
	// and gives each a new write ID, so a refresh racing it conflicts.
	RevokeAll(ctx context.Context, accountID uuid.UUID, now time.Time) error
	// ListActive is a query: the account's usable sessions at now, newest
	// first, with ids below before (zero starts at the newest), at most limit.
	ListActive(ctx context.Context, accountID uuid.UUID, now time.Time, before uuid.UUID, limit int) ([]View, error)
}
```

Create `internal/auth/session/session_store_pg.go`:

```go
package session

import (
	"context"
	"errors"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

type pgStore struct{ db *pgxpool.Pool }

func NewPGStore(db *pgxpool.Pool) Store { return pgStore{db} }

const columns = `id, account_id, refresh_hash, prev_refresh_hash, coalesce(device_name, ''),
       auth_time, created_at, last_used_at, expires_at, revoked_at, write_id`

func scan(row pgx.Row) (Session, error) {
	var s Session
	err := row.Scan(&s.id, &s.accountID, &s.refreshHash, &s.prevRefreshHash, &s.deviceName,
		&s.authTime, &s.createdAt, &s.lastUsedAt, &s.expiresAt, &s.revokedAt, &s.writeID)
	if errors.Is(err, pgx.ErrNoRows) {
		return Session{}, ErrNotFound
	}
	return s, err
}

const createSession = `
INSERT INTO sessions (id, account_id, refresh_hash, device_name, auth_time, created_at, last_used_at, expires_at, write_id)
VALUES ($1, $2, $3, NULLIF($4, ''), $5, $6, $6, $7, $1)
ON CONFLICT (id) DO NOTHING`

func (s pgStore) Create(ctx context.Context, x Session) (bool, error) {
	tag, err := s.db.Exec(ctx, createSession, x.id, x.accountID, x.refreshHash, x.deviceName, x.authTime, x.createdAt, x.expiresAt)
	return tag.RowsAffected() == 1, err
}

func (s pgStore) Get(ctx context.Context, id uuid.UUID) (Session, error) {
	return scan(s.db.QueryRow(ctx, `SELECT `+columns+` FROM sessions WHERE id = $1`, id))
}

func (s pgStore) FindByRefresh(ctx context.Context, hash []byte) (Session, error) {
	return scan(s.db.QueryRow(ctx, `SELECT `+columns+` FROM sessions WHERE refresh_hash = $1`, hash))
}

func (s pgStore) FindByPrevRefresh(ctx context.Context, hash []byte) (Session, error) {
	return scan(s.db.QueryRow(ctx, `SELECT `+columns+` FROM sessions WHERE prev_refresh_hash = $1 LIMIT 1`, hash))
}

const saveSession = `
UPDATE sessions SET refresh_hash = $3, prev_refresh_hash = $4, last_used_at = $5, revoked_at = $6, write_id = $7
WHERE id = $1 AND (write_id = $2 OR write_id = $7)`

func (s pgStore) Save(ctx context.Context, x *Session, writeID uuid.UUID) error {
	tag, err := s.db.Exec(ctx, saveSession, x.id, x.writeID, x.refreshHash, x.prevRefreshHash, x.lastUsedAt, x.revokedAt, writeID)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrConflict
	}
	x.writeID = writeID
	return nil
}

func (s pgStore) RevokeAll(ctx context.Context, accountID uuid.UUID, now time.Time) error {
	_, err := s.db.Exec(ctx, `
UPDATE sessions SET revoked_at = $2, write_id = uuidv7()
WHERE account_id = $1 AND revoked_at IS NULL`, accountID, now)
	return err
}

const listActive = `
SELECT id, coalesce(device_name, ''), created_at, last_used_at
FROM sessions
WHERE account_id = $1 AND revoked_at IS NULL AND expires_at > $2 AND last_used_at > $3
  AND ($4::uuid IS NULL OR id < $4)
ORDER BY id DESC
LIMIT $5`

func (s pgStore) ListActive(ctx context.Context, accountID uuid.UUID, now time.Time, before uuid.UUID, limit int) ([]View, error) {
	var cursor any
	if before != (uuid.UUID{}) {
		cursor = before
	}
	rows, err := s.db.Query(ctx, listActive, accountID, now, now.Add(-IdleLimit), cursor, limit)
	if err != nil {
		return nil, err
	}
	return pgx.CollectRows(rows, func(r pgx.CollectableRow) (View, error) {
		var v View
		err := r.Scan(&v.ID, &v.DeviceName, &v.CreatedAt, &v.LastUsedAt)
		return v, err
	})
}
```

Create `internal/auth/session/sessiontest/memstore.go`:

```go
package sessiontest

import (
	"bytes"
	"context"
	"slices"
	"sync"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/session"
)

// MemStore is an in-memory session.Store.
type MemStore struct {
	mu   sync.Mutex
	rows map[uuid.UUID]session.Session
}

func NewMemStore() *MemStore { return &MemStore{rows: map[uuid.UUID]session.Session{}} }

func us(t time.Time) time.Time { return t.Truncate(time.Microsecond) }

func normalise(s session.Session, w uuid.UUID) session.Session {
	revoked := s.RevokedAt()
	if revoked != nil {
		v := us(*revoked)
		revoked = &v
	}
	return session.Restore(s.ID(), s.AccountID(), s.RefreshHash(), s.PrevRefreshHash(), s.DeviceName(), us(s.AuthTime()),
		us(s.CreatedAt()), us(s.LastUsedAt()), us(s.ExpiresAt()), revoked, w)
}

func (m *MemStore) Create(_ context.Context, s session.Session) (bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if _, ok := m.rows[s.ID()]; ok {
		return false, nil
	}
	m.rows[s.ID()] = normalise(s, s.WriteID())
	return true, nil
}

func (m *MemStore) find(match func(session.Session) bool) (session.Session, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.rows {
		if match(s) {
			return s, nil
		}
	}
	return session.Session{}, session.ErrNotFound
}

func (m *MemStore) Get(_ context.Context, id uuid.UUID) (session.Session, error) {
	return m.find(func(s session.Session) bool { return s.ID() == id })
}

func (m *MemStore) FindByRefresh(_ context.Context, hash []byte) (session.Session, error) {
	return m.find(func(s session.Session) bool { return bytes.Equal(s.RefreshHash(), hash) })
}

func (m *MemStore) FindByPrevRefresh(_ context.Context, hash []byte) (session.Session, error) {
	return m.find(func(s session.Session) bool { return s.PrevRefreshHash() != nil && bytes.Equal(s.PrevRefreshHash(), hash) })
}

func (m *MemStore) Save(_ context.Context, s *session.Session, writeID uuid.UUID) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	cur, ok := m.rows[s.ID()]
	if !ok || (cur.WriteID() != s.WriteID() && cur.WriteID() != writeID) {
		return session.ErrConflict
	}
	*s = normalise(*s, writeID)
	m.rows[s.ID()] = *s
	return nil
}

func (m *MemStore) RevokeAll(_ context.Context, accountID uuid.UUID, now time.Time) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for id, s := range m.rows {
		if s.AccountID() == accountID && s.RevokedAt() == nil {
			s.Revoke(now)
			m.rows[id] = normalise(s, uuid.NewV7())
		}
	}
	return nil
}

func (m *MemStore) ListActive(_ context.Context, accountID uuid.UUID, now time.Time, before uuid.UUID, limit int) ([]session.View, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	var out []session.View
	for _, s := range m.rows {
		if s.AccountID() == accountID && s.Usable(now) == nil && (before == (uuid.UUID{}) || s.ID().Compare(before) < 0) {
			out = append(out, session.View{ID: s.ID(), DeviceName: s.DeviceName(), CreatedAt: s.CreatedAt(), LastUsedAt: s.LastUsedAt()})
		}
	}
	slices.SortFunc(out, func(a, b session.View) int { return b.ID.Compare(a.ID) })
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}
```

- [ ] **Step 4: Run and commit**

Run: `go test -race ./internal/auth/session/... && make lint`
Expected: PASS on entity, tokens, fake and Postgres.

```bash
git add go.mod go.sum internal/auth/session
git commit -m "feat(auth/session): sessions with write_id, rotating refresh tokens, EdDSA access tokens"
```

### Task 8: `POST /v1/auth/otp` through Restate service `OTP`

**Files:**
- Create: `api/parameters/common.yaml`, `api/responses/common.yaml`, `api/paths/auth.yaml`, `api/schemas/auth.yaml`; Modify: `api/embed.go`, `api/openapi.yaml`
- Create: `internal/auth/refusal.go`, `accounts.go`, `restate.go`, `metrics.go`, `routes.go`, `otp_send.go`, `otp_service.go`
- Create: `internal/auth/helpers_test.go`, `otp_send_test.go`, `otp_service_test.go`
- Modify: `internal/app/app.go`
- Create: `e2e/inbox_test.go`, `e2e/auth_helpers_test.go`, `e2e/auth_otp_test.go`; Modify: `e2e/main_test.go`

**Interfaces:**
- Consumes: `otp.*`, `contact.*`, `sms.Sender`, `email.Sender`, `httpx.ClientIP`, `restatex`, `restatetest`
- Produces: `auth.Refusal{Kind apperr.Kind; Code, Message string; Details map[string]any}` with `Err() error`; `auth.refuse(err error) (*Refusal, error)`
- Produces: `auth.AccountPort{Create(ctx, id uuid.UUID, displayName string) error; Delete(ctx, id) error; Status(ctx, id) (account.Status, error)}`
- Produces: `auth.Restate{Client *ingress.Client; Prefix string}` with `OTP() ingress.Requester[OTPSendInput, OTPSendResult]`
- Produces: `auth.ErrOTPTooSoon` (429 `otp_too_soon`, detail `retry_after`), `auth.ErrOTPLimit` (429 `otp_limit`), `auth.ErrTryAgain` (409 `try_again`)
- Produces: `auth.AdmitOTP(ctx, quotas otp.QuotaStore, dest contact.Address, ip netip.Addr, now time.Time) error`, `auth.NewChallenge(codes otp.Codes, id uuid.UUID, purpose otp.Purpose, dest contact.Address, ip netip.Addr, now time.Time) otp.Challenge`, `auth.SendCode(ctx, smsSender sms.Sender, emailSender email.Sender, codes otp.Codes, c otp.Challenge, now time.Time) error`
- Produces: `auth.OTP` (Restate service, handler `Send`), `auth.OTPSendInput{Kind contact.Kind; Destination string; Purpose otp.Purpose; IP netip.Addr}`, `auth.OTPSendResult{ChallengeID uuid.UUID; Refusal *Refusal}`, `auth.OTPSendHandler(rs Restate, trusted []netip.Prefix, log) http.Handler`
- Produces: `auth.Ports{Accounts AccountPort; Challenges otp.ChallengeStore; Quotas otp.QuotaStore; Credentials credentials.Store; Sessions session.Store; SMS sms.Sender; Email email.Sender}`, `auth.Keys{Codes otp.Codes; Signer session.Signer; Verifier session.Verifier}`, `auth.Services(prefix string, p Ports, k Keys) []restate.ServiceDefinition`, `auth.Routes(r *httpx.Router, p Ports, k Keys, rs Restate, trusted []netip.Prefix, now func() time.Time, log *slog.Logger)`
- Produces (E2E): `box` with `count(to) int` and `code(t, to, nth) string`; `newPhone()`, `newEmail()`, `newIP() [2]string`, `newKey() [2]string`, `decode[T]`, `errorOf`, `sendOTP(t, kind, dest string, headers ...[2]string) Response`

- [ ] **Step 1: Write the OpenAPI operation**

Create `api/parameters/common.yaml`:

```yaml
IdempotencyKey:
  name: Idempotency-Key
  in: header
  required: true
  description: A new UUID per user action, reused when the app retries that action. A repeated key returns the first result.
  schema:
    type: string
    format: uuid
```

Create `api/responses/common.yaml`:

```yaml
BadRequest:
  description: The request does not match the API description (invalid_request, malformed_json).
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
Unauthorized:
  description: No valid credentials (unauthenticated, invalid_token, or a refresh code).
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
Forbidden:
  description: The account is suspended (account_suspended).
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
NotFound:
  description: No such resource for this caller.
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
Conflict:
  description: The request collided with another (try_again).
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
Unprocessable:
  description: Well formed, but a rule refuses it.
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
PreconditionRequired:
  description: The caller must prove who they are again first (reauth_required).
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
TooManyRequests:
  description: Rate limited; details.retry_after gives seconds to wait when known.
  content:
    application/json:
      schema:
        $ref: "../schemas/error.yaml#/Error"
```

Create `api/schemas/auth.yaml`:

```yaml
OTPSendRequest:
  type: object
  additionalProperties: false
  required: [kind, destination, purpose]
  properties:
    kind:
      type: string
      enum: [phone, email]
    destination:
      type: string
      minLength: 1
      maxLength: 254
      description: A Vietnamese mobile number in any common format, or an email address.
    purpose:
      type: string
      enum: [login]
OTPChallenge:
  type: object
  additionalProperties: false
  required: [challenge_id, resend_after]
  properties:
    challenge_id:
      type: string
      format: uuid
    resend_after:
      type: integer
      description: Seconds before another code may be requested for this destination.
```

Create `api/paths/auth.yaml`:

```yaml
otp:
  post:
    operationId: sendOtp
    summary: Send a one-time code to a phone or email.
    description: |
      The reply is the same whether or not an account uses the destination.
      Limits: one code per destination per 45 seconds, five per destination
      per hour, twenty per client address per hour.
    tags: [auth]
    parameters:
      - $ref: "../parameters/common.yaml#/IdempotencyKey"
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/auth.yaml#/OTPSendRequest"
    responses:
      "200":
        description: The code is on its way.
        content:
          application/json:
            schema:
              $ref: "../schemas/auth.yaml#/OTPChallenge"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "422":
        $ref: "../responses/common.yaml#/Unprocessable"
      "429":
        $ref: "../responses/common.yaml#/TooManyRequests"
```

In `api/openapi.yaml` add the path and `components.securitySchemes.bearerAuth` (`type: http`, `scheme: bearer`, `bearerFormat: JWT`):

```yaml
  /v1/auth/otp:
    $ref: "paths/auth.yaml#/otp"
```

`api/embed.go`: `//go:embed openapi.yaml paths schemas responses parameters`.

Run: `go test -short ./api/`
Expected: PASS. If kin-openapi rejects a `$ref` to a parameter or response in another file, inline it and ledger the ruling.

- [ ] **Step 2: Write the failing unit tests**

Create `internal/auth/helpers_test.go`:

```go
package auth_test

import (
	"context"
	"log/slog"
	"net/netip"
	"sync"
	"time"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/config"
)

var (
	now      = time.Date(2026, 10, 20, 9, 0, 0, 0, time.UTC)
	testKeys = config.NewAuthKeys()
	clientIP = netip.MustParseAddr("203.0.113.7")
	discard  = slog.New(slog.DiscardHandler)
)

func codes() otp.Codes { return otp.NewCodes(testKeys.OTPKey) }

type message struct{ To, Text string }

// inbox records what the SMS and email senders were asked to send.
type inbox struct {
	mu   sync.Mutex
	msgs []message
}

func (b *inbox) Send(_ context.Context, to, text string) error {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.msgs = append(b.msgs, message{to, text})
	return nil
}

func (b *inbox) all() []message {
	b.mu.Lock()
	defer b.mu.Unlock()
	return append([]message(nil), b.msgs...)
}

// emailInbox adapts inbox to email.Sender.
type emailInbox struct{ *inbox }

func (e emailInbox) Send(ctx context.Context, to, _, body string) error { return e.inbox.Send(ctx, to, body) }
```

Create `internal/auth/otp_send_test.go`:

```go
package auth_test

import (
	"context"
	"crypto/hmac"
	"errors"
	"fmt"
	"net/netip"
	"strings"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/auth/otp/otptest"
	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/contact"
)

func phone(t *testing.T, raw string) contact.Address {
	t.Helper()
	a, err := contact.ParsePhone(raw)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func TestAdmitSpacingAndHourlyCap(t *testing.T) {
	q, dest, ctx := otptest.NewQuotas(), phone(t, "0901234567"), context.Background()
	at := now
	for i := range 5 {
		if err := auth.AdmitOTP(ctx, q, dest, clientIP, at); err != nil {
			t.Fatalf("send %d: %v", i+1, err)
		}
		err := auth.AdmitOTP(ctx, q, dest, clientIP, at.Add(44*time.Second))
		var ae *apperr.Error
		if !errors.Is(err, auth.ErrOTPTooSoon) || !errors.As(err, &ae) || ae.Details["retry_after"] != 1 {
			t.Fatalf("at 44 s: %v", err)
		}
		at = at.Add(45 * time.Second)
	}
	if err := auth.AdmitOTP(ctx, q, dest, clientIP, at); !errors.Is(err, auth.ErrOTPLimit) {
		t.Fatalf("sixth send: %v", err)
	}
}

func TestAdmitCapsOneAddress(t *testing.T) {
	q, ctx := otptest.NewQuotas(), context.Background()
	for i := range 20 {
		if err := auth.AdmitOTP(ctx, q, phone(t, fmt.Sprintf("09%08d", i)), clientIP, now); err != nil {
			t.Fatalf("send %d: %v", i+1, err)
		}
	}
	if err := auth.AdmitOTP(ctx, q, phone(t, "0987654321"), clientIP, now); !errors.Is(err, auth.ErrOTPLimit) {
		t.Fatalf("21st: %v", err)
	}
	if err := auth.AdmitOTP(ctx, q, phone(t, "0987654321"), netip.MustParseAddr("198.51.100.1"), now); err != nil {
		t.Fatalf("another address: %v", err)
	}
}

// losing makes the first n saves lose a race.
type losing struct {
	otp.QuotaStore
	n int
}

func (l *losing) Save(ctx context.Context, q *otp.Quota, w uuid.UUID) error {
	if l.n > 0 {
		l.n--
		return otp.ErrConflict
	}
	return l.QuotaStore.Save(ctx, q, w)
}

func TestAdmitRetriesConflicts(t *testing.T) {
	ctx := context.Background()
	if err := auth.AdmitOTP(ctx, &losing{otptest.NewQuotas(), 2}, phone(t, "0901234567"), clientIP, now); err != nil {
		t.Fatalf("two conflicts: %v", err)
	}
	if err := auth.AdmitOTP(ctx, &losing{otptest.NewQuotas(), 3}, phone(t, "0901234567"), clientIP, now); !errors.Is(err, auth.ErrOTPLimit) {
		t.Fatalf("three conflicts: %v", err)
	}
}

func TestNewChallengeHashesTheDerivedCode(t *testing.T) {
	id, dest := uuid.NewV7(), phone(t, "0901234567")
	c := auth.NewChallenge(codes(), id, otp.PurposeLogin, dest, clientIP, now)
	if c.ID() != id || !hmac.Equal(c.CodeHash(), codes().Hash(dest, codes().For(id))) {
		t.Fatalf("%+v", c)
	}
}

func TestSendCode(t *testing.T) {
	ctx, b := context.Background(), &inbox{}
	email, _ := contact.ParseEmail("linh@gmail.com")
	for _, dest := range []contact.Address{phone(t, "0901234567"), email} {
		c := auth.NewChallenge(codes(), uuid.NewV7(), otp.PurposeLogin, dest, clientIP, now)
		if err := auth.SendCode(ctx, b, emailInbox{b}, codes(), c, now); err != nil {
			t.Fatal(err)
		}
		last := b.all()[len(b.all())-1]
		if last.To != dest.Value() || !strings.Contains(last.Text, codes().For(c.ID())) {
			t.Fatalf("%+v", last)
		}
	}
	expired := auth.NewChallenge(codes(), uuid.NewV7(), otp.PurposeLogin, phone(t, "0901234567"), clientIP, now)
	if err := auth.SendCode(ctx, b, emailInbox{b}, codes(), expired, now.Add(otp.CodeTTL)); err != nil || len(b.all()) != 2 {
		t.Fatalf("expired challenge sent: %v, %d messages", err, len(b.all()))
	}
}
```

Run: `go test -short ./internal/auth/`
Expected: build failure, package `auth` has no non-test files.

- [ ] **Step 3: Implement the use case functions**

Create `internal/auth/refusal.go`:

```go
package auth

import (
	"errors"

	"github.com/shopnexus/server2/internal/platform/apperr"
)

// ErrTryAgain answers a request that collided with another write. It reads
// the same whether the collided OTP guess was right or wrong.
var ErrTryAgain = apperr.New(apperr.KindConflict, "try_again", "the request collided with another; try again")

// Refusal is a business error carried in a Restate result. The ingress turns
// a terminal error into a bare 500, so refusals travel as data.
type Refusal struct {
	Kind    apperr.Kind    `json:"kind"`
	Code    string         `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

// refuse splits err: a business error becomes a Refusal, anything else stays
// an error, which Restate retries.
func refuse(err error) (*Refusal, error) {
	var ae *apperr.Error
	if errors.As(err, &ae) {
		return &Refusal{Kind: ae.Kind, Code: ae.Code, Message: ae.Message, Details: ae.Details}, nil
	}
	return nil, err
}

// Err turns the refusal back into the error httpx writes; nil stays nil.
func (r *Refusal) Err() error {
	if r == nil {
		return nil
	}
	return &apperr.Error{Kind: r.Kind, Code: r.Code, Message: r.Message, Details: r.Details}
}
```

Create `internal/auth/accounts.go`:

```go
package auth

import (
	"context"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
)

// AccountPort is what auth needs from module account; account.Client
// implements it.
type AccountPort interface {
	Create(ctx context.Context, id uuid.UUID, displayName string) error
	Delete(ctx context.Context, id uuid.UUID) error
	Status(ctx context.Context, id uuid.UUID) (account.Status, error)
}
```

Create `internal/auth/metrics.go`:

```go
package auth

import (
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/metric"
)

var meter = otel.Meter("github.com/shopnexus/server2/internal/auth")

// The spec's auth counters. Instruments from the global meter bind to the
// provider telemetry.Setup installs, even when they were created first.
var (
	otpSent      = counter("otp_sent_total", "OTP codes sent")
	logins       = counter("login_total", "sign-in attempts by method and result")
	refreshReuse = counter("refresh_reuse_total", "refresh tokens presented after they were rotated")
)

func counter(name, description string) metric.Int64Counter {
	c, err := meter.Int64Counter(name, metric.WithDescription(description))
	if err != nil {
		panic(err)
	}
	return c
}
```

Create `internal/auth/otp_send.go`:

```go
package auth

import (
	"context"
	"errors"
	"log/slog"
	"math"
	"net/http"
	"net/netip"
	"time"
	"uuid"

	restate "github.com/restatedev/sdk-go"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/contact"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/provider/email"
	"github.com/shopnexus/server2/internal/provider/sms"
)

var (
	ErrOTPTooSoon = apperr.New(apperr.KindRateLimited, "otp_too_soon", "wait before requesting another code")
	ErrOTPLimit   = apperr.New(apperr.KindRateLimited, "otp_limit", "too many codes requested; try again later")
)

const resendAfter = 45 * time.Second

var (
	destinationRules = []otp.Rule{{Window: resendAfter, Max: 1}, {Window: time.Hour, Max: 5}}
	addressRules     = []otp.Rule{{Window: time.Hour, Max: 20}}
)

// AdmitOTP spends one send from the destination's quota, then the address's.
// A destination quota spent before the address refuses stays spent.
func AdmitOTP(ctx context.Context, quotas otp.QuotaStore, dest contact.Address, ip netip.Addr, now time.Time) error {
	if err := admit(ctx, quotas, "dest:"+dest.Value(), now, destinationRules); err != nil {
		return err
	}
	return admit(ctx, quotas, "ip:"+ip.String(), now, addressRules)
}

// admit retries a lost race three times, so parallel sends behind one NAT do
// not get a spurious 429. It runs inside restate.Run, where a fresh write ID
// per attempt is allowed.
func admit(ctx context.Context, quotas otp.QuotaStore, key string, now time.Time, rules []otp.Rule) error {
	for range 3 {
		q, err := quotas.Get(ctx, key)
		if err != nil {
			return err
		}
		rule, wait, ok := q.Admit(now, rules...)
		if !ok {
			if rule.Window == resendAfter {
				return ErrOTPTooSoon.WithDetail("retry_after", int(math.Ceil(wait.Seconds())))
			}
			return ErrOTPLimit
		}
		if err := quotas.Save(ctx, &q, uuid.NewV7()); !errors.Is(err, otp.ErrConflict) {
			return err
		}
	}
	return ErrOTPLimit
}

// NewChallenge builds the challenge for id. Its code is derived from id, so
// the send step computes the same code again.
func NewChallenge(codes otp.Codes, id uuid.UUID, purpose otp.Purpose, dest contact.Address, ip netip.Addr, now time.Time) otp.Challenge {
	return otp.New(id, purpose, dest, ip, codes.Hash(dest, codes.For(id)), now)
}

// SendCode sends a challenge's code, unless it has expired by now.
func SendCode(ctx context.Context, smsSender sms.Sender, emailSender email.Sender, codes otp.Codes, c otp.Challenge, now time.Time) error {
	if !now.Before(c.ExpiresAt()) {
		return nil
	}
	text := "Mã xác thực shopnexus: " + codes.For(c.ID()) + ". Mã hết hạn sau 5 phút. Không chia sẻ mã này với ai."
	if c.Destination().Kind() == contact.Email {
		return emailSender.Send(ctx, c.Destination().Value(), "Mã xác thực shopnexus", text)
	}
	return smsSender.Send(ctx, c.Destination().Value(), text)
}

type OTPSendRequest struct {
	Kind        contact.Kind `json:"kind"`
	Destination string       `json:"destination"`
	Purpose     otp.Purpose  `json:"purpose"`
}

type OTPSendResponse struct {
	ChallengeID uuid.UUID `json:"challenge_id"`
	ResendAfter int       `json:"resend_after"`
}

// POST /v1/auth/otp
func OTPSendHandler(rs Restate, trusted []netip.Prefix, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		in, err := httpx.Decode[OTPSendRequest](r)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		dest, err := contact.Parse(in.Kind, in.Destination)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		ip := httpx.ClientIP(r, trusted)
		if !ip.IsValid() {
			httpx.WriteError(w, r, log, errors.New("otp send: no client address"))
			return
		}
		ctx, cancel := context.WithTimeout(r.Context(), restateTimeout)
		defer cancel()
		res, err := rs.OTP().Request(ctx,
			OTPSendInput{Kind: dest.Kind(), Destination: dest.Value(), Purpose: in.Purpose, IP: ip},
			restate.WithIdempotencyKey(r.Header.Get("Idempotency-Key")))
		if err == nil {
			err = res.Refusal.Err()
		}
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, r, http.StatusOK, OTPSendResponse{ChallengeID: res.ChallengeID, ResendAfter: int(resendAfter.Seconds())})
	})
}
```

Create `internal/auth/restate.go`:

```go
package auth

import (
	"time"
	"uuid"

	restate "github.com/restatedev/sdk-go"
	"github.com/restatedev/sdk-go/ingress"
)

// restateTimeout bounds how long a handler waits for a service. The
// invocation goes on after a timeout, and the app's retry with the same
// Idempotency-Key picks up its result.
const restateTimeout = 15 * time.Second

// Restate is how handlers reach auth's Restate services.
type Restate struct {
	Client *ingress.Client
	Prefix string
}

func (r Restate) OTP() ingress.Requester[OTPSendInput, OTPSendResult] {
	return ingress.Service[OTPSendInput, OTPSendResult](r.Client, r.Prefix+"OTP", "Send")
}

// clock returns the time from a journaled step, so a replay sees the same time.
func clock(ctx restate.Context) (time.Time, error) {
	return restate.Run(ctx, func(restate.RunContext) (time.Time, error) { return time.Now(), nil })
}

// newID returns a journaled UUID: the same on every replay.
func newID(ctx restate.Context) uuid.UUID { return uuid.UUID(restate.UUID(ctx)) }
```

Create `internal/auth/otp_service.go`:

```go
package auth

import (
	"net/netip"
	"time"
	"uuid"

	restate "github.com/restatedev/sdk-go"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"

	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/contact"
	"github.com/shopnexus/server2/internal/provider/email"
	"github.com/shopnexus/server2/internal/provider/sms"
)

type OTPSendInput struct {
	Kind        contact.Kind `json:"kind"`
	Destination string       `json:"destination"` // normalised by the handler
	Purpose     otp.Purpose  `json:"purpose"`
	IP          netip.Addr   `json:"ip"`
}

type OTPSendResult struct {
	ChallengeID uuid.UUID `json:"challenge_id"`
	Refusal     *Refusal  `json:"refusal,omitempty"`
}

// OTP is the Restate service that sends codes. Every step is idempotent: the
// challenge ID is journaled and the code is derived from it.
type OTP struct {
	Prefix     string
	Quotas     otp.QuotaStore
	Challenges otp.ChallengeStore
	Codes      otp.Codes
	SMS        sms.Sender
	Email      email.Sender
}

func (s OTP) ServiceName() string { return s.Prefix + "OTP" }

func (s OTP) Send(ctx restate.Context, in OTPSendInput) (OTPSendResult, error) {
	dest := contact.Restore(in.Kind, in.Destination)
	at, err := clock(ctx)
	if err != nil {
		return OTPSendResult{}, err
	}
	refusal, err := restate.Run(ctx, func(rc restate.RunContext) (*Refusal, error) {
		return refuse(AdmitOTP(rc, s.Quotas, dest, in.IP, at))
	})
	if err != nil || refusal != nil {
		return OTPSendResult{Refusal: refusal}, err
	}
	c := NewChallenge(s.Codes, newID(ctx), in.Purpose, dest, in.IP, at)
	if err := restate.RunVoid(ctx, func(rc restate.RunContext) error { return s.Challenges.Create(rc, c) }); err != nil {
		return OTPSendResult{}, err
	}
	if err := restate.RunVoid(ctx, func(rc restate.RunContext) error {
		if err := SendCode(rc, s.SMS, s.Email, s.Codes, c, time.Now()); err != nil {
			return err
		}
		otpSent.Add(rc, 1, metric.WithAttributes(attribute.String("kind", string(dest.Kind()))))
		return nil
	}); err != nil {
		return OTPSendResult{}, err
	}
	return OTPSendResult{ChallengeID: c.ID()}, nil
}
```

Create `internal/auth/routes.go`:

```go
// Package auth proves who a person is: OTP sign-in, sessions and tokens. Use
// cases are functions in this package; otp, credentials and session hold the
// aggregates.
package auth

import (
	"log/slog"
	"net/netip"
	"time"

	restate "github.com/restatedev/sdk-go"

	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/httpx"
	"github.com/shopnexus/server2/internal/provider/email"
	"github.com/shopnexus/server2/internal/provider/sms"
)

// Ports holds the adapters auth's handlers and services use. Only Routes,
// Services and app.go read it.
type Ports struct {
	Accounts    AccountPort
	Challenges  otp.ChallengeStore
	Quotas      otp.QuotaStore
	Credentials credentials.Store
	Sessions    session.Store
	SMS         sms.Sender
	Email       email.Sender
}

// Keys holds what auth derives codes and signs tokens with.
type Keys struct {
	Codes    otp.Codes
	Signer   session.Signer
	Verifier session.Verifier
}

// Services returns auth's Restate services with prefixed names.
func Services(prefix string, p Ports, k Keys) []restate.ServiceDefinition {
	return []restate.ServiceDefinition{
		restate.Reflect(OTP{Prefix: prefix, Quotas: p.Quotas, Challenges: p.Challenges, Codes: k.Codes, SMS: p.SMS, Email: p.Email}),
	}
}

// Routes registers auth's HTTP handlers.
func Routes(r *httpx.Router, p Ports, k Keys, rs Restate, trusted []netip.Prefix, now func() time.Time, log *slog.Logger) {
	r.Handle("POST /v1/auth/otp", OTPSendHandler(rs, trusted, log))
}
```

Run: `go test -short ./internal/auth/`
Expected: PASS for the unit tests.

- [ ] **Step 4: Write and run the Restate integration tests**

Create `internal/auth/otp_service_test.go`:

```go
package auth_test

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	restate "github.com/restatedev/sdk-go"

	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/contact"
	"github.com/shopnexus/server2/internal/platform/pgtest"
	"github.com/shopnexus/server2/internal/platform/restatetest"
)

// commitThenFail commits a challenge and then reports a retryable error once,
// as when the process dies before Restate journals the step.
type commitThenFail struct {
	otp.ChallengeStore
	failed atomic.Bool
}

func (c *commitThenFail) Create(ctx context.Context, ch otp.Challenge) error {
	if err := c.ChallengeStore.Create(ctx, ch); err != nil {
		return err
	}
	if !c.failed.Swap(true) {
		return errors.New("connection reset after commit")
	}
	return nil
}

type otpEnv struct {
	rs  auth.Restate
	db  *pgxpool.Pool
	box *inbox
}

func startOTP(t *testing.T, wrap func(otp.ChallengeStore) otp.ChallengeStore) *otpEnv {
	t.Helper()
	db := pgtest.New(t)
	challenges := otp.NewChallengePGStore(db)
	if wrap != nil {
		challenges = wrap(challenges)
	}
	b := &inbox{}
	prefix := restatetest.Prefix()
	svc := auth.OTP{Prefix: prefix, Quotas: otp.NewQuotaPGStore(db), Challenges: challenges, Codes: codes(), SMS: b, Email: emailInbox{b}}
	client := restatetest.Start(t, restate.Reflect(svc))
	return &otpEnv{rs: auth.Restate{Client: client, Prefix: prefix}, db: db, box: b}
}

func (e *otpEnv) trySend(raw, ip, key string) (auth.OTPSendResult, error) {
	dest, _ := contact.ParsePhone(raw)
	return e.rs.OTP().Request(context.Background(),
		auth.OTPSendInput{Kind: dest.Kind(), Destination: dest.Value(), Purpose: otp.PurposeLogin, IP: netipOf(ip)},
		restate.WithIdempotencyKey(key))
}

func (e *otpEnv) send(t *testing.T, raw, ip, key string) auth.OTPSendResult {
	t.Helper()
	res, err := e.trySend(raw, ip, key)
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func (e *otpEnv) rows(t *testing.T) int {
	var n int
	e.db.QueryRow(context.Background(), `SELECT count(*) FROM otp_challenges`).Scan(&n)
	return n
}

func TestOTPServiceStoresAndSends(t *testing.T) {
	e := startOTP(t, nil)
	res := e.send(t, "0901234567", "203.0.113.7", uuid.NewV7().String())
	msgs := e.box.all()
	if res.Refusal != nil || e.rows(t) != 1 || len(msgs) != 1 || msgs[0].To != "+84901234567" ||
		!strings.Contains(msgs[0].Text, codes().For(res.ChallengeID)) {
		t.Fatalf("result %+v, rows %d, messages %+v", res, e.rows(t), msgs)
	}
}

func TestOTPServiceReplayedKey(t *testing.T) {
	e := startOTP(t, nil)
	key := uuid.NewV7().String()
	a := e.send(t, "0901234567", "203.0.113.7", key)
	b := e.send(t, "0901234567", "203.0.113.7", key)
	if a.ChallengeID != b.ChallengeID || e.rows(t) != 1 || len(e.box.all()) != 1 {
		t.Fatalf("a %+v, b %+v, rows %d, messages %d", a, b, e.rows(t), len(e.box.all()))
	}
}

func TestOTPServiceRefusesTooSoon(t *testing.T) {
	e := startOTP(t, nil)
	e.send(t, "0901234567", "203.0.113.7", uuid.NewV7().String())
	if res := e.send(t, "0901234567", "198.51.100.1", uuid.NewV7().String()); res.Refusal == nil || res.Refusal.Code != "otp_too_soon" {
		t.Fatalf("%+v", res)
	}
}

func TestOTPSendSurvivesCommitThenFail(t *testing.T) {
	e := startOTP(t, func(s otp.ChallengeStore) otp.ChallengeStore { return &commitThenFail{ChallengeStore: s} })
	res := e.send(t, "0901234567", "203.0.113.7", uuid.NewV7().String())
	if res.Refusal != nil || e.rows(t) != 1 || len(e.box.all()) != 1 {
		t.Fatalf("result %+v, rows %d, messages %d", res, e.rows(t), len(e.box.all()))
	}
}

// TestOTPSendCapsOneAddress is the SMS-pumping test: 40 parallel sends from
// one address to 40 numbers let at most 20 codes out.
func TestOTPSendCapsOneAddress(t *testing.T) {
	e := startOTP(t, nil)
	var wg sync.WaitGroup
	var sent, failed atomic.Int32
	for i := range 40 {
		wg.Go(func() {
			res, err := e.trySend(fmt.Sprintf("09%08d", i), "203.0.113.7", uuid.NewV7().String())
			switch {
			case err != nil:
				failed.Add(1)
			case res.Refusal == nil:
				sent.Add(1)
			}
		})
	}
	wg.Wait()
	if failed.Load() > 0 || sent.Load() > 20 || sent.Load() == 0 || len(e.box.all()) != int(sent.Load()) {
		t.Fatalf("sent %d, messages %d", sent.Load(), len(e.box.all()))
	}
}
```

Add to `helpers_test.go`: `func netipOf(s string) netip.Addr { return netip.MustParseAddr(s) }`.

Run: `go test -race -run 'TestOTP(Service|Send)' ./internal/auth/`
Expected: PASS. In the commit-then-fail test the logs show Restate retrying the step once.

- [ ] **Step 5: Wire the app**

In `internal/app/app.go`, after the `/readyz` route:

```go
	defs := a.routeModules(cfg, log)
	if err := a.startRestate(ctx, cfg, log, defs); err != nil {
		a.Close(context.Background())
		return nil, err
	}
```

and:

```go
// routeModules builds the modules' adapters, registers their routes and
// returns their Restate services.
func (a *App) routeModules(cfg config.Config, log *slog.Logger) []restate.ServiceDefinition {
	accounts := account.NewPGStore(a.pool)
	ports := auth.Ports{
		Accounts:    account.Client{Store: accounts, Now: time.Now},
		Challenges:  otp.NewChallengePGStore(a.pool),
		Quotas:      otp.NewQuotaPGStore(a.pool),
		Credentials: credentials.NewPGStore(a.pool),
		Sessions:    session.NewPGStore(a.pool),
		SMS:         a.opts.sms,
		Email:       a.opts.email,
	}
	keys := auth.Keys{
		Codes:    otp.NewCodes(cfg.Auth.OTPKey),
		Signer:   session.NewSigner(cfg.Auth),
		Verifier: session.NewVerifier(cfg.Auth),
	}
	rs := auth.Restate{Client: a.ingress, Prefix: a.opts.restatePrefix}
	auth.Routes(a.router, ports, keys, rs, cfg.TrustedProxies, time.Now, log)
	return auth.Services(a.opts.restatePrefix, ports, keys)
}
```

- [ ] **Step 6: Build the E2E harness and tests**

In `e2e/main_test.go` add the package variable `box = newInbox()` and pass `app.WithSMSSender(box.sms())` and `app.WithEmailSender(box.email())` to `app.New`.

Create `e2e/inbox_test.go`:

```go
package e2e

import (
	"context"
	"regexp"
	"sync"
	"testing"

	"github.com/shopnexus/server2/internal/provider/email"
	"github.com/shopnexus/server2/internal/provider/sms"
)

// inbox keeps every message the server sends. The send step finishes before
// the OTP request answers, so a test reads its code right after the call.
type inbox struct {
	mu   sync.Mutex
	msgs map[string][]string // destination → texts, oldest first
}

func newInbox() *inbox { return &inbox{msgs: map[string][]string{}} }

type smsInbox struct{ *inbox }

func (b smsInbox) Send(_ context.Context, to, text string) error { b.add(to, text); return nil }

type emailInbox struct{ *inbox }

func (b emailInbox) Send(_ context.Context, to, _, body string) error { b.add(to, body); return nil }

func (b *inbox) sms() sms.Sender     { return smsInbox{b} }
func (b *inbox) email() email.Sender { return emailInbox{b} }

func (b *inbox) add(to, text string) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.msgs[to] = append(b.msgs[to], text)
}

func (b *inbox) count(to string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	return len(b.msgs[to])
}

var codeIn = regexp.MustCompile(`\b[0-9]{6}\b`)

// code returns the code in the nth message to "to", counting from 1.
func (b *inbox) code(t *testing.T, to string, nth int) string {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.msgs[to]) < nth {
		t.Fatalf("%s got %d messages, want at least %d", to, len(b.msgs[to]), nth)
	}
	return codeIn.FindString(b.msgs[to][nth-1])
}
```

Create `e2e/auth_helpers_test.go`:

```go
package e2e

import (
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"testing"
	"uuid"
)

// newPhone returns a fresh mobile number, so tests never share a
// destination's quota.
func newPhone() string { return fmt.Sprintf("+849%08d", rand.IntN(100_000_000)) }

func newEmail() string { return fmt.Sprintf("e2e-%d@example.com", rand.Int64()) }

// newIP returns an X-Forwarded-For header with a fresh address, so tests
// never share an address's quota.
func newIP() [2]string {
	return [2]string{"X-Forwarded-For", fmt.Sprintf("198.18.%d.%d", rand.IntN(256), rand.IntN(256))}
}

// newKey returns a fresh Idempotency-Key header.
func newKey() [2]string { return [2]string{"Idempotency-Key", uuid.NewV7().String()} }

func decode[T any](t *testing.T, res Response) T {
	t.Helper()
	var v T
	if err := json.Unmarshal(res.Body, &v); err != nil {
		t.Fatalf("decode %s: %v", res.Body, err)
	}
	return v
}

type apiError struct {
	Code    string            `json:"code"`
	Fields  map[string]string `json:"fields"`
	Details map[string]any    `json:"details"`
}

func errorOf(t *testing.T, res Response) apiError {
	t.Helper()
	return decode[struct {
		Error apiError `json:"error"`
	}](t, res).Error
}

type challenge struct {
	ChallengeID string `json:"challenge_id"`
	ResendAfter int    `json:"resend_after"`
}

// sendOTP sends with a fresh address and key unless headers override them.
func sendOTP(t *testing.T, kind, dest string, headers ...[2]string) Response {
	t.Helper()
	return call(t, server, "POST", "/v1/auth/otp",
		map[string]string{"kind": kind, "destination": dest, "purpose": "login"},
		append([][2]string{newIP(), newKey()}, headers...)...)
}
```

`call` sets headers in order, so a later header with the same name overrides an earlier one.

Create `e2e/auth_otp_test.go`:

```go
package e2e

import "testing"

func TestOTPSendDeliversACode(t *testing.T) {
	phone := newPhone()
	res := sendOTP(t, "phone", phone)
	if c := decode[challenge](t, res); res.Status != 200 || c.ChallengeID == "" || c.ResendAfter != 45 {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
	if box.code(t, phone, 1) == "" {
		t.Fatal("the message carries no code")
	}
}

func TestOTPSendEmail(t *testing.T) {
	addr := newEmail()
	if res := sendOTP(t, "email", addr); res.Status != 200 {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
	box.code(t, addr, 1)
}

func TestOTPSendTooSoon(t *testing.T) {
	phone := newPhone()
	sendOTP(t, "phone", phone)
	res := sendOTP(t, "phone", phone)
	if e := errorOf(t, res); res.Status != 429 || e.Code != "otp_too_soon" || e.Details["retry_after"] == nil {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
}

func TestOTPSendLimitPerAddress(t *testing.T) {
	ip := newIP()
	for i := range 20 {
		if res := sendOTP(t, "phone", newPhone(), ip); res.Status != 200 {
			t.Fatalf("send %d: %d %s", i+1, res.Status, res.Body)
		}
	}
	if res := sendOTP(t, "phone", newPhone(), ip); res.Status != 429 || errorOf(t, res).Code != "otp_limit" {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
}

func TestOTPSendRejectsALandline(t *testing.T) {
	if res := sendOTP(t, "phone", "0201234567"); res.Status != 422 || errorOf(t, res).Code != "invalid_phone" {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
}

func TestOTPSendRejectsBadRequests(t *testing.T) {
	res := call(t, server, "POST", "/v1/auth/otp",
		map[string]string{"kind": "phone", "destination": newPhone(), "purpose": "add_identity"}, newIP(), newKey())
	if e := errorOf(t, res); res.Status != 400 || e.Fields["purpose"] == "" {
		t.Fatalf("unknown purpose: %d %s", res.Status, res.Body)
	}
	res = call(t, server, "POST", "/v1/auth/otp",
		map[string]string{"kind": "phone", "destination": newPhone(), "purpose": "login"}, newIP())
	if e := errorOf(t, res); res.Status != 400 || e.Fields["Idempotency-Key"] == "" {
		t.Fatalf("no Idempotency-Key: %d %s", res.Status, res.Body)
	}
}
```

- [ ] **Step 7: Run and commit**

Run: `make lint && make test`
Expected: PASS, `TestRoutesMatchSpec` included, `sendOtp` 200, 400, 422, 429 observed.

```bash
git add -A
git commit -m "feat(auth): send OTP codes through a Restate service with quotas and idempotency keys"
```

### Task 9: `POST /v1/auth/otp/verify` through Restate service `SignIn`

**Files:**
- Modify: `api/openapi.yaml`, `api/paths/auth.yaml`, `api/schemas/auth.yaml`
- Create: `internal/auth/sign_in.go`, `sign_in_service.go`, `session_issue.go`
- Create: `internal/auth/sign_in_test.go`, `sign_in_pg_test.go`, `sign_in_service_test.go`, `session_issue_test.go`
- Modify: `internal/auth/restate.go`, `routes.go`, `helpers_test.go`
- Modify: `e2e/auth_helpers_test.go`, `e2e/auth_otp_test.go`

**Interfaces:**
- Consumes: `otp.ChallengeStore`, `otp.Codes`, `credentials.Store`, `credentials.New`, `credentials.NewIdentity`, `session.Store`, `session.Signer`, `AccountPort`, `account.StatusSuspended`, `account.ErrSuspended`
- Produces: `auth.VerifyChallenge(ctx, challenges otp.ChallengeStore, id uuid.UUID, codeHash []byte, now time.Time, writeID uuid.UUID) (contact.Address, error)`
- Produces: `auth.SignInExisting(ctx, accounts AccountPort, creds credentials.Store, accountID, identityID uuid.UUID, now time.Time, writeID uuid.UUID) error`
- Produces: `auth.IssueSession(ctx, sessions session.Store, signer session.Signer, id, accountID uuid.UUID, deviceName string, now time.Time) (session.Tokens, error)`
- Produces: `auth.SignIn` (Restate service, handler `Run`), `auth.SignInInput{ChallengeID uuid.UUID; CodeHash []byte}`, `auth.SignInResult{AccountID uuid.UUID; IsNew bool; SessionID uuid.UUID; Refusal *Refusal}`, `(Restate).SignIn() ingress.Requester[SignInInput, SignInResult]`, `auth.SignInHandler(rs Restate, challenges otp.ChallengeStore, codes otp.Codes, sessions session.Store, signer session.Signer, now func() time.Time, log) http.Handler`
- Produces (E2E): `signIn` type, `requestCode(t, typed string) (challengeID, code string)`, `verifyCode(t, challengeID, code string, headers ...[2]string) Response`, `signInWith(t, typed string) signIn`, `newAccount(t) (signIn, string)`, `bearer(token string) [2]string`, `wrongCode(code string) string`

- [ ] **Step 1: Write the OpenAPI operation**

Append to `api/schemas/auth.yaml`:

```yaml
OTPVerifyRequest:
  type: object
  additionalProperties: false
  required: [challenge_id, code]
  properties:
    challenge_id:
      type: string
      format: uuid
    code:
      type: string
      pattern: "^[0-9]{6}$"
    device_name:
      type: string
      maxLength: 100
      description: Shown in the list of signed-in devices.
Tokens:
  type: object
  additionalProperties: false
  required: [access_token, access_token_expires_at, refresh_token, token_type]
  properties:
    access_token:
      type: string
    access_token_expires_at:
      type: string
      format: date-time
    refresh_token:
      type: string
    token_type:
      type: string
      enum: [Bearer]
SignIn:
  type: object
  additionalProperties: false
  required: [access_token, access_token_expires_at, refresh_token, token_type, account]
  properties:
    access_token:
      type: string
    access_token_expires_at:
      type: string
      format: date-time
    refresh_token:
      type: string
    token_type:
      type: string
      enum: [Bearer]
    account:
      type: object
      additionalProperties: false
      required: [id, is_new]
      properties:
        id:
          type: string
          format: uuid
        is_new:
          type: boolean
          description: True when this sign-in created the account; the app then asks for a profile.
```

Append to `api/paths/auth.yaml`:

```yaml
otpVerify:
  post:
    operationId: verifyOtp
    summary: Sign in, or sign up on first use, with a code.
    tags: [auth]
    parameters:
      - $ref: "../parameters/common.yaml#/IdempotencyKey"
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/auth.yaml#/OTPVerifyRequest"
    responses:
      "200":
        description: Signed in.
        content:
          application/json:
            schema:
              $ref: "../schemas/auth.yaml#/SignIn"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "403":
        $ref: "../responses/common.yaml#/Forbidden"
      "409":
        $ref: "../responses/common.yaml#/Conflict"
      "422":
        description: invalid_code (details.attempts_left), code_expired or code_locked.
        content:
          application/json:
            schema:
              $ref: "../schemas/error.yaml#/Error"
```

In `api/openapi.yaml`:

```yaml
  /v1/auth/otp/verify:
    $ref: "paths/auth.yaml#/otpVerify"
```

- [ ] **Step 2: Write the failing unit tests**

Append to `internal/auth/helpers_test.go` (imports `account`, `uuid`, `postgres`-free):

```go
// fakeAccounts stands in for module account behind AccountPort.
type fakeAccounts struct {
	mu     sync.Mutex
	status map[uuid.UUID]account.Status
}

func newFakeAccounts() *fakeAccounts { return &fakeAccounts{status: map[uuid.UUID]account.Status{}} }

func (f *fakeAccounts) Create(_ context.Context, id uuid.UUID, _ string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	if _, ok := f.status[id]; !ok {
		f.status[id] = account.StatusActive
	}
	return nil
}

func (f *fakeAccounts) Delete(_ context.Context, id uuid.UUID) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	delete(f.status, id)
	return nil
}

func (f *fakeAccounts) Status(_ context.Context, id uuid.UUID) (account.Status, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	st, ok := f.status[id]
	if !ok {
		return "", account.ErrNotFound
	}
	return st, nil
}

func (f *fakeAccounts) suspend(id uuid.UUID) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.status[id] = account.StatusSuspended
}

func (f *fakeAccounts) len() int {
	f.mu.Lock()
	defer f.mu.Unlock()
	return len(f.status)
}
```

Create `internal/auth/sign_in_test.go`:

```go
package auth_test

import (
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/auth/credentials/credentialstest"
	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/auth/otp/otptest"
)

// stored creates a login challenge in s and returns it with its code.
func stored(t *testing.T, s otp.ChallengeStore, raw string, at time.Time) (otp.Challenge, string) {
	t.Helper()
	c := auth.NewChallenge(codes(), uuid.NewV7(), otp.PurposeLogin, phone(t, raw), clientIP, at)
	if err := s.Create(context.Background(), c); err != nil {
		t.Fatal(err)
	}
	return c, codes().For(c.ID())
}

func hashOf(c otp.Challenge, code string) []byte { return codes().Hash(c.Destination(), code) }

func TestVerifyChallengeRightCode(t *testing.T) {
	s := otptest.NewChallenges()
	c, code := stored(t, s, "0901234567", now)
	dest, err := auth.VerifyChallenge(context.Background(), s, c.ID(), hashOf(c, code), now, uuid.NewV7())
	if err != nil || dest.Value() != "+84901234567" {
		t.Fatalf("%v %v", dest, err)
	}
	if _, err := auth.VerifyChallenge(context.Background(), s, c.ID(), hashOf(c, code), now, uuid.NewV7()); !errors.Is(err, otp.ErrCodeExpired) {
		t.Fatalf("second use: %v", err)
	}
}

func TestVerifyChallengeWrongCodeIsSaved(t *testing.T) {
	s := otptest.NewChallenges()
	c, _ := stored(t, s, "0901234567", now)
	if _, err := auth.VerifyChallenge(context.Background(), s, c.ID(), hashOf(c, "000000"), now, uuid.NewV7()); !errors.Is(err, otp.ErrInvalidCode) {
		t.Fatalf("err %v", err)
	}
	if got, _ := s.Get(context.Background(), c.ID()); got.Attempts() != 1 {
		t.Fatalf("attempts %d", got.Attempts())
	}
}

func TestVerifyChallengeRefusals(t *testing.T) {
	s := otptest.NewChallenges()
	old, oldCode := stored(t, s, "0901234567", now)
	stored(t, s, "0901234567", now.Add(time.Minute))
	ctx := context.Background()
	if _, err := auth.VerifyChallenge(ctx, s, old.ID(), hashOf(old, oldCode), now, uuid.NewV7()); !errors.Is(err, otp.ErrCodeExpired) {
		t.Fatalf("replaced: %v", err)
	}
	if _, err := auth.VerifyChallenge(ctx, s, uuid.NewV7(), []byte("x"), now, uuid.NewV7()); !errors.Is(err, otp.ErrCodeExpired) {
		t.Fatalf("unknown: %v", err)
	}
	c, code := stored(t, s, "0907654321", now)
	if _, err := auth.VerifyChallenge(ctx, s, c.ID(), hashOf(c, code), now.Add(otp.CodeTTL), uuid.NewV7()); !errors.Is(err, otp.ErrCodeExpired) {
		t.Fatalf("expired: %v", err)
	}
}

// racing is a challenge store whose Save always loses.
type racing struct{ otp.ChallengeStore }

func (racing) Save(context.Context, *otp.Challenge, uuid.UUID) error { return otp.ErrConflict }

func TestVerifyChallengeConflictSaysTryAgainForAnyCode(t *testing.T) {
	s := otptest.NewChallenges()
	c, code := stored(t, s, "0901234567", now)
	for _, guess := range []string{code, "000000"} {
		if _, err := auth.VerifyChallenge(context.Background(), racing{s}, c.ID(), hashOf(c, guess), now, uuid.NewV7()); !errors.Is(err, auth.ErrTryAgain) {
			t.Fatalf("guess %s: %v", guess, err)
		}
	}
}

func TestSignInExisting(t *testing.T) {
	ctx := context.Background()
	accounts, creds := newFakeAccounts(), credentialstest.NewMemStore()
	acc, identID := uuid.NewV7(), uuid.NewV7()
	accounts.Create(ctx, acc, "")
	creds.Create(ctx, credentials.New(acc, credentials.NewIdentity(identID, phone(t, "0901234567"), now), now))

	if err := auth.SignInExisting(ctx, accounts, creds, acc, identID, now.Add(time.Hour), uuid.NewV7()); err != nil {
		t.Fatal(err)
	}
	if c, _ := creds.Get(ctx, acc); !c.Identities()[0].LastUsedAt().Equal(now.Add(time.Hour)) {
		t.Fatalf("last used %v", c.Identities()[0].LastUsedAt())
	}
	accounts.suspend(acc)
	if err := auth.SignInExisting(ctx, accounts, creds, acc, identID, now, uuid.NewV7()); !errors.Is(err, account.ErrSuspended) {
		t.Fatalf("suspended: %v", err)
	}
}
```

Create `internal/auth/session_issue_test.go`:

```go
package auth_test

import (
	"context"
	"testing"
	"uuid"

	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/auth/session/sessiontest"
)

func TestIssueSessionCreatesThenRotates(t *testing.T) {
	ctx, sessions, signer := context.Background(), sessiontest.NewMemStore(), session.NewSigner(testKeys)
	id, acc := uuid.NewV7(), uuid.NewV7()
	first, err := auth.IssueSession(ctx, sessions, signer, id, acc, "Pixel 9", now)
	if err != nil {
		t.Fatal(err)
	}
	p, err := session.NewVerifier(testKeys).Verify(first.AccessToken, now)
	if err != nil || p.SessionID != id || p.AccountID != acc || !p.AuthTime.Equal(now) || first.TokenType != "Bearer" {
		t.Fatalf("%+v %v", p, err)
	}
	again, err := auth.IssueSession(ctx, sessions, signer, id, acc, "Pixel 9", now)
	if err != nil || again.RefreshToken == first.RefreshToken {
		t.Fatalf("replay: %+v %v", again, err)
	}
	if s, err := sessions.FindByRefresh(ctx, session.HashRefresh(again.RefreshToken)); err != nil || s.ID() != id {
		t.Fatalf("the replay's token does not refresh: %v", err)
	}
}
```

Run: `go test -short ./internal/auth/`
Expected: build failure naming `VerifyChallenge`, `SignInExisting`, `IssueSession`.

- [ ] **Step 3: Implement the functions**

Create `internal/auth/sign_in.go`:

```go
package auth

import (
	"context"
	"errors"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/contact"
)

// VerifyChallenge checks a code hash against a login challenge and saves the
// attempt before it answers, so a wrong code stays counted. A write that loses
// a race returns ErrTryAgain whether the code was right or wrong, and that
// attempt is not counted.
func VerifyChallenge(ctx context.Context, challenges otp.ChallengeStore, id uuid.UUID, codeHash []byte, now time.Time, writeID uuid.UUID) (contact.Address, error) {
	c, err := challenges.Get(ctx, id)
	if errors.Is(err, otp.ErrNotFound) {
		return contact.Address{}, otp.ErrCodeExpired
	}
	if err != nil {
		return contact.Address{}, err
	}
	if c.Purpose() != otp.PurposeLogin {
		return contact.Address{}, otp.ErrCodeExpired
	}
	newest, err := challenges.IsNewest(ctx, c)
	if err != nil {
		return contact.Address{}, err
	}
	if !newest {
		return contact.Address{}, otp.ErrCodeExpired
	}
	verifyErr := c.Verify(codeHash, now)
	if err := challenges.Save(ctx, &c, writeID); err != nil {
		if errors.Is(err, otp.ErrConflict) {
			return contact.Address{}, ErrTryAgain
		}
		return contact.Address{}, err
	}
	return c.Destination(), verifyErr
}

// SignInExisting lets an existing account in: it refuses a suspended account
// and records the identity's use. Only a person who just proved they hold the
// identity gets here, so account_suspended is safe to reveal.
func SignInExisting(ctx context.Context, accounts AccountPort, creds credentials.Store, accountID, identityID uuid.UUID, now time.Time, writeID uuid.UUID) error {
	st, err := accounts.Status(ctx, accountID)
	if err != nil {
		return err
	}
	if st == account.StatusSuspended {
		return account.ErrSuspended
	}
	c, err := creds.Get(ctx, accountID)
	if err != nil {
		return err
	}
	if err := c.MarkUsed(identityID, now); err != nil {
		return err
	}
	// last_used_at is a hint for the dormant check; losing it to a concurrent
	// sign-in of the same account costs nothing.
	if err := creds.Save(ctx, &c, writeID); err != nil && !errors.Is(err, credentials.ErrConflict) {
		return err
	}
	return nil
}
```

Create `internal/auth/session_issue.go`:

```go
package auth

import (
	"context"
	"errors"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/session"
)

// IssueSession starts session id and signs its first access token. When the
// session exists already, because the client replayed an Idempotency-Key, it
// rotates the refresh token instead, so the replay also gets working tokens.
func IssueSession(ctx context.Context, sessions session.Store, signer session.Signer, id, accountID uuid.UUID, deviceName string, now time.Time) (session.Tokens, error) {
	s, refresh := session.New(id, accountID, deviceName, now, now)
	created, err := sessions.Create(ctx, s)
	if err != nil {
		return session.Tokens{}, err
	}
	if !created {
		if s, err = sessions.Get(ctx, id); err != nil {
			return session.Tokens{}, err
		}
		if s.AccountID() != accountID {
			return session.Tokens{}, errors.New("issue session: id belongs to another account")
		}
		refresh = s.Rotate(now)
		if err := sessions.Save(ctx, &s, uuid.NewV7()); err != nil {
			if errors.Is(err, session.ErrConflict) {
				return session.Tokens{}, ErrTryAgain
			}
			return session.Tokens{}, err
		}
	}
	access, exp, err := signer.Sign(accountID, id, s.AuthTime(), now)
	if err != nil {
		return session.Tokens{}, err
	}
	return session.Tokens{AccessToken: access, AccessTokenExpiresAt: exp, RefreshToken: refresh, TokenType: "Bearer"}, nil
}
```

Run: `go test -short ./internal/auth/`
Expected: PASS.

- [ ] **Step 4: Write the Postgres race test**

Create `internal/auth/sign_in_pg_test.go`:

```go
package auth_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"uuid"

	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/pgtest"
)

// TestVerifyChallengeUnderParallelGuesses is the spec's 50-parallel-guesses
// attack: whatever the interleaving, no guess succeeds, at most five are
// counted, and every reply is invalid_code, code_locked or try_again.
func TestVerifyChallengeUnderParallelGuesses(t *testing.T) {
	ctx := context.Background()
	db := pgtest.New(t)
	s := otp.NewChallengePGStore(db)
	c, code := stored(t, s, "0901234567", now)
	wrong := hashOf(c, "000000")
	if code == "000000" {
		wrong = hashOf(c, "000001")
	}

	errs := make(chan error, 50)
	var wg sync.WaitGroup
	for range 50 {
		wg.Go(func() {
			_, err := auth.VerifyChallenge(ctx, s, c.ID(), wrong, now, uuid.NewV7())
			errs <- err
		})
	}
	wg.Wait()
	close(errs)
	invalid := 0
	for err := range errs {
		switch {
		case errors.Is(err, otp.ErrInvalidCode):
			invalid++
		case errors.Is(err, otp.ErrCodeLocked), errors.Is(err, auth.ErrTryAgain):
		default:
			t.Fatalf("unexpected %v", err)
		}
	}
	got, _ := s.Get(ctx, c.ID())
	if invalid > otp.MaxAttempts-1 || got.Attempts() > otp.MaxAttempts || got.ConsumedAt() != nil {
		t.Fatalf("invalid replies %d, attempts %d, consumed %v", invalid, got.Attempts(), got.ConsumedAt())
	}
}
```

Run: `go test -race -run TestVerifyChallengeUnderParallelGuesses ./internal/auth/`
Expected: PASS.

- [ ] **Step 5: Write the service, its handler and the integration tests**

Create `internal/auth/sign_in_service.go`:

```go
package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	restate "github.com/restatedev/sdk-go"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/metric"

	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/contact"
	"github.com/shopnexus/server2/internal/platform/httpx"
)

// SignInInput carries the code's HMAC, never the code, because Restate keeps
// inputs in its journal.
type SignInInput struct {
	ChallengeID uuid.UUID `json:"challenge_id"`
	CodeHash    []byte    `json:"code_hash"`
}

// SignInResult names the account and the session the handler issues tokens
// for. Tokens never enter Restate.
type SignInResult struct {
	AccountID uuid.UUID `json:"account_id"`
	IsNew     bool      `json:"is_new"`
	SessionID uuid.UUID `json:"session_id"`
	Refusal   *Refusal  `json:"refusal,omitempty"`
}

// SignIn verifies a code and finds or creates the account. Creating one is a
// saga: Account, then Credentials, and the account is deleted when the
// credentials cannot be created.
type SignIn struct {
	Prefix      string
	Challenges  otp.ChallengeStore
	Credentials credentials.Store
	Accounts    AccountPort
}

func (s SignIn) ServiceName() string { return s.Prefix + "SignIn" }

type verified struct {
	Kind    contact.Kind `json:"kind"`
	Value   string       `json:"value"`
	Refusal *Refusal     `json:"refusal,omitempty"`
}

type holder struct {
	AccountID  uuid.UUID `json:"account_id"`
	IdentityID uuid.UUID `json:"identity_id"`
	Found      bool      `json:"found"`
}

func (s SignIn) Run(ctx restate.Context, in SignInInput) (SignInResult, error) {
	at, err := clock(ctx)
	if err != nil {
		return SignInResult{}, err
	}
	verifyWrite := newID(ctx)
	v, err := restate.Run(ctx, func(rc restate.RunContext) (verified, error) {
		dest, err := VerifyChallenge(rc, s.Challenges, in.ChallengeID, in.CodeHash, at, verifyWrite)
		r, err := refuse(err)
		return verified{Kind: dest.Kind(), Value: dest.Value(), Refusal: r}, err
	})
	if err != nil || v.Refusal != nil {
		return SignInResult{Refusal: v.Refusal}, err
	}
	dest := contact.Restore(v.Kind, v.Value)

	h, err := restate.Run(ctx, func(rc restate.RunContext) (holder, error) {
		acc, ident, err := s.Credentials.FindAccount(rc, credentials.KindOf(dest), dest.Value())
		if errors.Is(err, credentials.ErrNotFound) {
			return holder{}, nil
		}
		return holder{AccountID: acc, IdentityID: ident, Found: err == nil}, err
	})
	if err != nil {
		return SignInResult{}, err
	}
	sessionID := newID(ctx)

	if h.Found {
		markWrite := newID(ctx)
		refusal, err := restate.Run(ctx, func(rc restate.RunContext) (*Refusal, error) {
			return refuse(SignInExisting(rc, s.Accounts, s.Credentials, h.AccountID, h.IdentityID, at, markWrite))
		})
		if err != nil || refusal != nil {
			return SignInResult{Refusal: refusal}, err
		}
		return SignInResult{AccountID: h.AccountID, SessionID: sessionID}, nil
	}

	accountID, identityID := newID(ctx), newID(ctx)
	if err := restate.RunVoid(ctx, func(rc restate.RunContext) error { return s.Accounts.Create(rc, accountID, "") }); err != nil {
		return SignInResult{}, err
	}
	refusal, err := restate.Run(ctx, func(rc restate.RunContext) (*Refusal, error) {
		c := credentials.New(accountID, credentials.NewIdentity(identityID, dest, at), at)
		return refuse(s.Credentials.Create(rc, c))
	})
	if err != nil {
		return SignInResult{}, err
	}
	if refusal != nil {
		// Another sign-up took the identity between the lookup and the
		// insert: undo the account and let the client try again.
		if err := restate.RunVoid(ctx, func(rc restate.RunContext) error { return s.Accounts.Delete(rc, accountID) }); err != nil {
			return SignInResult{}, err
		}
		r, _ := refuse(ErrTryAgain)
		return SignInResult{Refusal: r}, nil
	}
	return SignInResult{AccountID: accountID, IsNew: true, SessionID: sessionID}, nil
}

type SignInRequest struct {
	ChallengeID uuid.UUID `json:"challenge_id"`
	Code        string    `json:"code"`
	DeviceName  string    `json:"device_name"`
}

type SignedInAccount struct {
	ID    uuid.UUID `json:"id"`
	IsNew bool      `json:"is_new"`
}

type SignInResponse struct {
	session.Tokens
	Account SignedInAccount `json:"account"`
}

// POST /v1/auth/otp/verify
func SignInHandler(rs Restate, challenges otp.ChallengeStore, codes otp.Codes, sessions session.Store, signer session.Signer, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		res, err := signIn(r, rs, challenges, codes, sessions, signer, now)
		result := "success"
		if err != nil {
			result = "failure"
		}
		logins.Add(r.Context(), 1, metric.WithAttributes(attribute.String("method", "otp"), attribute.String("result", result)))
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, r, http.StatusOK, res)
	})
}

func signIn(r *http.Request, rs Restate, challenges otp.ChallengeStore, codes otp.Codes, sessions session.Store, signer session.Signer, now func() time.Time) (SignInResponse, error) {
	in, err := httpx.Decode[SignInRequest](r)
	if err != nil {
		return SignInResponse{}, err
	}
	c, err := challenges.Get(r.Context(), in.ChallengeID)
	if errors.Is(err, otp.ErrNotFound) {
		return SignInResponse{}, otp.ErrCodeExpired
	}
	if err != nil {
		return SignInResponse{}, err
	}
	ctx, cancel := context.WithTimeout(r.Context(), restateTimeout)
	defer cancel()
	res, err := rs.SignIn().Request(ctx, SignInInput{ChallengeID: in.ChallengeID, CodeHash: codes.Hash(c.Destination(), in.Code)},
		restate.WithIdempotencyKey(r.Header.Get("Idempotency-Key")))
	if err == nil {
		err = res.Refusal.Err()
	}
	if err != nil {
		return SignInResponse{}, err
	}
	tokens, err := IssueSession(r.Context(), sessions, signer, res.SessionID, res.AccountID, in.DeviceName, now())
	if err != nil {
		return SignInResponse{}, err
	}
	return SignInResponse{Tokens: tokens, Account: SignedInAccount{ID: res.AccountID, IsNew: res.IsNew}}, nil
}
```

In `internal/auth/restate.go` add:

```go
func (r Restate) SignIn() ingress.Requester[SignInInput, SignInResult] {
	return ingress.Service[SignInInput, SignInResult](r.Client, r.Prefix+"SignIn", "Run")
}
```

In `internal/auth/routes.go`, `Services` appends
`restate.Reflect(SignIn{Prefix: prefix, Challenges: p.Challenges, Credentials: p.Credentials, Accounts: p.Accounts})`, and `Routes` adds
`r.Handle("POST /v1/auth/otp/verify", SignInHandler(rs, p.Challenges, k.Codes, p.Sessions, k.Signer, now, log))`.

Create `internal/auth/sign_in_service_test.go`:

```go
package auth_test

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"
	"uuid"

	"github.com/jackc/pgx/v5/pgxpool"
	restate "github.com/restatedev/sdk-go"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/credentials"
	"github.com/shopnexus/server2/internal/auth/otp"
	"github.com/shopnexus/server2/internal/platform/pgtest"
	"github.com/shopnexus/server2/internal/platform/restatetest"
)

type signInEnv struct {
	rs         auth.Restate
	db         *pgxpool.Pool
	challenges otp.ChallengeStore
}

// creatingThenFailing commits an account and then reports a retryable error
// once.
type creatingThenFailing struct {
	auth.AccountPort
	failed atomic.Bool
}

func (c *creatingThenFailing) Create(ctx context.Context, id uuid.UUID, name string) error {
	if err := c.AccountPort.Create(ctx, id, name); err != nil {
		return err
	}
	if !c.failed.Swap(true) {
		return errors.New("connection reset after commit")
	}
	return nil
}

// takenCredentials refuses every new identity.
type takenCredentials struct{ credentials.Store }

func (takenCredentials) Create(context.Context, credentials.Credentials) error { return credentials.ErrTaken }

func startSignIn(t *testing.T, wrapAccounts func(auth.AccountPort) auth.AccountPort, wrapCreds func(credentials.Store) credentials.Store) *signInEnv {
	t.Helper()
	db := pgtest.New(t)
	var accounts auth.AccountPort = account.Client{Store: account.NewPGStore(db), Now: func() time.Time { return time.Now() }}
	if wrapAccounts != nil {
		accounts = wrapAccounts(accounts)
	}
	var creds credentials.Store = credentials.NewPGStore(db)
	if wrapCreds != nil {
		creds = wrapCreds(creds)
	}
	challenges := otp.NewChallengePGStore(db)
	prefix := restatetest.Prefix()
	client := restatetest.Start(t, restate.Reflect(auth.SignIn{Prefix: prefix, Challenges: challenges, Credentials: creds, Accounts: accounts}))
	return &signInEnv{rs: auth.Restate{Client: client, Prefix: prefix}, db: db, challenges: challenges}
}

func (e *signInEnv) run(t *testing.T, raw, key string) auth.SignInResult {
	t.Helper()
	c, code := stored(t, e.challenges, raw, time.Now())
	res, err := e.rs.SignIn().Request(context.Background(), auth.SignInInput{ChallengeID: c.ID(), CodeHash: hashOf(c, code)},
		restate.WithIdempotencyKey(key))
	if err != nil {
		t.Fatal(err)
	}
	return res
}

func (e *signInEnv) count(t *testing.T, table string) int {
	var n int
	e.db.QueryRow(context.Background(), `SELECT count(*) FROM `+table).Scan(&n)
	return n
}

func TestSignInCreatesThenFindsTheAccount(t *testing.T) {
	e := startSignIn(t, nil, nil)
	first := e.run(t, "0901234567", uuid.NewV7().String())
	second := e.run(t, "+84 90 123 4567", uuid.NewV7().String())
	if first.Refusal != nil || !first.IsNew || second.Refusal != nil || second.IsNew || second.AccountID != first.AccountID ||
		first.SessionID == second.SessionID || e.count(t, "accounts") != 1 || e.count(t, "identities") != 1 {
		t.Fatalf("first %+v, second %+v", first, second)
	}
}

func TestSignInReplayedKey(t *testing.T) {
	e := startSignIn(t, nil, nil)
	c, code := stored(t, e.challenges, "0901234567", time.Now())
	key := uuid.NewV7().String()
	in := auth.SignInInput{ChallengeID: c.ID(), CodeHash: hashOf(c, code)}
	a, err1 := e.rs.SignIn().Request(context.Background(), in, restate.WithIdempotencyKey(key))
	b, err2 := e.rs.SignIn().Request(context.Background(), in, restate.WithIdempotencyKey(key))
	if err1 != nil || err2 != nil || a != b || e.count(t, "accounts") != 1 {
		t.Fatalf("a %+v %v, b %+v %v", a, err1, b, err2)
	}
}

func TestSignInSurvivesCommitThenFail(t *testing.T) {
	e := startSignIn(t, func(p auth.AccountPort) auth.AccountPort { return &creatingThenFailing{AccountPort: p} }, nil)
	res := e.run(t, "0901234567", uuid.NewV7().String())
	if res.Refusal != nil || !res.IsNew || e.count(t, "accounts") != 1 || e.count(t, "credentials") != 1 {
		t.Fatalf("%+v, accounts %d", res, e.count(t, "accounts"))
	}
}

func TestSignInCompensatesWhenTheIdentityIsTaken(t *testing.T) {
	e := startSignIn(t, nil, func(s credentials.Store) credentials.Store { return takenCredentials{s} })
	res := e.run(t, "0901234567", uuid.NewV7().String())
	if res.Refusal == nil || res.Refusal.Code != "try_again" || e.count(t, "accounts") != 0 {
		t.Fatalf("%+v, accounts %d", res, e.count(t, "accounts"))
	}
}

func TestSignInWrongCodeIsRefused(t *testing.T) {
	e := startSignIn(t, nil, nil)
	c, _ := stored(t, e.challenges, "0901234567", time.Now())
	res, err := e.rs.SignIn().Request(context.Background(), auth.SignInInput{ChallengeID: c.ID(), CodeHash: []byte("nope")},
		restate.WithIdempotencyKey(uuid.NewV7().String()))
	if err != nil || res.Refusal == nil || res.Refusal.Code != "invalid_code" || res.Refusal.Details["attempts_left"] != float64(4) {
		t.Fatalf("%+v %v", res, err)
	}
	if got, _ := e.challenges.Get(context.Background(), c.ID()); got.Attempts() != 1 {
		t.Fatalf("attempts %d", got.Attempts())
	}
}
```

Run: `go test -race -run 'Test(SignIn|IssueSession|VerifyChallenge)' ./internal/auth/`
Expected: PASS.

- [ ] **Step 6: Write the E2E tests**

Append to `e2e/auth_helpers_test.go` (imports `context`, `contact`):

```go
type signIn struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	TokenType    string `json:"token_type"`
	Account      struct {
		ID    string `json:"id"`
		IsNew bool   `json:"is_new"`
	} `json:"account"`
}

func bearer(token string) [2]string { return [2]string{"Authorization", "Bearer " + token} }

func wrongCode(code string) string {
	if code == "000000" {
		return "000001"
	}
	return "000000"
}

// requestCode sends a code to a phone typed any way and returns the challenge
// and the code. Earlier sends to that phone are pushed back a minute in its
// quota, so a test can ask again without waiting 45 s.
func requestCode(t *testing.T, typed string) (string, string) {
	t.Helper()
	p, err := contact.ParsePhone(typed)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := db.Exec(context.Background(), `
UPDATE otp_quotas SET sent_at = ARRAY(SELECT s - interval '1 minute' FROM unnest(sent_at) s)
WHERE key = $1`, "dest:"+p.Value()); err != nil {
		t.Fatal(err)
	}
	n := box.count(p.Value())
	res := sendOTP(t, "phone", typed)
	if res.Status != 200 {
		t.Fatalf("send: %d %s", res.Status, res.Body)
	}
	return decode[challenge](t, res).ChallengeID, box.code(t, p.Value(), n+1)
}

func verifyCode(t *testing.T, challengeID, code string, headers ...[2]string) Response {
	t.Helper()
	return call(t, server, "POST", "/v1/auth/otp/verify",
		map[string]string{"challenge_id": challengeID, "code": code, "device_name": "e2e"},
		append([][2]string{newKey()}, headers...)...)
}

func signInWith(t *testing.T, typed string) signIn {
	t.Helper()
	id, code := requestCode(t, typed)
	res := verifyCode(t, id, code)
	if res.Status != 200 {
		t.Fatalf("verify: %d %s", res.Status, res.Body)
	}
	return decode[signIn](t, res)
}

func newAccount(t *testing.T) (signIn, string) {
	t.Helper()
	phone := newPhone()
	return signInWith(t, phone), phone
}
```

Append to `e2e/auth_otp_test.go` (imports `context`, `reflect`, `sync`, `uuid`):

```go
func TestSignUpThenSignIn(t *testing.T) {
	first, phone := newAccount(t)
	if !first.Account.IsNew || first.TokenType != "Bearer" || first.AccessToken == "" || first.RefreshToken == "" {
		t.Fatalf("%+v", first)
	}
	if second := signInWith(t, phone); second.Account.ID != first.Account.ID || second.Account.IsNew {
		t.Fatalf("second %+v", second.Account)
	}
}

func TestSignInIgnoresPhoneFormat(t *testing.T) {
	phone := newPhone() // +849xxxxxxxx
	a := signInWith(t, "0"+phone[3:])
	b := signInWith(t, "+84 "+phone[3:5]+" "+phone[5:8]+" "+phone[8:])
	if a.Account.ID != b.Account.ID || !a.Account.IsNew || b.Account.IsNew {
		t.Fatalf("%+v, %+v", a.Account, b.Account)
	}
}

func TestSignInReplayedKeyGetsTheSameAccount(t *testing.T) {
	id, code := requestCode(t, newPhone())
	key := newKey()
	a := verifyCode(t, id, code, key)
	b := verifyCode(t, id, code, key)
	sa, sb := decode[signIn](t, a), decode[signIn](t, b)
	if a.Status != 200 || b.Status != 200 || sa.Account != sb.Account || sb.RefreshToken == sa.RefreshToken {
		t.Fatalf("a %d %s, b %d %s", a.Status, a.Body, b.Status, b.Body)
	}
}

func TestVerifyWrongCode(t *testing.T) {
	id, code := requestCode(t, newPhone())
	res := verifyCode(t, id, wrongCode(code))
	if e := errorOf(t, res); res.Status != 422 || e.Code != "invalid_code" || e.Details["attempts_left"] != float64(4) {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
}

func TestVerifyUnknownChallenge(t *testing.T) {
	if res := verifyCode(t, uuid.NewV7().String(), "123456"); res.Status != 422 || errorOf(t, res).Code != "code_expired" {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
}

func TestVerifyBadShape(t *testing.T) {
	if res := verifyCode(t, uuid.NewV7().String(), "12345"); res.Status != 400 || errorOf(t, res).Fields["code"] != "pattern" {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
}

func TestVerifySuspendedAccount(t *testing.T) {
	acc, phone := newAccount(t)
	if _, err := db.Exec(context.Background(),
		`UPDATE accounts SET status = 'suspended', suspend_reason = 'e2e' WHERE id = $1`, acc.Account.ID); err != nil {
		t.Fatal(err)
	}
	id, code := requestCode(t, phone)
	if res := verifyCode(t, id, code); res.Status != 403 || errorOf(t, res).Code != "account_suspended" {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
}

// TestVerifyParallelGuesses fires 30 wrong guesses at one challenge with
// separate keys. Every reply is 422 or 409, and the challenge ends with at
// most five counted attempts.
func TestVerifyParallelGuesses(t *testing.T) {
	id, code := requestCode(t, newPhone())
	statuses := make(chan int, 30)
	var wg sync.WaitGroup
	for range 30 {
		wg.Go(func() { statuses <- verifyCodeStatus(id, wrongCode(code)) })
	}
	wg.Wait()
	close(statuses)
	for s := range statuses {
		if s != 422 && s != 409 {
			t.Fatalf("status %d", s)
		}
	}
	var attempts int
	db.QueryRow(context.Background(), `SELECT attempts FROM otp_challenges WHERE id = $1`, id).Scan(&attempts)
	if attempts > 5 {
		t.Fatalf("attempts %d", attempts)
	}
}

// TestOTPSendRepliesAlikeForKnownAndUnknown is the enumeration test.
func TestOTPSendRepliesAlikeForKnownAndUnknown(t *testing.T) {
	_, known := newAccount(t)
	db.Exec(context.Background(), `UPDATE otp_quotas SET sent_at = '{}' WHERE key = $1`, "dest:"+known)
	a, b := sendOTP(t, "phone", known), sendOTP(t, "phone", newPhone())
	ka, kb := decode[map[string]any](t, a), decode[map[string]any](t, b)
	delete(ka, "challenge_id")
	delete(kb, "challenge_id")
	if a.Status != b.Status || !reflect.DeepEqual(ka, kb) {
		t.Fatalf("known %d %s, unknown %d %s", a.Status, a.Body, b.Status, b.Body)
	}
}
```

Add to `e2e/auth_helpers_test.go` (imports `bytes`, `encoding/json`, `net/http`): a status-only call that is safe off the test goroutine, recording the status for the coverage check as `call` does. It skips response validation, so the parallel test asserts the statuses itself.

```go
// verifyCodeStatus posts one guess and returns the status without touching t,
// so goroutines can call it.
func verifyCodeStatus(challengeID, code string) int {
	body, _ := json.Marshal(map[string]string{"challenge_id": challengeID, "code": code})
	req, _ := http.NewRequest("POST", server+"/v1/auth/otp/verify", bytes.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", uuid.NewV7().String())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return 0
	}
	res.Body.Close()
	mu.Lock()
	if seen["verifyOtp"] == nil {
		seen["verifyOtp"] = map[int]bool{}
	}
	seen["verifyOtp"][res.StatusCode] = true
	mu.Unlock()
	return res.StatusCode
}
```

Task 11 adds a check to `TestSignInReplayedKeyGetsTheSameAccount` that the replay's refresh token works.

Run: `make lint && make test`
Expected: PASS, with `verifyOtp` 200, 400, 403, 409, 422 observed. If no run of `TestVerifyParallelGuesses` yields a 409 in three tries, ledger it and drop 409 from the spec rather than keep a flaky coverage check.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(auth): sign in or sign up through a Restate service; tokens stay out of the journal"
```

### Task 10: Sign-in middleware and `/v1/accounts/me`

**Files:**
- Create: `api/paths/account.yaml`, `api/schemas/account.yaml`; Modify: `api/openapi.yaml`
- Create: `internal/auth/middleware.go`, `middleware_test.go`; Modify: `internal/auth/routes.go`, `internal/app/app.go`
- Create: `e2e/accounts_test.go`

**Interfaces:**
- Produces: `auth.RequireAuth(v session.Verifier, now func() time.Time, log *slog.Logger) func(http.Handler) http.Handler`; `auth.principal(w, r, log) (authn.Principal, bool)` (unexported)

- [ ] **Step 1: Write the OpenAPI operations**

Create `api/schemas/account.yaml`:

```yaml
Account:
  type: object
  additionalProperties: false
  required: [id, display_name, status, created_at]
  properties:
    id:
      type: string
      format: uuid
    display_name:
      type: string
      description: Empty until the person completes their profile.
    status:
      type: string
      enum: [active, suspended]
    created_at:
      type: string
      format: date-time
AccountUpdate:
  type: object
  additionalProperties: false
  required: [display_name]
  properties:
    display_name:
      type: string
      minLength: 1
      maxLength: 50
```

Create `api/paths/account.yaml`:

```yaml
me:
  get:
    operationId: getMyAccount
    summary: Read the caller's account.
    tags: [account]
    security:
      - bearerAuth: []
    responses:
      "200":
        description: The account.
        content:
          application/json:
            schema:
              $ref: "../schemas/account.yaml#/Account"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
  patch:
    operationId: updateMyAccount
    summary: Change the display name.
    tags: [account]
    security:
      - bearerAuth: []
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/account.yaml#/AccountUpdate"
    responses:
      "200":
        description: The updated account.
        content:
          application/json:
            schema:
              $ref: "../schemas/account.yaml#/Account"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "403":
        $ref: "../responses/common.yaml#/Forbidden"
      "422":
        $ref: "../responses/common.yaml#/Unprocessable"
```

`api/openapi.yaml`: add `/v1/accounts/me: {$ref: "paths/account.yaml#/me"}`.

- [ ] **Step 2: Write the failing middleware test**

Create `internal/auth/middleware_test.go`:

```go
package auth_test

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/authn"
)

func TestRequireAuth(t *testing.T) {
	acc, sid := uuid.NewV7(), uuid.NewV7()
	valid, _, _ := session.NewSigner(testKeys).Sign(acc, sid, now, now)
	expired, _, _ := session.NewSigner(testKeys).Sign(acc, sid, now, now.Add(-20*time.Minute))
	var seen authn.Principal
	h := auth.RequireAuth(session.NewVerifier(testKeys), func() time.Time { return now }, discard)(
		http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			seen, _ = authn.From(r.Context())
			w.WriteHeader(http.StatusNoContent)
		}))
	for _, c := range []struct {
		header string
		status int
		code   string
	}{
		{"", 401, "unauthenticated"},
		{"Basic dXNlcjpwYXNz", 401, "unauthenticated"},
		{"Bearer ", 401, "unauthenticated"},
		{"Bearer junk", 401, "invalid_token"},
		{"Bearer " + expired, 401, "invalid_token"},
		{"Bearer " + valid, 204, ""},
	} {
		r := httptest.NewRequest("GET", "/x", nil)
		if c.header != "" {
			r.Header.Set("Authorization", c.header)
		}
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, r)
		var body struct {
			Error struct {
				Code string `json:"code"`
			} `json:"error"`
		}
		json.Unmarshal(rec.Body.Bytes(), &body)
		if rec.Code != c.status || body.Error.Code != c.code {
			t.Errorf("%q: %d %q", c.header, rec.Code, body.Error.Code)
		}
	}
	if seen.AccountID != acc || seen.SessionID != sid {
		t.Fatalf("principal %+v", seen)
	}
}
```

Run: `go test -short -run TestRequireAuth ./internal/auth/`
Expected: build failure, `auth.RequireAuth` undefined.

- [ ] **Step 3: Implement and wire**

Create `internal/auth/middleware.go`:

```go
package auth

import (
	"log/slog"
	"net/http"
	"strings"
	"time"

	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/httpx"
)

// RequireAuth checks the bearer token and puts the principal in the request
// context. It reads no database: a signed-out session's access token works
// until it expires, and write use cases check the account themselves.
func RequireAuth(v session.Verifier, now func() time.Time, log *slog.Logger) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			token, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
			if !ok || token == "" {
				httpx.WriteError(w, r, log, authn.ErrUnauthenticated)
				return
			}
			p, err := v.Verify(token, now())
			if err != nil {
				httpx.WriteError(w, r, log, err)
				return
			}
			next.ServeHTTP(w, r.WithContext(authn.With(r.Context(), p)))
		})
	}
}

// principal returns the caller of a route behind RequireAuth, or writes 401.
func principal(w http.ResponseWriter, r *http.Request, log *slog.Logger) (authn.Principal, bool) {
	p, ok := authn.From(r.Context())
	if !ok {
		httpx.WriteError(w, r, log, authn.ErrUnauthenticated)
	}
	return p, ok
}
```

In `internal/app/app.go` `routeModules`, after `auth.Routes(...)`:

```go
	protect := auth.RequireAuth(keys.Verifier, time.Now, log)
	account.Routes(a.router, accounts, time.Now, log, protect)
```

- [ ] **Step 4: Write the E2E tests**

Create `e2e/accounts_test.go`:

```go
package e2e

import (
	"context"
	"testing"
)

type accountView struct {
	ID          string `json:"id"`
	DisplayName string `json:"display_name"`
	Status      string `json:"status"`
}

func TestAccountMe(t *testing.T) {
	acc, _ := newAccount(t)
	res := call(t, server, "GET", "/v1/accounts/me", nil, bearer(acc.AccessToken))
	if v := decode[accountView](t, res); res.Status != 200 || v.ID != acc.Account.ID || v.DisplayName != "" || v.Status != "active" {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
}

func TestAccountMeNeedsAToken(t *testing.T) {
	if res := call(t, server, "GET", "/v1/accounts/me", nil); res.Status != 401 || errorOf(t, res).Code != "unauthenticated" {
		t.Fatalf("no token: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/accounts/me", nil, bearer("junk")); res.Status != 401 || errorOf(t, res).Code != "invalid_token" {
		t.Fatalf("junk token: %d %s", res.Status, res.Body)
	}
}

func TestAccountRename(t *testing.T) {
	acc, _ := newAccount(t)
	res := call(t, server, "PATCH", "/v1/accounts/me", map[string]string{"display_name": "  Linh  "}, bearer(acc.AccessToken))
	if res.Status != 200 || decode[accountView](t, res).DisplayName != "Linh" {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
	for _, c := range []struct {
		body   map[string]string
		status int
		code   string
	}{
		{map[string]string{"display_name": "   "}, 422, "invalid_display_name"},
		{map[string]string{"display_name": "Linh", "status": "active"}, 400, "invalid_request"},
	} {
		if res := call(t, server, "PATCH", "/v1/accounts/me", c.body, bearer(acc.AccessToken)); res.Status != c.status || errorOf(t, res).Code != c.code {
			t.Fatalf("%v: %d %s", c.body, res.Status, res.Body)
		}
	}
	if res := call(t, server, "PATCH", "/v1/accounts/me", map[string]string{"display_name": "Linh"}); res.Status != 401 {
		t.Fatalf("no token: %d %s", res.Status, res.Body)
	}
}

// A suspended person keeps read access until the access token expires;
// writes stop at once.
func TestAccountRenameWhileSuspended(t *testing.T) {
	acc, _ := newAccount(t)
	if _, err := db.Exec(context.Background(),
		`UPDATE accounts SET status = 'suspended', suspend_reason = 'e2e' WHERE id = $1`, acc.Account.ID); err != nil {
		t.Fatal(err)
	}
	if res := call(t, server, "PATCH", "/v1/accounts/me", map[string]string{"display_name": "Linh"}, bearer(acc.AccessToken)); res.Status != 403 {
		t.Fatalf("rename: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/accounts/me", nil, bearer(acc.AccessToken)); res.Status != 200 {
		t.Fatalf("read: %d %s", res.Status, res.Body)
	}
}
```

- [ ] **Step 5: Run and commit**

Run: `make lint && make test`
Expected: PASS, `getMyAccount` 200/401 and `updateMyAccount` 200/400/401/403/422 observed.

```bash
git add -A
git commit -m "feat(auth): bearer-token middleware; serve GET and PATCH /v1/accounts/me"
```

### Task 11: `POST /v1/auth/refresh`

**Files:**
- Modify: `api/openapi.yaml`, `api/paths/auth.yaml`, `api/schemas/auth.yaml`, `internal/auth/routes.go`
- Create: `internal/auth/session_refresh.go`, `session_refresh_test.go`, `session_refresh_pg_test.go`
- Create: `e2e/auth_session_test.go`; Modify: `e2e/auth_otp_test.go`

**Interfaces:**
- Produces: `auth.Refresh(ctx, sessions session.Store, accounts AccountPort, signer session.Signer, token string, now time.Time, log *slog.Logger) (session.Tokens, error)`, `auth.RefreshHandler(sessions, accounts, signer, now func() time.Time, log) http.Handler`

- [ ] **Step 1: Write the OpenAPI operation**

Append to `api/schemas/auth.yaml`:

```yaml
RefreshRequest:
  type: object
  additionalProperties: false
  required: [refresh_token]
  properties:
    refresh_token:
      type: string
      minLength: 1
      maxLength: 200
```

Append to `api/paths/auth.yaml`:

```yaml
refresh:
  post:
    operationId: refreshSession
    summary: Rotate the refresh token and get a new access token.
    description: A refresh token works once. Presenting it again, or two refreshes racing with one token, signs the session out.
    tags: [auth]
    requestBody:
      required: true
      content:
        application/json:
          schema:
            $ref: "../schemas/auth.yaml#/RefreshRequest"
    responses:
      "200":
        description: New tokens.
        content:
          application/json:
            schema:
              $ref: "../schemas/auth.yaml#/Tokens"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "403":
        $ref: "../responses/common.yaml#/Forbidden"
```

`api/openapi.yaml`: add `/v1/auth/refresh: {$ref: "paths/auth.yaml#/refresh"}`.

- [ ] **Step 2: Write the failing tests**

Create `internal/auth/session_refresh_test.go`:

```go
package auth_test

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/auth/session/sessiontest"
)

type refreshEnv struct {
	sessions *sessiontest.MemStore
	accounts *fakeAccounts
	acc      uuid.UUID
	sid      uuid.UUID
	token    string
}

func newRefreshEnv(t *testing.T) *refreshEnv {
	t.Helper()
	e := &refreshEnv{sessions: sessiontest.NewMemStore(), accounts: newFakeAccounts(), acc: uuid.NewV7(), sid: uuid.NewV7()}
	e.accounts.Create(context.Background(), e.acc, "")
	tokens, err := auth.IssueSession(context.Background(), e.sessions, session.NewSigner(testKeys), e.sid, e.acc, "Pixel 9", now)
	if err != nil {
		t.Fatal(err)
	}
	e.token = tokens.RefreshToken
	return e
}

func (e *refreshEnv) refresh(token string, at time.Time) (session.Tokens, error) {
	return auth.Refresh(context.Background(), e.sessions, e.accounts, session.NewSigner(testKeys), token, at, discard)
}

func (e *refreshEnv) revoked(t *testing.T) bool {
	s, err := e.sessions.Get(context.Background(), e.sid)
	if err != nil {
		t.Fatal(err)
	}
	return s.RevokedAt() != nil
}

func TestRefreshRotatesAndKeepsAuthTime(t *testing.T) {
	e := newRefreshEnv(t)
	out, err := e.refresh(e.token, now.Add(time.Hour))
	if err != nil || out.RefreshToken == e.token {
		t.Fatalf("%+v %v", out, err)
	}
	p, err := session.NewVerifier(testKeys).Verify(out.AccessToken, now.Add(time.Hour))
	if err != nil || p.SessionID != e.sid || !p.AuthTime.Equal(now) {
		t.Fatalf("%+v %v", p, err)
	}
	s, _ := e.sessions.Get(context.Background(), e.sid)
	if !bytes.Equal(s.PrevRefreshHash(), session.HashRefresh(e.token)) {
		t.Fatal("previous hash not kept")
	}
}

func TestRefreshReplayRevokes(t *testing.T) {
	e := newRefreshEnv(t)
	next, _ := e.refresh(e.token, now)
	if _, err := e.refresh(e.token, now); !errors.Is(err, session.ErrRevoked) || !e.revoked(t) {
		t.Fatalf("replay: %v", err)
	}
	if _, err := e.refresh(next.RefreshToken, now); !errors.Is(err, session.ErrRevoked) {
		t.Fatalf("the newer token after a replay: %v", err)
	}
}

func TestRefreshRefusals(t *testing.T) {
	e := newRefreshEnv(t)
	if _, err := e.refresh("rt_nope", now); !errors.Is(err, session.ErrInvalidRefresh) {
		t.Fatalf("unknown: %v", err)
	}
	if _, err := e.refresh(e.token, now.Add(session.IdleLimit)); !errors.Is(err, session.ErrExpired) {
		t.Fatalf("idle: %v", err)
	}
	e.accounts.suspend(e.acc)
	if _, err := e.refresh(e.token, now); !errors.Is(err, account.ErrSuspended) || !e.revoked(t) {
		t.Fatalf("suspended: %v", err)
	}
}

// losingSave behaves as if another refresh with the same token saved first.
type losingSave struct{ *sessiontest.MemStore }

func (l losingSave) Save(ctx context.Context, s *session.Session, w uuid.UUID) error {
	if s.RevokedAt() == nil {
		return session.ErrConflict
	}
	return l.MemStore.Save(ctx, s, w)
}

func TestRefreshThatLosesARaceRevokes(t *testing.T) {
	e := newRefreshEnv(t)
	_, err := auth.Refresh(context.Background(), losingSave{e.sessions}, e.accounts, session.NewSigner(testKeys), e.token, now, discard)
	if !errors.Is(err, session.ErrRevoked) || !e.revoked(t) {
		t.Fatalf("%v, revoked %v", err, e.revoked(t))
	}
}
```

Create `internal/auth/session_refresh_pg_test.go`:

```go
package auth_test

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/pgtest"
)

// TestParallelRefreshRevokes is the spec's parallel-refresh attack: one token
// used five times at once yields at most one success, and afterwards the
// session no longer refreshes.
func TestParallelRefreshRevokes(t *testing.T) {
	ctx := context.Background()
	db := pgtest.New(t)
	accounts := account.Client{Store: account.NewPGStore(db), Now: time.Now}
	sessions, signer := session.NewPGStore(db), session.NewSigner(testKeys)
	acc := uuid.NewV7()
	accounts.Create(ctx, acc, "")
	tokens, err := auth.IssueSession(ctx, sessions, signer, uuid.NewV7(), acc, "", time.Now())
	if err != nil {
		t.Fatal(err)
	}

	type result struct {
		tokens session.Tokens
		err    error
	}
	results := make(chan result, 5)
	var wg sync.WaitGroup
	for range 5 {
		wg.Go(func() {
			out, err := auth.Refresh(ctx, sessions, accounts, signer, tokens.RefreshToken, time.Now(), discard)
			results <- result{out, err}
		})
	}
	wg.Wait()
	close(results)
	var winners []session.Tokens
	for r := range results {
		switch {
		case r.err == nil:
			winners = append(winners, r.tokens)
		case errors.Is(r.err, session.ErrRevoked):
		default:
			t.Fatalf("unexpected %v", r.err)
		}
	}
	if len(winners) > 1 {
		t.Fatalf("%d refreshes won", len(winners))
	}
	for _, w := range winners {
		if _, err := auth.Refresh(ctx, sessions, accounts, signer, w.RefreshToken, time.Now(), discard); !errors.Is(err, session.ErrRevoked) {
			t.Fatalf("the winner's token after the race: %v", err)
		}
	}
}
```

Run: `go test ./internal/auth/`
Expected: build failure, `auth.Refresh` undefined.

- [ ] **Step 3: Implement**

Create `internal/auth/session_refresh.go`:

```go
package auth

import (
	"context"
	"errors"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/account"
	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/httpx"
)

// Refresh rotates a refresh token. A token presented after it was rotated, or
// two refreshes racing with one token, means two parties hold it, so the
// session is revoked.
func Refresh(ctx context.Context, sessions session.Store, accounts AccountPort, signer session.Signer, token string, now time.Time, log *slog.Logger) (session.Tokens, error) {
	hash := session.HashRefresh(token)
	s, err := sessions.FindByRefresh(ctx, hash)
	if errors.Is(err, session.ErrNotFound) {
		prev, err := sessions.FindByPrevRefresh(ctx, hash)
		if errors.Is(err, session.ErrNotFound) {
			return session.Tokens{}, session.ErrInvalidRefresh
		}
		if err != nil {
			return session.Tokens{}, err
		}
		return session.Tokens{}, reused(ctx, sessions, prev.ID(), now, "rotated token presented again", log)
	}
	if err != nil {
		return session.Tokens{}, err
	}
	if err := s.Usable(now); err != nil {
		return session.Tokens{}, err
	}
	st, err := accounts.Status(ctx, s.AccountID())
	if err != nil {
		return session.Tokens{}, err
	}
	if st == account.StatusSuspended {
		if err := revoke(ctx, sessions, s.ID(), now); err != nil {
			return session.Tokens{}, err
		}
		return session.Tokens{}, account.ErrSuspended
	}
	next := s.Rotate(now)
	if err := sessions.Save(ctx, &s, uuid.NewV7()); err != nil {
		if errors.Is(err, session.ErrConflict) {
			return session.Tokens{}, reused(ctx, sessions, s.ID(), now, "concurrent refresh", log)
		}
		return session.Tokens{}, err
	}
	access, exp, err := signer.Sign(s.AccountID(), s.ID(), s.AuthTime(), now)
	if err != nil {
		return session.Tokens{}, err
	}
	return session.Tokens{AccessToken: access, AccessTokenExpiresAt: exp, RefreshToken: next, TokenType: "Bearer"}, nil
}

// reused revokes a session whose refresh token two parties hold, records the
// security event and returns the refusal.
func reused(ctx context.Context, sessions session.Store, id uuid.UUID, now time.Time, why string, log *slog.Logger) error {
	if err := revoke(ctx, sessions, id, now); err != nil {
		return err
	}
	log.WarnContext(ctx, "security: refresh token reuse, session revoked", "why", why, "session_id", id)
	refreshReuse.Add(ctx, 1)
	return session.ErrRevoked
}

// revoke reloads the session and revokes it, retrying once when a concurrent
// write gets there first.
func revoke(ctx context.Context, sessions session.Store, id uuid.UUID, now time.Time) error {
	var err error
	for range 2 {
		var s session.Session
		if s, err = sessions.Get(ctx, id); err != nil {
			return err
		}
		if s.RevokedAt() != nil {
			return nil
		}
		s.Revoke(now)
		if err = sessions.Save(ctx, &s, uuid.NewV7()); !errors.Is(err, session.ErrConflict) {
			return err
		}
	}
	return err
}

type RefreshRequest struct {
	RefreshToken string `json:"refresh_token"`
}

// POST /v1/auth/refresh
func RefreshHandler(sessions session.Store, accounts AccountPort, signer session.Signer, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		in, err := httpx.Decode[RefreshRequest](r)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		out, err := Refresh(r.Context(), sessions, accounts, signer, in.RefreshToken, now(), log)
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, r, http.StatusOK, out)
	})
}
```

`internal/auth/routes.go`, in `Routes`: `r.Handle("POST /v1/auth/refresh", RefreshHandler(p.Sessions, p.Accounts, k.Signer, now, log))`.

Run: `go test -race ./internal/auth/`
Expected: PASS.

- [ ] **Step 4: Write the E2E tests**

Create `e2e/auth_session_test.go`:

```go
package e2e

import (
	"context"
	"testing"
)

type tokens struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
}

func refresh(t *testing.T, token string) Response {
	t.Helper()
	return call(t, server, "POST", "/v1/auth/refresh", map[string]string{"refresh_token": token})
}

func TestRefreshRotates(t *testing.T) {
	acc, _ := newAccount(t)
	res := refresh(t, acc.RefreshToken)
	next := decode[tokens](t, res)
	if res.Status != 200 || next.RefreshToken == acc.RefreshToken {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/accounts/me", nil, bearer(next.AccessToken)); res.Status != 200 {
		t.Fatalf("new access token: %d %s", res.Status, res.Body)
	}
}

// TestRefreshReplayRevokesTheSession is the spec's replay attack test.
func TestRefreshReplayRevokesTheSession(t *testing.T) {
	acc, _ := newAccount(t)
	next := decode[tokens](t, refresh(t, acc.RefreshToken))
	for _, token := range []string{acc.RefreshToken, next.RefreshToken} {
		if res := refresh(t, token); res.Status != 401 || errorOf(t, res).Code != "session_revoked" {
			t.Fatalf("%d %s", res.Status, res.Body)
		}
	}
}

func TestRefreshRefusals(t *testing.T) {
	if res := refresh(t, "rt_nope"); res.Status != 401 || errorOf(t, res).Code != "invalid_refresh_token" {
		t.Fatalf("unknown: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", "/v1/auth/refresh", map[string]string{}); res.Status != 400 {
		t.Fatalf("empty body: %d %s", res.Status, res.Body)
	}
	acc, _ := newAccount(t)
	db.Exec(context.Background(), `UPDATE accounts SET status = 'suspended', suspend_reason = 'e2e' WHERE id = $1`, acc.Account.ID)
	if res := refresh(t, acc.RefreshToken); res.Status != 403 || errorOf(t, res).Code != "account_suspended" {
		t.Fatalf("suspended: %d %s", res.Status, res.Body)
	}
}
```

In `e2e/auth_otp_test.go`, `TestSignInReplayedKeyGetsTheSameAccount` ends with:

```go
	if res := refresh(t, sb.RefreshToken); res.Status != 200 {
		t.Fatalf("the replay's refresh token: %d %s", res.Status, res.Body)
	}
```

- [ ] **Step 5: Run and commit**

Run: `make lint && make test`
Expected: PASS, `refreshSession` 200/400/401/403 observed.

```bash
git add -A
git commit -m "feat(auth): rotate refresh tokens and revoke the session on reuse"
```

### Task 12: Sign out and devices

**Files:**
- Modify: `api/openapi.yaml`, `api/paths/auth.yaml`, `api/schemas/auth.yaml`, `internal/auth/routes.go`, `e2e/auth_session_test.go`
- Create: `internal/auth/session_logout.go`, `session_list.go`, `session_logout_test.go`, `session_list_test.go`

**Interfaces:**
- Produces: `auth.Logout(ctx, sessions, p authn.Principal, now) error`, `auth.LogoutAll(ctx, sessions, p, now) error`, `auth.ErrReauthRequired` (428 `reauth_required`), `auth.RemoveSession(ctx, sessions, p, id uuid.UUID, now) error`, `auth.ErrSessionNotFound` (404 `session_not_found`)
- Produces: `auth.ListSessions(ctx, sessions, p, cursor uuid.UUID, limit int, now) (SessionPage, error)`, `auth.SessionPage{Items []SessionItem; NextCursor *uuid.UUID}`, `auth.SessionItem{ID; DeviceName; CreatedAt; LastUsedAt; Current bool}`
- Produces: handlers `LogoutHandler`, `LogoutAllHandler`, `RemoveSessionHandler`, `ListSessionsHandler`, each `(sessions session.Store, now func() time.Time, log *slog.Logger) http.Handler`

- [ ] **Step 1: Write the OpenAPI operations**

Append to `api/schemas/auth.yaml`:

```yaml
Session:
  type: object
  additionalProperties: false
  required: [id, device_name, created_at, last_used_at, current]
  properties:
    id:
      type: string
      format: uuid
    device_name:
      type: string
    created_at:
      type: string
      format: date-time
    last_used_at:
      type: string
      format: date-time
    current:
      type: boolean
      description: True for the session the request was made with.
SessionList:
  type: object
  additionalProperties: false
  required: [items]
  properties:
    items:
      type: array
      items:
        $ref: "#/Session"
    next_cursor:
      type: string
      format: uuid
      description: Present when more sessions follow; pass it as cursor.
```

Append to `api/paths/auth.yaml`:

```yaml
logout:
  post:
    operationId: logout
    summary: Sign out the session this request was made with.
    description: The access token keeps working until it expires, at most 15 minutes; the app discards it.
    tags: [auth]
    security:
      - bearerAuth: []
    responses:
      "204":
        description: Signed out.
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
logoutAll:
  post:
    operationId: logoutAll
    summary: Sign out every session of the account.
    description: Needs a sign-in within the last 15 minutes.
    tags: [auth]
    security:
      - bearerAuth: []
    responses:
      "204":
        description: Every session is signed out.
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "428":
        $ref: "../responses/common.yaml#/PreconditionRequired"
sessions:
  get:
    operationId: listSessions
    summary: List signed-in devices, newest first.
    tags: [auth]
    security:
      - bearerAuth: []
    parameters:
      - name: cursor
        in: query
        schema:
          type: string
          format: uuid
      - name: limit
        in: query
        schema:
          type: integer
          minimum: 1
          maximum: 100
          default: 20
    responses:
      "200":
        description: One page of sessions.
        content:
          application/json:
            schema:
              $ref: "../schemas/auth.yaml#/SessionList"
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
session:
  delete:
    operationId: deleteSession
    summary: Sign one device out.
    tags: [auth]
    security:
      - bearerAuth: []
    parameters:
      - name: id
        in: path
        required: true
        schema:
          type: string
          format: uuid
    responses:
      "204":
        description: Signed out.
      "400":
        $ref: "../responses/common.yaml#/BadRequest"
      "401":
        $ref: "../responses/common.yaml#/Unauthorized"
      "404":
        $ref: "../responses/common.yaml#/NotFound"
```

`api/openapi.yaml`: add `/v1/auth/logout`, `/v1/auth/logout-all`, `/v1/auth/sessions` and `/v1/auth/sessions/{id}` pointing at `logout`, `logoutAll`, `sessions` and `session`.

- [ ] **Step 2: Write the failing unit tests**

Create `internal/auth/session_logout_test.go`:

```go
package auth_test

import (
	"context"
	"errors"
	"testing"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/auth/session/sessiontest"
	"github.com/shopnexus/server2/internal/platform/authn"
)

// devices issues sessions for acc and returns the principal of each.
func devices(t *testing.T, s session.Store, acc uuid.UUID, n int, at time.Time) []authn.Principal {
	t.Helper()
	var out []authn.Principal
	for range n {
		id := uuid.NewV7()
		if _, err := auth.IssueSession(context.Background(), s, session.NewSigner(testKeys), id, acc, "Pixel 9", at); err != nil {
			t.Fatal(err)
		}
		out = append(out, authn.Principal{AccountID: acc, SessionID: id, AuthTime: at})
	}
	return out
}

func revokedIn(t *testing.T, s session.Store, id uuid.UUID) bool {
	t.Helper()
	got, err := s.Get(context.Background(), id)
	if err != nil {
		t.Fatal(err)
	}
	return got.RevokedAt() != nil
}

func TestLogoutRevokesOnlyThisSession(t *testing.T) {
	s, acc := sessiontest.NewMemStore(), uuid.NewV7()
	ps := devices(t, s, acc, 2, now)
	if err := auth.Logout(context.Background(), s, ps[1], now); err != nil {
		t.Fatal(err)
	}
	if !revokedIn(t, s, ps[1].SessionID) || revokedIn(t, s, ps[0].SessionID) {
		t.Fatal("wrong session revoked")
	}
}

func TestLogoutAllNeedsRecentSignIn(t *testing.T) {
	s, acc := sessiontest.NewMemStore(), uuid.NewV7()
	ps := devices(t, s, acc, 2, now)
	other := devices(t, s, uuid.NewV7(), 1, now)
	if err := auth.LogoutAll(context.Background(), s, ps[0], now.Add(15*time.Minute+time.Second)); !errors.Is(err, auth.ErrReauthRequired) {
		t.Fatalf("stale sign-in: %v", err)
	}
	if err := auth.LogoutAll(context.Background(), s, ps[0], now.Add(14*time.Minute)); err != nil {
		t.Fatal(err)
	}
	if !revokedIn(t, s, ps[0].SessionID) || !revokedIn(t, s, ps[1].SessionID) || revokedIn(t, s, other[0].SessionID) {
		t.Fatal("wrong sessions revoked")
	}
}

func TestRemoveSessionChecksTheOwner(t *testing.T) {
	s := sessiontest.NewMemStore()
	mine := devices(t, s, uuid.NewV7(), 2, now)
	theirs := devices(t, s, uuid.NewV7(), 1, now)
	if err := auth.RemoveSession(context.Background(), s, mine[0], theirs[0].SessionID, now); !errors.Is(err, auth.ErrSessionNotFound) || revokedIn(t, s, theirs[0].SessionID) {
		t.Fatalf("another account's session: %v", err)
	}
	if err := auth.RemoveSession(context.Background(), s, mine[0], mine[1].SessionID, now); err != nil || !revokedIn(t, s, mine[1].SessionID) {
		t.Fatalf("own session: %v", err)
	}
	if err := auth.RemoveSession(context.Background(), s, mine[0], uuid.NewV7(), now); !errors.Is(err, auth.ErrSessionNotFound) {
		t.Fatalf("unknown session: %v", err)
	}
}
```

Create `internal/auth/session_list_test.go`:

```go
package auth_test

import (
	"context"
	"testing"
	"uuid"

	"github.com/shopnexus/server2/internal/auth"
	"github.com/shopnexus/server2/internal/auth/session/sessiontest"
)

func TestListSessionsPagesNewestFirst(t *testing.T) {
	s, acc := sessiontest.NewMemStore(), uuid.NewV7()
	ps := devices(t, s, acc, 2, now)
	devices(t, s, uuid.NewV7(), 1, now)
	ctx := context.Background()

	all, err := auth.ListSessions(ctx, s, ps[1], uuid.UUID{}, 0, now)
	if err != nil || len(all.Items) != 2 || all.NextCursor != nil || all.Items[0].ID != ps[1].SessionID ||
		!all.Items[0].Current || all.Items[1].Current {
		t.Fatalf("%+v %v", all, err)
	}
	first, _ := auth.ListSessions(ctx, s, ps[1], uuid.UUID{}, 1, now)
	if len(first.Items) != 1 || first.NextCursor == nil || *first.NextCursor != ps[1].SessionID {
		t.Fatalf("first page %+v", first)
	}
	second, _ := auth.ListSessions(ctx, s, ps[1], *first.NextCursor, 1, now)
	if len(second.Items) != 1 || second.Items[0].ID != ps[0].SessionID || second.NextCursor != nil {
		t.Fatalf("second page %+v", second)
	}
}
```

Run: `go test -short ./internal/auth/`
Expected: build failure naming `Logout`, `LogoutAll`, `RemoveSession`, `ListSessions`.

- [ ] **Step 3: Implement**

Create `internal/auth/session_logout.go`:

```go
package auth

import (
	"context"
	"log/slog"
	"net/http"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/httpx"
)

var (
	ErrReauthRequired = apperr.New(apperr.KindPreconditionRequired, "reauth_required", "sign in again to do this")
	// ErrSessionNotFound also answers for another account's session: a
	// resource the caller may not see is 404, never 403.
	ErrSessionNotFound = apperr.New(apperr.KindNotFound, "session_not_found", "no such session")
)

// recentAuth is how long after a sign-in the sensitive actions stay open.
const recentAuth = 15 * time.Minute

// Logout revokes the caller's session. Its access token keeps working until
// it expires; the app discards it.
func Logout(ctx context.Context, sessions session.Store, p authn.Principal, now time.Time) error {
	return revoke(ctx, sessions, p.SessionID, now)
}

// LogoutAll revokes every session of the caller's account after a recent
// sign-in.
func LogoutAll(ctx context.Context, sessions session.Store, p authn.Principal, now time.Time) error {
	if now.Sub(p.AuthTime) > recentAuth {
		return ErrReauthRequired
	}
	return sessions.RevokeAll(ctx, p.AccountID, now)
}

// RemoveSession signs one of the caller's devices out.
func RemoveSession(ctx context.Context, sessions session.Store, p authn.Principal, id uuid.UUID, now time.Time) error {
	s, err := sessions.Get(ctx, id)
	if err == session.ErrNotFound || (err == nil && s.AccountID() != p.AccountID) {
		return ErrSessionNotFound
	}
	if err != nil {
		return err
	}
	return revoke(ctx, sessions, id, now)
}

// POST /v1/auth/logout
func LogoutHandler(sessions session.Store, now func() time.Time, log *slog.Logger) http.Handler {
	return noContent(log, func(r *http.Request, p authn.Principal) error { return Logout(r.Context(), sessions, p, now()) })
}

// POST /v1/auth/logout-all
func LogoutAllHandler(sessions session.Store, now func() time.Time, log *slog.Logger) http.Handler {
	return noContent(log, func(r *http.Request, p authn.Principal) error { return LogoutAll(r.Context(), sessions, p, now()) })
}

// DELETE /v1/auth/sessions/{id}
func RemoveSessionHandler(sessions session.Store, now func() time.Time, log *slog.Logger) http.Handler {
	return noContent(log, func(r *http.Request, p authn.Principal) error {
		id, err := uuid.Parse(r.PathValue("id"))
		if err != nil {
			return ErrSessionNotFound
		}
		return RemoveSession(r.Context(), sessions, p, id, now())
	})
}

// noContent runs a signed-in action and answers 204.
func noContent(log *slog.Logger, do func(*http.Request, authn.Principal) error) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, ok := principal(w, r, log)
		if !ok {
			return
		}
		if err := do(r, p); err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
```

`noContent` takes a function, which is HTTP plumbing in the handler layer; the use cases above it take none.

Create `internal/auth/session_list.go`:

```go
package auth

import (
	"context"
	"log/slog"
	"net/http"
	"strconv"
	"time"
	"uuid"

	"github.com/shopnexus/server2/internal/auth/session"
	"github.com/shopnexus/server2/internal/platform/apperr"
	"github.com/shopnexus/server2/internal/platform/authn"
	"github.com/shopnexus/server2/internal/platform/httpx"
)

const defaultPageSize = 20

var errBadPage = apperr.New(apperr.KindBadRequest, "invalid_request", "cursor or limit is not valid")

type SessionItem struct {
	ID         uuid.UUID `json:"id"`
	DeviceName string    `json:"device_name"`
	CreatedAt  time.Time `json:"created_at"`
	LastUsedAt time.Time `json:"last_used_at"`
	Current    bool      `json:"current"`
}

type SessionPage struct {
	Items      []SessionItem `json:"items"`
	NextCursor *uuid.UUID    `json:"next_cursor,omitempty"`
}

// ListSessions lists the caller's devices, newest first. A zero cursor starts
// at the newest; a zero limit means 20.
func ListSessions(ctx context.Context, sessions session.Store, p authn.Principal, cursor uuid.UUID, limit int, now time.Time) (SessionPage, error) {
	if limit == 0 {
		limit = defaultPageSize
	}
	rows, err := sessions.ListActive(ctx, p.AccountID, now, cursor, limit+1)
	if err != nil {
		return SessionPage{}, err
	}
	page := SessionPage{Items: []SessionItem{}}
	for i, v := range rows {
		if i == limit {
			next := rows[limit-1].ID
			page.NextCursor = &next
			break
		}
		page.Items = append(page.Items, SessionItem{ID: v.ID, DeviceName: v.DeviceName, CreatedAt: v.CreatedAt,
			LastUsedAt: v.LastUsedAt, Current: v.ID == p.SessionID})
	}
	return page, nil
}

// GET /v1/auth/sessions
func ListSessionsHandler(sessions session.Store, now func() time.Time, log *slog.Logger) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p, ok := principal(w, r, log)
		if !ok {
			return
		}
		var cursor uuid.UUID
		var limit int
		q := r.URL.Query()
		if c := q.Get("cursor"); c != "" {
			id, err := uuid.Parse(c)
			if err != nil {
				httpx.WriteError(w, r, log, errBadPage)
				return
			}
			cursor = id
		}
		if l := q.Get("limit"); l != "" {
			n, err := strconv.Atoi(l)
			if err != nil || n < 1 || n > 100 {
				httpx.WriteError(w, r, log, errBadPage)
				return
			}
			limit = n
		}
		page, err := ListSessions(r.Context(), sessions, p, cursor, limit, now())
		if err != nil {
			httpx.WriteError(w, r, log, err)
			return
		}
		httpx.Respond(w, r, http.StatusOK, page)
	})
}
```

`internal/auth/routes.go`, in `Routes`:

```go
	protect := RequireAuth(k.Verifier, now, log)
	r.Handle("POST /v1/auth/logout", protect(LogoutHandler(p.Sessions, now, log)))
	r.Handle("POST /v1/auth/logout-all", protect(LogoutAllHandler(p.Sessions, now, log)))
	r.Handle("GET /v1/auth/sessions", protect(ListSessionsHandler(p.Sessions, now, log)))
	r.Handle("DELETE /v1/auth/sessions/{id}", protect(RemoveSessionHandler(p.Sessions, now, log)))
```

Run: `go test -race ./internal/auth/`
Expected: PASS.

- [ ] **Step 4: Write the E2E tests**

Append to `e2e/auth_session_test.go` (imports `time`, `session`):

```go
type sessionPage struct {
	Items []struct {
		ID      string `json:"id"`
		Current bool   `json:"current"`
	} `json:"items"`
	NextCursor string `json:"next_cursor"`
}

func sessionOf(t *testing.T, accessToken string) string {
	t.Helper()
	p, err := session.NewVerifier(keys).Verify(accessToken, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return p.SessionID.String()
}

func TestLogoutRevokesRefresh(t *testing.T) {
	acc, _ := newAccount(t)
	if res := call(t, server, "POST", "/v1/auth/logout", nil, bearer(acc.AccessToken)); res.Status != 204 {
		t.Fatalf("logout: %d %s", res.Status, res.Body)
	}
	if res := refresh(t, acc.RefreshToken); res.Status != 401 || errorOf(t, res).Code != "session_revoked" {
		t.Fatalf("refresh after logout: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "GET", "/v1/accounts/me", nil, bearer(acc.AccessToken)); res.Status != 200 {
		t.Fatalf("the access token lives until it expires: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", "/v1/auth/logout", nil); res.Status != 401 {
		t.Fatalf("no token: %d %s", res.Status, res.Body)
	}
}

func TestLogoutAll(t *testing.T) {
	first, phone := newAccount(t)
	second := signInWith(t, phone)
	p, _ := session.NewVerifier(keys).Verify(second.AccessToken, time.Now())
	stale, _, _ := session.NewSigner(keys).Sign(p.AccountID, p.SessionID, time.Now().Add(-20*time.Minute), time.Now())
	if res := call(t, server, "POST", "/v1/auth/logout-all", nil, bearer(stale)); res.Status != 428 || errorOf(t, res).Code != "reauth_required" {
		t.Fatalf("stale sign-in: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "POST", "/v1/auth/logout-all", nil, bearer(second.AccessToken)); res.Status != 204 {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
	for _, token := range []string{first.RefreshToken, second.RefreshToken} {
		if res := refresh(t, token); res.Status != 401 {
			t.Fatalf("refresh after logout-all: %d %s", res.Status, res.Body)
		}
	}
	if res := call(t, server, "POST", "/v1/auth/logout-all", nil); res.Status != 401 {
		t.Fatalf("no token: %d %s", res.Status, res.Body)
	}
}

func TestSessionsListAndRemove(t *testing.T) {
	first, phone := newAccount(t)
	second := signInWith(t, phone)
	res := call(t, server, "GET", "/v1/auth/sessions", nil, bearer(second.AccessToken))
	page := decode[sessionPage](t, res)
	if res.Status != 200 || len(page.Items) != 2 || page.Items[0].ID != sessionOf(t, second.AccessToken) || !page.Items[0].Current {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
	one := decode[sessionPage](t, call(t, server, "GET", "/v1/auth/sessions?limit=1", nil, bearer(second.AccessToken)))
	rest := decode[sessionPage](t, call(t, server, "GET", "/v1/auth/sessions?limit=1&cursor="+one.NextCursor, nil, bearer(second.AccessToken)))
	if len(rest.Items) != 1 || rest.Items[0].ID != sessionOf(t, first.AccessToken) {
		t.Fatalf("pages %+v, %+v", one, rest)
	}
	for path, want := range map[string]int{"/v1/auth/sessions?limit=0": 400} {
		if res := call(t, server, "GET", path, nil, bearer(second.AccessToken)); res.Status != want {
			t.Fatalf("%s: %d %s", path, res.Status, res.Body)
		}
	}
	if res := call(t, server, "GET", "/v1/auth/sessions", nil); res.Status != 401 {
		t.Fatalf("no token: %d", res.Status)
	}
	if res := call(t, server, "DELETE", "/v1/auth/sessions/"+sessionOf(t, first.AccessToken), nil, bearer(second.AccessToken)); res.Status != 204 {
		t.Fatalf("remove: %d %s", res.Status, res.Body)
	}
	if res := refresh(t, first.RefreshToken); res.Status != 401 {
		t.Fatalf("removed device refreshes: %d", res.Status)
	}
	if res := call(t, server, "DELETE", "/v1/auth/sessions/not-a-uuid", nil, bearer(second.AccessToken)); res.Status != 400 {
		t.Fatalf("bad id: %d %s", res.Status, res.Body)
	}
	if res := call(t, server, "DELETE", "/v1/auth/sessions/"+sessionOf(t, second.AccessToken), nil); res.Status != 401 {
		t.Fatalf("no token: %d", res.Status)
	}
}

// TestSessionsOfAnotherAccount is the spec's ownership attack test.
func TestSessionsOfAnotherAccount(t *testing.T) {
	a, _ := newAccount(t)
	b, _ := newAccount(t)
	aSession := sessionOf(t, a.AccessToken)
	for _, s := range decode[sessionPage](t, call(t, server, "GET", "/v1/auth/sessions", nil, bearer(b.AccessToken))).Items {
		if s.ID == aSession {
			t.Fatal("B sees A's session")
		}
	}
	if res := call(t, server, "DELETE", "/v1/auth/sessions/"+aSession, nil, bearer(b.AccessToken)); res.Status != 404 || errorOf(t, res).Code != "session_not_found" {
		t.Fatalf("status %d: %s", res.Status, res.Body)
	}
	if res := refresh(t, a.RefreshToken); res.Status != 200 {
		t.Fatalf("A's session after B's attempt: %d %s", res.Status, res.Body)
	}
}
```

- [ ] **Step 5: Run and commit**

Run: `make lint && make test`
Expected: PASS, every declared status of `logout`, `logoutAll`, `listSessions`, `deleteSession` observed.

```bash
git add -A
git commit -m "feat(auth): sign out one device, every device, and list devices"
```

### Task 13: Run it by hand and record the rulings

**Files:**
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: Sign in with curl against the dev stack**

```bash
make up && make migrate && make run   # make keys first when .env has none
curl -s localhost:8080/v1/auth/otp -H 'Content-Type: application/json' -H "Idempotency-Key: $(uuidgen)" \
  -d '{"kind":"phone","destination":"0901234567","purpose":"login"}'
curl -s localhost:8080/v1/auth/otp/verify -H 'Content-Type: application/json' -H "Idempotency-Key: $(uuidgen)" \
  -d '{"challenge_id":"<id>","code":"<code from the server log>","device_name":"curl"}'
curl -s localhost:8080/v1/accounts/me -H "Authorization: Bearer <access_token>"
```

Expected: a challenge, tokens with `"is_new":true`, the account with `"status":"active"`. The Restate UI (`http://127.0.0.1:56570`) lists the `OTP/Send` and `SignIn/Run` invocations and their journals hold no code and no token. Grafana shows the verify request's trace and the `login_total` point. Record the three responses, tokens shortened, in the ledger.

- [ ] **Step 2: Record the rulings in `ARCHITECTURE.md`**

Add a section `### Restate in practice` holding, as decided facts: services invoked with an idempotency key stand in for workflows; Restate runs on the host network on 127.0.0.1 ports and the server registers its endpoint over HTTP/1.1 at start; codes are derived from the challenge ID and the verify handler passes `code_hash`; refusals travel in results; tests prefix service names. Run the `humanizing-writing` checker on the new text.

```bash
git add ARCHITECTURE.md
git commit -m "docs: record how Restate is wired"
```

- [ ] **Step 3: Final suite and review**

Run: `make lint && make test`
Expected: PASS. Then the final whole-branch review per the executing skill.
