# Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-app notification list and FCM push, fed by the events of deal, chat, catalog, trust and account.

**Architecture:** Source modules emit events in their write transactions. Module `notification` subscribes a Restate worker to them; each handler reads the facts through the source module's service, decides in its domain who gets which notice, writes the notices with a stream hint in one transaction, and pushes each recipient's tokens in steps of their own. Push goes through `internal/provider/push` (a log sender in development, FCM HTTP v1 in production).

**Tech Stack:** Go 1.27, pgx v5 (StrictNamedArgs), Restate Go SDK v1.1.0, ParadeDB/Postgres 18, `golang.org/x/oauth2` v0.37.0 (`google.CredentialsFromJSON`).

**Spec:** `~/shopnexus/specs/2026-10-27-server2-notification-design.md`

## Global Constraints

- Configuration has no defaults. `FCM_CREDENTIALS` (base64 service account JSON; empty means the log sender) and `FCM_PROJECT_ID` (empty with an empty `FCM_CREDENTIALS`) are both set in `.env.example`, `FCM_*` empty there.
- The server writes every text in Vietnamese from stored type and params; the app gets `text`, `type` and `target`.
- Collapse: at most one unread notice per `(account_id, collapse_key)`; `deal:<id>` for deal and order notices, `listing:<id>` for listing notices, none for review and account notices. Chat pushes collapse on `conversation:<id>` and are never listed.
- Chat push body: sender name, then the first 100 characters, or "gửi N ảnh".
- Notices older than 90 days are deleted when the recipient gets a new one.
- A redelivered event writes no second notice and pushes once.
- Suspended accounts are notified.
- A use case or Restate handler reads top to bottom; no helper called from only one place; no update callbacks. Every SQL statement uses `pgx.StrictNamedArgs`.
- Scratch files in `tmp/`. Prose in files goes through `python3 ~/.claude/skills/humanizing-writing/ai-tells.py`. Full-suite runs go through `make test` only.

## Review Focus

1. A deal move the worker cannot find (the event names a move ID a replayed save never committed): skip it, no error loop. Test in Task 5.
2. A push to a session that ended (logout, revoke, refresh reuse, expiry): the token is deleted and nothing is sent. Test in Task 6.
3. An older event delivered after a newer one on the same deal: the notice keeps the newer content. Test in Task 4.
4. FCM answers 429 or 5xx: the step errs so Restate retries, and tokens already sent in earlier steps are not sent again. Test in Task 3 (sender) and Task 6 (worker, one step per token).
5. `POST /v1/notifications/{id}/read` on someone else's notice: 404, nothing changes. Test in Task 7.

---

## File Structure

```
migrations/0020_notifications.sql              notifications, push_tokens
internal/platform/events/events.go             MessageSent, ListingRejected, ReviewPosted
internal/platform/stream/stream.go             KindNotification, Hint.NotificationID
internal/platform/config/config.go             PushConfig
internal/provider/push/push.go                 Sender, Message, LogSender, FCM, ErrDeadToken, ErrRetry
internal/deal/repository/deal_pg.go            deal.moved carries move IDs
internal/deal/service/moves.go                 Moves(ctx, dealID, ids) → MoveFacts
internal/chat/repository/chat_pg.go            message.sent in written()
internal/chat/service/message_facts.go         MessageFacts
internal/catalog/service/listing_publish_durable.go  listing.rejected
internal/trust/repository/review_pg.go         Insert in a tx with review.posted
internal/trust/service/review_facts.go         ReviewFacts
internal/account/service/account_suspend.go    payload until
internal/auth/service/session_active.go        ActiveSessions
internal/notification/                         domain, repository, service, handler, worker, notification.go
internal/screen/service/home.go                notifications_unread
api/…                                          spec for the endpoints
e2e/notification_test.go, e2e/push_stub_test.go
ARCHITECTURE.md                                Notifications section
```

---

### Task 1: The events

**Files:**
- Modify: `internal/platform/events/events.go` (kinds), `internal/deal/repository/deal_pg.go` (Save), `internal/chat/repository/chat_pg.go` (`written`), `internal/catalog/service/listing_publish_durable.go`, `internal/trust/repository/review_pg.go` (Insert), `internal/account/service/account_suspend.go`
- Test: `internal/deal/repository/deal_pg_test.go`, `internal/chat/repository/chat_pg_test.go`, `internal/catalog/service/flow_test.go`, `internal/trust/repository/review_pg_test.go`, `internal/account/service/account_suspend_test.go`

**Interfaces:**
- Produces: `events.MessageSent = "message.sent"` (SubjectID the message, event ID the message ID), `events.ListingRejected = "listing.rejected"`, `events.ReviewPosted = "review.posted"` (SubjectID and event ID the review ID); `deal.moved` payload `"moves": []string` of move IDs; `account.suspended` payload `"until": RFC 3339 string` when set.

- [ ] **Step 1: Failing tests.** Each test reads the `events` table after the write (`SELECT kind, subject_id, payload FROM events WHERE subject_id = @id`):
  - deal repository: a save with an offer writes `deal.moved` whose `payload->'moves'` holds the offer's move ID;
  - chat repository: `AddMessage` of a sent message writes one `message.sent` with ID = the message ID; a processing message writes none; `SaveMessage` turning it sent writes it then; a second `SaveMessage` writes no second row;
  - catalog flow test: a listing whose photo is refused writes `listing.rejected`;
  - trust repository: `Insert` writes `review.posted` with ID = the review ID; `Save` writes none;
  - account service: `Suspend` with an `Until` writes `payload->>'until'`.
- [ ] **Step 2: Run them** — FAIL (no such events / no payload).
- [ ] **Step 3: Implement.**
  - `events.go`: add the three kinds after `DealMoved`, each with a one-line comment of what it says.
  - `deal_pg.go` `Save`: before inserting each event, for `e.Kind == events.DealMoved` set `e.Payload = map[string]any{"moves": ids}` where `ids` are `d.Pending()` move IDs as strings. Comment: "The moves' IDs ride on deal.moved, so a subscriber reads exactly the moves of this save."
  - `chat_pg.go` `written`: inside the `if m.Status() == domain.StatusSent` branch, `events.Insert(ctx, tx, events.Event{ID: m.ID(), Kind: events.MessageSent, SubjectID: m.ID(), OccurredAt: m.CreatedAt()})`. The message ID as the event ID makes a retried write insert nothing (`ON CONFLICT (id) DO NOTHING`).
  - `listing_publish_durable.go`: in the `len(reasons) > 0` branch append `events.Event{ID: restatex.NewID(ctx, at), Kind: events.ListingRejected, SubjectID: id, OccurredAt: at}`.
  - `review_pg.go` `Insert`: wrap the insert in `pgx.BeginFunc` and, when one row was inserted, `events.Insert(ctx, tx, events.Event{ID: r.ID(), Kind: events.ReviewPosted, SubjectID: r.ID(), OccurredAt: r.CreatedAt()})`.
  - `account_suspend.go`: the suspended event gets `Payload: map[string]any{"until": r.SuspendedUntil.Format(time.RFC3339)}` when `SuspendedUntil` is set.
- [ ] **Step 4: Run** `go test -race -count=1 ./internal/deal/... ./internal/chat/... ./internal/catalog/... ./internal/trust/... ./internal/account/... ./internal/platform/events/...` → PASS.
- [ ] **Step 5: Commit** `feat: events for messages, rejections, reviews and deal moves`.

---

### Task 2: Facts for the worker

**Files:**
- Create: `internal/deal/service/moves.go`, `internal/chat/service/message_facts.go`, `internal/trust/service/review_facts.go`, `internal/auth/service/session_active.go` (+ `_test.go` each)
- Modify: each module's `service.go` interface; `internal/auth/repository/session.go` + `session_pg.go` (`ActiveAmong`)

**Interfaces:**
- Produces:

```go
// dealsvc
type MoveFact struct {
	ID     uuid.UUID
	Kind   domain.MoveKind
	By     domain.Party
	Amount int64
}
type MoveFacts struct {
	DealID, ListingID, BuyerID, SellerID uuid.UUID
	ListingTitle, BuyerName, SellerName  string
	Moves                                []MoveFact // of ids, in order; an id the deal lacks is left out
	Order                                *domain.Order // the deal's latest order
}
Moves(ctx context.Context, dealID uuid.UUID, ids []uuid.UUID) (MoveFacts, bool, error) // false for an unknown deal

// chatsvc
type MessageFacts struct {
	ID, ConversationID, SenderID, RecipientID uuid.UUID
	SenderName, Text string // Text is the first 100 runes of the body
	Photos           int
}
MessageFacts(ctx context.Context, id uuid.UUID) (MessageFacts, bool, error)

// trustsvc
type ReviewFacts struct {
	ID, SellerID, ListingID uuid.UUID
	BuyerName, ListingTitle string
	Stars                   int
}
ReviewFacts(ctx context.Context, id uuid.UUID) (ReviewFacts, bool, error)

// authsvc
ActiveSessions(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID]bool, error) // not revoked, not expired
```

- [ ] **Step 1: Failing tests** in each module's service tests (use the package's env helper):
  - deal: open a deal, offer, then `Moves(dealID, [offerMoveID, uuid.NewV7()])` returns one fact `{Kind: offer, By: buyer, Amount}`, both names, the title; an unknown deal answers false;
  - chat: a sent text message of 150 runes gives `Text` of 100 runes, `RecipientID` the other member, `SenderName`; a photo message gives `Photos`;
  - trust: a posted review gives buyer name, stars, title;
  - auth: of an active, a revoked and an expired session, only the first is true.
- [ ] **Step 2: Run** → FAIL to compile.
- [ ] **Step 3: Implement.** Each reads what it needs in a fixed number of queries: deal through `deals.Find` (or the existing deal read) plus `accounts.GetMany` and `catalog.Summaries`; chat through its message and member reads plus `accounts.GetMany`; trust through `reviews` by ID (add `Get(ctx, id)` to the repository if missing) plus accounts and catalog; auth through `ActiveAmong(ctx, ids, now)`:

```sql
SELECT id FROM sessions WHERE id = ANY(@ids) AND revoked_at IS NULL AND expires_at > @now
```

  The move kinds come from the deal's stored moves; read how `deal_get.go` loads them and filter by `ids`.
- [ ] **Step 4: Run** `go test -race -count=1 ./internal/deal/... ./internal/chat/... ./internal/trust/... ./internal/auth/...` → PASS.
- [ ] **Step 5: Commit** `feat: facts other modules read for notifications`.

---

### Task 3: The push provider and its configuration

**Files:**
- Create: `internal/provider/push/push.go`, `internal/provider/push/push_test.go`
- Modify: `internal/platform/config/config.go`, `config_test.go`, `.env.example`, `go.mod` (`golang.org/x/oauth2 v0.37.0`)

**Interfaces:**

```go
package push

// Message is one push: what the notification shows and the data the app
// opens it with. Tag replaces an earlier push with the same tag.
type Message struct {
	Title, Body string
	Tag         string
	Data        map[string]string
}

// Sender delivers a push to one device token.
type Sender interface {
	Send(ctx context.Context, token string, m Message) error
}

var (
	// ErrDeadToken is a token FCM no longer delivers to; delete it.
	ErrDeadToken = errors.New("push token is no longer valid")
	// ErrRetry is a failure worth retrying (429, 5xx).
	ErrRetry = errors.New("push failed, retry")
)

type LogSender struct{ Log *slog.Logger }

// FCM sends through FCM HTTP v1. New reads the service account JSON.
type FCM struct { /* project, endpoint, client */ }
func NewFCM(ctx context.Context, credentialsJSON []byte, projectID string) (*FCM, error)
```

`config.PushConfig{Credentials []byte, ProjectID string}` from `FCM_CREDENTIALS` (`set`, base64-decoded when non-empty) and `FCM_PROJECT_ID` (`set`; required non-empty when credentials are set).

- [ ] **Step 1: Failing tests** (`push_test.go`) against an `httptest.Server` standing in for `https://fcm.googleapis.com/v1/projects/p/messages:send`: give `FCM` an endpoint field the test overrides and an `HTTP` client (the test uses `srv.Client()` without OAuth). Cases: 200 → nil, and the body has `message.token`, `message.notification.title/body`, `message.android.notification.tag`, `message.android.collapse_key`, `message.data`; 404 with `"errorCode":"UNREGISTERED"` → `ErrDeadToken`; 400 with `"status":"INVALID_ARGUMENT"` → `ErrDeadToken`; 429 and 503 → `ErrRetry`; 403 → another error. Config tests: the two keys in `required()` (empty), and credentials set without a project fails naming `FCM_PROJECT_ID`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement.** `NewFCM` uses `google.CredentialsFromJSON(ctx, json, "https://www.googleapis.com/auth/firebase.messaging")` and `oauth2.NewClient(ctx, creds.TokenSource)`. `Send` POSTs:

```json
{"message":{"token":"…","notification":{"title":"…","body":"…"},
 "android":{"collapse_key":"<tag>","notification":{"tag":"<tag>"}},"data":{…}}}
```

  and maps the status as the tests say (decode `error.status` and `error.details[].errorCode`). `LogSender.Send` logs title, tag and the token's last 6 characters, never the body. `go get golang.org/x/oauth2@v0.37.0`.
- [ ] **Step 4: Run** `go test -race -count=1 ./internal/provider/push/ ./internal/platform/config/` → PASS.
- [ ] **Step 5: Commit** `feat: the push provider, FCM HTTP v1 and a log sender`.

---

### Task 4: Notification domain and store

**Files:**
- Create: `migrations/0020_notifications.sql`
- Create: `internal/notification/domain/notice.go`, `notice_test.go`, `errors.go`
- Create: `internal/notification/repository/repository.go`, `notice_pg.go`, `notice_pg_test.go`

**Interfaces:**

```go
// domain
type Type string // offer counter agreed declined agreement_cancelled offer_voided cod_requested shipped
                 // delivered returned order_cancelled listing_live listing_rejected review suspended unsuspended
type Notice struct {
	Recipient   uuid.UUID
	Type        Type
	CollapseKey string         // "" does not collapse
	Params      map[string]any // names, title, amount, carrier, code, reason, stars, until
	At          time.Time
}
// FromMoves decides the notices of a deal's new moves.
func FromMoves(f DealFacts, at time.Time) []Notice
type DealFacts struct { // the notification module's own copy of what it reads from deal
	DealID, ListingID, BuyerID, SellerID uuid.UUID
	Title, BuyerName, SellerName         string
	Moves                                []Move
	Carrier, TrackingCode, CancelReason  string
}
type Move struct{ Kind string; By string; Amount int64 }
func Text(t Type, p map[string]any) string
func Title(t Type) string      // the push title: "Trả giá", "Đơn hàng", "Tin đăng", "Đánh giá", "Tài khoản"
type Target struct{ Kind string `json:"kind"`; ID string `json:"id"` }
func TargetOf(t Type, p map[string]any) Target
func ChatBody(sender, text string, photos int) string
const Retention = 90 * 24 * time.Hour
var ErrNotFound *apperr.Error // notification_not_found, 404

// repository
type Notices interface {
	// Add writes n for event, collapsing on the recipient's unread notice
	// with the same key unless that one is newer; an event already written
	// for the recipient changes nothing. It deletes the recipient's notices
	// older than expired and notifies the stream, in one transaction, and
	// returns the notice's ID.
	Add(ctx context.Context, event uuid.UUID, n domain.Notice, expired time.Time) (uuid.UUID, error)
	List(ctx context.Context, account uuid.UUID, p page.Request) ([]Row, error) // newest bumped first
	Unread(ctx context.Context, account uuid.UUID) (int, error)
	Read(ctx context.Context, account, id uuid.UUID, at time.Time) error // ErrNotFound for another's
	ReadAll(ctx context.Context, account uuid.UUID, at time.Time) error
	PutToken(ctx context.Context, session, account uuid.UUID, token string, at time.Time) error
	DeleteToken(ctx context.Context, session uuid.UUID) error
	Tokens(ctx context.Context, account uuid.UUID) ([]Token, error) // {Session uuid.UUID; Token string}
}
```

- [ ] **Step 1: Migration** `0020_notifications.sql`:

```sql
-- What a person is told: one row per notice, collapsing on a key while
-- unread. params holds what the text is written from.
CREATE TABLE notifications (
    id           uuid PRIMARY KEY,
    account_id   uuid NOT NULL REFERENCES accounts (id),
    notice_type  text NOT NULL,
    collapse_key text,
    params       jsonb NOT NULL,
    event_id     uuid NOT NULL,
    read_at      timestamptz,
    created_at   timestamptz NOT NULL,
    bumped_at    timestamptz NOT NULL
);
CREATE UNIQUE INDEX notifications_unread_key ON notifications (account_id, collapse_key)
WHERE read_at IS NULL AND collapse_key IS NOT NULL;
CREATE INDEX notifications_list ON notifications (account_id, bumped_at DESC, id DESC);
CREATE INDEX notifications_event ON notifications (account_id, event_id);

-- One FCM token per sign-in session.
CREATE TABLE push_tokens (
    session_id uuid PRIMARY KEY,
    account_id uuid NOT NULL REFERENCES accounts (id),
    token      text NOT NULL,
    updated_at timestamptz NOT NULL
);
CREATE INDEX push_tokens_account ON push_tokens (account_id);
```

(`notice_type` keeps `type` out of the columns.) Run `sqlfluff lint`.

- [ ] **Step 2: Failing domain tests** (`notice_test.go`), table-driven over moves:
  - `offer` by buyer → seller, type offer, collapse `deal:<id>`, params amount;
  - `counter` by seller → buyer; `accept` by buyer → seller `agreed`, by seller → buyer;
  - `decline` by seller → buyer `declined`; `withdraw` → nothing; `cancel` by buyer → seller `agreement_cancelled`;
  - `price_changed`, `offers_closed`, `listing_closed` (by system) → buyer `offer_voided` with reason;
  - `cod_requested` → seller; `shipped` → buyer with carrier and code; `delivered`, `returned` → buyer;
  - `order_cancelled` by buyer → seller, by seller → buyer, by system with reason `sent_to_another` or `listing_closed` → buyer;
  - texts: `Text(offer, {buyer: "Đức Huy", amount: 1200000, title: "Xe đạp Asama"})` is "Đức Huy trả 1,2 tr cho Xe đạp Asama"; amounts under a million read "350.000 ₫"; `suspended` with until "2026-11-03T…" reads "Tài khoản của bạn bị khoá đến 3/11", without it "Tài khoản của bạn bị khoá";
  - `ChatBody("Hoàng Nam", "Còn không bạn?", 0)` is "Hoàng Nam: Còn không bạn?", with no text and 2 photos "Hoàng Nam gửi 2 ảnh";
  - `TargetOf`: deal types → `{deal, <deal id>}`, order types → `{order, <deal id>}`, listing types → `{listing, id}`, review → `{seller_reviews, seller id}`, account types → `{account, ""}`.
- [ ] **Step 3: Run** → FAIL; **implement** `notice.go` (the text table is a `map[Type]func(p) string`; money: ≥1,000,000 as millions with a comma decimal and " tr", else dots and " ₫"); **run** → PASS.
- [ ] **Step 4: Failing repository tests** (`notice_pg_test.go`):
  - two `Add`s on one key while unread → one row with the second's params, bumped to the second's time; after `Read`, a third `Add` makes a new row;
  - an `Add` with an older `At` than the unread row's keeps the newer params (Review Focus 3);
  - the same event twice for a non-collapsing notice → one row;
  - `Add` deletes the recipient's rows older than `expired`, no one else's;
  - `List` orders by `bumped_at` then `id`, pages by cursor; `Unread` counts;
  - `Read` of another account's notice → `ErrNotFound`; `ReadAll` marks only the caller's;
  - `PutToken` twice for one session keeps one row with the newer token; `DeleteToken`; `Tokens`.
- [ ] **Step 5: Implement** `notice_pg.go`. `Add` in one `pgx.BeginFunc`:
  1. `SELECT id FROM notifications WHERE account_id = @a AND event_id = @e` → return it if found;
  2. delete `WHERE account_id = @a AND created_at < @expired`;
  3. with a key: `INSERT … ON CONFLICT (account_id, collapse_key) WHERE read_at IS NULL AND collapse_key IS NOT NULL DO UPDATE SET notice_type = excluded.notice_type, params = excluded.params, event_id = excluded.event_id, bumped_at = excluded.bumped_at WHERE notifications.bumped_at <= excluded.bumped_at RETURNING id`, falling back to selecting the unread row's ID when the guarded update returns nothing; without a key a plain insert;
  4. `stream.Notify(ctx, tx, []uuid.UUID{n.Recipient}, stream.Hint{Kind: stream.KindNotification, NotificationID: &id})`.

  Add `KindNotification = "notification"` and `NotificationID *uuid.UUID \`json:"notification_id,omitempty"\`` to `internal/platform/stream/stream.go`. Paging uses `page.Request` with the cursor as the last ID; list `WHERE (bumped_at, id) < (SELECT bumped_at, id FROM notifications WHERE id = @cursor)` when a cursor is given.
- [ ] **Step 6: Run** `go test -race -count=1 ./internal/notification/... ./internal/platform/stream/` → PASS.
- [ ] **Step 7: Commit** `feat: notification rules and store`.

---

### Task 5: The worker

**Files:**
- Create: `internal/notification/worker/worker.go`, `worker_test.go`

**Interfaces:**
- Consumes: Task 1 events, Task 2 facts, Task 3 `push.Sender`, Task 4 domain and `Notices`.
- Produces: `type Worker struct{ Prefix string; Notices repository.Notices; Deals dealsvc.Service; Chats chatsvc.Service; Catalog catalogsvc.Service; Trust trustsvc.Service; Accounts accountsvc.Service; Auth authsvc.Service; Push push.Sender; Log *slog.Logger; Now func() time.Time }`, `ServiceName() = Prefix + "NotificationWorker"`, handlers `DealMoved`, `MessageSent`, `ListingPublished`, `ListingRejected`, `ReviewPosted`, `AccountSuspended`, `AccountUnsuspended`, each `func(restate.Context, events.Event) error`.

- [ ] **Step 1: Failing tests** with restatetest and a recording fake `push.Sender` (counts sends per token; can be set to answer `ErrDeadToken` or `ErrRetry` once):
  - `DealMoved` for an offer writes one notice for the seller and pushes to the seller's token once; delivering the same event again writes no second notice and sends nothing more;
  - an event naming a move ID the deal lacks writes nothing and returns nil (Review Focus 1);
  - `MessageSent` pushes "Name: text" with tag `conversation:<id>` and lists nothing;
  - `ListingRejected`, `ReviewPosted`, `AccountSuspended` each write their type.
- [ ] **Step 2: Implement** each handler top to bottom:
  1. one `restate.Run` reading the facts (for `DealMoved`, the IDs from `e.Payload["moves"]`); not found → return nil;
  2. the domain decision;
  3. per notice one `restate.Run` calling `Notices.Add(ctx, e.ID, n, now.Add(-domain.Retention))`;
  4. per recipient the push (Task 6 adds the token checks; here call `w.deliver`, the one helper every handler shares).
- [ ] **Step 3: Run** `go test -race -count=1 ./internal/notification/...` → PASS.
- [ ] **Step 4: Commit** `feat: the notification worker`.

---

### Task 6: Push delivery

**Files:**
- Modify: `internal/notification/worker/worker.go` (`deliver`), `worker_test.go`

- [ ] **Step 1: Failing tests:**
  - a recipient with two tokens, one of a revoked session: only the active one is sent to, and the revoked one's token row is gone (Review Focus 2);
  - the sender answers `ErrDeadToken` for a token: the row is deleted, the handler returns nil;
  - the sender answers `ErrRetry` once for the second of two tokens: the handler retries, the first token is sent once in total (Review Focus 4);
  - another error is logged and dropped.
- [ ] **Step 2: Implement** `deliver(ctx restate.Context, account uuid.UUID, m push.Message) error`: one step reads `Notices.Tokens` and `Auth.ActiveSessions`, deletes the inactive ones and returns the active tokens; then one `restate.Run` per token sends, mapping `ErrDeadToken` to a delete and nil, `ErrRetry` to a returned error (Restate retries that step alone), any other error to a warning and nil.
- [ ] **Step 3: Run** `go test -race -count=1 ./internal/notification/...` → PASS.
- [ ] **Step 4: Commit** `feat: push only to active sessions, drop dead tokens`.

---

### Task 7: Service, endpoints, wiring

**Files:**
- Create: `internal/notification/service/service.go`, `notices.go`, `notices_test.go`; `internal/notification/handler/handler.go`; `internal/notification/notification.go`
- Modify: `internal/app/app.go` (mount, `WithPushSender` option, sender from config), `api/openapi.yaml`, `api/paths/notification.yaml`, `api/schemas/notification.yaml`, `tmp/gen_depguard.py` (add `notification` to `mods`, regenerate `.golangci.yml`)

**Interfaces:**

```go
type Item struct {
	ID     uuid.UUID     `json:"id"`
	Type   domain.Type   `json:"type"`
	Text   string        `json:"text"`
	Target domain.Target `json:"target"`
	Unread bool          `json:"unread"`
	At     time.Time     `json:"at"`
}
type List struct {
	Items      []Item     `json:"items"`
	NextCursor *uuid.UUID `json:"next_cursor,omitempty"`
	Unread     int        `json:"unread"`
}
type Service interface {
	List(ctx context.Context, account uuid.UUID, p page.Request) (List, error)
	Unread(ctx context.Context, account uuid.UUID) (int, error)
	Read(ctx context.Context, account, id uuid.UUID) error
	ReadAll(ctx context.Context, account uuid.UUID) error
	PutToken(ctx context.Context, p authn.Principal, token string) error
	DeleteToken(ctx context.Context, p authn.Principal) error
}
```

- [ ] **Step 1: Failing service tests:** `List` writes text and target from params; `Read` of another's is `ErrNotFound`; `PutToken` with an empty or over-4096-byte token is 422 `invalid_push_token`.
- [ ] **Step 2: Implement** the service and the handlers: `GET /v1/notifications`, `POST /v1/notifications/{id}/read`, `POST /v1/notifications/read-all`, `PUT /v1/me/push-token {token}`, `DELETE /v1/me/push-token`, all behind protect. `notification.Mount(d, protect, deps…, sender push.Sender)` builds the worker and subscribes it: `deal.moved → DealMoved`, `message.sent → MessageSent`, `listing.published → ListingPublished`, `listing.rejected → ListingRejected`, `review.posted → ReviewPosted`, `account.suspended → AccountSuspended`, `account.unsuspended → AccountUnsuspended`; it returns the Restate services and the Service. App builds the sender: `push.LogSender` when `cfg.Push.Credentials` is empty, else `push.NewFCM`; `app.WithPushSender` replaces it (e2e).
- [ ] **Step 3: OpenAPI** for the five operations (200/204, 400, 401, 404 on read, 422 on put-token), schemas `NotificationList`, `Notification`, `Target`, `PushToken`. The stream's event list in its description gains `notification`.
- [ ] **Step 4: Run** `go test -race -count=1 ./internal/notification/... ./internal/app/ ./api/` and `golangci-lint run ./internal/notification/... ./internal/app/...` → PASS, 0 issues.
- [ ] **Step 5: Commit** `feat: notification endpoints and wiring`.

---

### Task 8: Home badge, e2e, record, full run

**Files:**
- Modify: `internal/screen/service/home.go` (+ `Deps.Notifications`), `internal/screen/screen.go`, `api/schemas/screen_home.yaml`
- Create: `e2e/push_stub_test.go`, `e2e/notification_test.go`; modify `e2e/main_test.go`
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1: e2e stub**: a `push.Sender` that records `(token, Message)`; `TestMain` passes it with `app.WithPushSender`.
- [ ] **Step 2: Failing e2e** `TestNotifications`:
  - the seller puts a push token; a buyer offers on the seller's listing; within 30 s the seller's `GET /v1/notifications` has an `offer` with the buyer's name and `target.kind = deal`, `unread` 1, and the stub got one push on the token;
  - a counter makes the buyer's notice, a second offer replaces the seller's unread notice (one row, new amount);
  - `POST …/read` → 204 and `unread` 0; a stranger's read of it → 404; `read-all` → 204;
  - the buyer sends a chat message; the seller's token gets "Name: text", the list does not grow;
  - the seller logs out; the next push to the seller sends nothing to that token;
  - `PUT /v1/me/push-token` with an empty token → 422; signed out → 401; `GET /v1/screens/home?near_commune=00004` as the seller shows `notifications_unread`.
- [ ] **Step 3: Implement** `notifications_unread` in Home (`Notifications.Unread` when a reader is signed in, 0 otherwise; schema field required integer).
- [ ] **Step 4: Run** `go test -race -count=1 ./e2e/ -run 'TestNotifications|TestHomeScreen'` → PASS.
- [ ] **Step 5: ARCHITECTURE.md** `### Notifications`: the types and texts by group, collapse keys and the unread rule, the guard against an older event, the event-ID check, retention by deletion on write, the worker's steps, push per token with the active-session check, the FCM provider and `FCM_*` variables, chat pushes not listed, suspended accounts notified. Run the prose checker.
- [ ] **Step 6: Full run** `GOFLAGS=-count=1 make test` → all ok, `0 issues.`
- [ ] **Step 7: Commit** `docs: notification decisions` (and the e2e and Home changes in `feat: notifications on Home and in e2e`).
