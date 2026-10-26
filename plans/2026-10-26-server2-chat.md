# server2 chat: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buyer messages a seller from a listing; both then chat with text and photos in one conversation per pair of people, see their deals there, read, archive and block; the open app learns of changes through `GET /v1/stream`.

**Architecture:** Blocks live in module `account` (both `chat` and `deal` check them). A platform package `stream` carries hints: `stream.Notify` runs `pg_notify('stream', …)` in the transaction of the change, and `stream.Hub` listens on its own connection and fans hints out to SSE connections by account. A new module `chat` holds conversations, members and messages; sending runs as the Restate flow `MessageSend`, and photo messages finish in `MessagePublish` through media's `MediaProcess`.

**Tech Stack:** Go 1.27, pgx v5, Restate Go SDK v1.1.0, Postgres 18.

**Spec:** `~/shopnexus/specs/2026-10-26-server2-chat-design.md`

## Global Constraints

- One conversation per unordered pair, stored with `account_a < account_b`.
- Opening: from someone else's active listing; not suspended, verified phone, no block between the two. Sending: a member, not suspended, no block either way.
- Message: text 1–1,000 runes after trimming and/or 1–4 photos of the sender; optional listing. `processing` messages and `failed` ones are visible to the sender only.
- Every send takes an `Idempotency-Key`; the invocation key is `<sender id>/<Idempotency-Key>`.
- A block refuses send, open and deal open with 403 `blocked`, in either direction; it cancels nothing running.
- Stream events: `ready`, `message {conversation_id, message_id}`, `read {conversation_id}`, `deal {deal_id}`; a comment every 25 seconds; hints only, no replay.
- No SQL keyword as a column name (`body`, not `text`). No update callbacks in business code. A use case reads top to bottom.
- No commits unless the user asks; each task ends on a green `make test`.
- Comments, docs and migration comments go through the humanizing checker.

## Review Focus

1. A stream connection outlives the server's 30 s `WriteTimeout`: the handler clears its write deadline with `http.ResponseController` (Task 2 `TestHandlerStreams` streams past a 1 s server `WriteTimeout`).
2. A hint for account A never reaches account B's stream (Task 2 `TestHintReachesOnlyItsAccounts`).
3. A photo message whose attach is refused leaves no message behind, and a retried send with the same key sends one message (Task 5).
4. A conversation archived by A comes back to A's inbox when B writes after the archive (Task 4 repository test).
5. A blocked buyer cannot open a deal on the blocker's listing, nor message them (Tasks 1 and 5).

---

### Task 1: blocks in module account, checked by deal

**Files:**
- Create: `migrations/0012_blocks.sql`
- Modify: `internal/account/repository/account.go`, `account_pg.go`, `account_pg_test.go`; `internal/account/service/service.go`, create `block.go`, `block_test.go`; `internal/account/handler/handler.go`, create `block.go`; `internal/account/domain/errors.go`
- Modify: `internal/deal/service/deal_open.go`, `deal_test.go`
- Modify: `api/openapi.yaml`, `api/paths/account.yaml`, `api/schemas/account.yaml`; create `e2e/block_test.go`

**Interfaces:**
- Produces: `repository.Accounts` gains `Block(ctx, blocker, blocked uuid.UUID, at time.Time) error` (a repeat changes nothing), `Unblock(ctx, blocker, blocked uuid.UUID) error`, `Blocked(ctx, a, b uuid.UUID) (bool, error)` (either direction), `ListBlocks(ctx, blocker uuid.UUID, p page.Request) ([]Block, error)` with `Block{AccountID uuid.UUID; At time.Time}`. `accountsvc.Service` gains `Block(ctx, blocker, blocked uuid.UUID) error`, `Unblock(ctx, blocker, blocked uuid.UUID) error`, `Blocked(ctx, a, b uuid.UUID) (bool, error)`, `Blocks(ctx, blocker uuid.UUID, p page.Request) (page.Page[BlockView], error)` with `BlockView{AccountID uuid.UUID; DisplayName string; At time.Time}`. Errors: `domain.ErrBlocked` (403 `blocked`), `domain.ErrSelfBlock` (422 `invalid_block`).

- [ ] **Step 1: Migration** `0012_blocks.sql`:

  ```sql
  -- Blocks: blocker no longer hears from blocked, in chat or deals, and
  -- writes to them no more either.

  CREATE TABLE account_blocks (
      blocker_id uuid NOT NULL REFERENCES accounts (id),
      blocked_id uuid NOT NULL REFERENCES accounts (id),
      created_at timestamptz NOT NULL,
      PRIMARY KEY (blocker_id, blocked_id),
      CHECK (blocker_id <> blocked_id)
  );

  CREATE INDEX account_blocks_blocked ON account_blocks (blocked_id, blocker_id);
  ```
- [ ] **Step 2: Failing tests.** Repository `TestBlocks`: block twice → one row; `Blocked(a, b)` and `Blocked(b, a)` both true; `ListBlocks` newest first; unblock → false. Service `TestBlock`: blocking oneself → `ErrSelfBlock`; an unknown account → `ErrAccountNotFound`; `Blocks` carries display names. Deal `TestOpenRefusesABlockedBuyer`: seller blocks the buyer → `Open` is `accountdomain.ErrBlocked`; the buyer blocks the seller → the same.
- [ ] **Step 3: Run** `go test ./internal/account/... ./internal/deal/...` → build failure.
- [ ] **Step 4: Implement.** SQL `INSERT ... ON CONFLICT DO NOTHING`, `DELETE`, `SELECT EXISTS (... WHERE (blocker_id = @a AND blocked_id = @b) OR (blocker_id = @b AND blocked_id = @a))`, and a keyset list on `created_at, blocked_id` read as newest first (`page.Request.Cursor` is the blocked account; the list is short, so read `p.Fetch()` rows ordered by `created_at DESC` and page by position of the cursor's row: `WHERE created_at < (SELECT created_at FROM account_blocks WHERE blocker_id = @blocker AND blocked_id = @cursor)` when a cursor is set). `Service.Block` checks self and existence through `Get`, then `Block` with `now`. Deal `Open`, after the phone check and before `own_listing`: `blocked, err := s.accounts.Blocked(ctx, buyer, l.SellerID)` → `accountdomain.ErrBlocked`.
- [ ] **Step 5: API and handler.** `POST /v1/blocks {account_id}` → 204 (`blockAccount`: 400, 401, 404, 422); `DELETE /v1/blocks/{account_id}` → 204 (`unblockAccount`: 400, 401); `GET /v1/blocks` → `BlockList {items: [{account_id, display_name, at}], next_cursor}` (`listBlocks`: 200, 400, 401). `openDeal` declares 403 `blocked` in its 403 description. e2e `TestBlocks` observes every status, including a blocked buyer's `POST /v1/deals` → 403 `blocked`.
- [ ] **Step 6: Run** `make test` → green.

### Task 2: the stream

**Files:**
- Create: `internal/platform/stream/stream.go`, `hub.go`, `handler.go`, `stream_test.go`
- Modify: `internal/app/app.go` (start and stop the hub, register `GET /v1/stream` behind `protect` in `mountModules`), `internal/deal/repository/deal_pg.go` (notify on save)
- Modify: `api/openapi.yaml`, `api/paths/system.yaml` or a new `api/paths/stream.yaml`; `e2e/stream_test.go`

**Interfaces:**
- Produces (package `stream`):

  ```go
  // Hint names what changed for the app to reload.
  type Hint struct {
  	Kind           string     `json:"-"`
  	ConversationID *uuid.UUID `json:"conversation_id,omitempty"`
  	MessageID      *uuid.UUID `json:"message_id,omitempty"`
  	DealID         *uuid.UUID `json:"deal_id,omitempty"`
  }

  const (
  	KindMessage = "message"
  	KindRead    = "read"
  	KindDeal    = "deal"
  )

  // Notify sends h to the streams of accounts when tx commits.
  func Notify(ctx context.Context, tx pgx.Tx, accounts []uuid.UUID, h Hint) error

  func NewHub(db *pgxpool.Pool, log *slog.Logger) *Hub
  func (h *Hub) Run(ctx context.Context) error            // until ctx is done
  func (h *Hub) Subscribe(account uuid.UUID) (<-chan Hint, func())
  func (h *Hub) Handler(log *slog.Logger) http.Handler     // GET /v1/stream; needs authn
  ```

- [ ] **Step 1: Failing tests** (`stream_test.go`, on `pgtest`):
  - `TestHintReachesOnlyItsAccounts`: a running hub; subscribe A and B; `Notify(tx, [A], deal hint)` and commit → A receives it within 5 s, B receives nothing within 500 ms.
  - `TestRollbackSendsNothing`: notify in a transaction that rolls back → nothing within 500 ms.
  - `TestHandlerStreams`: an `httptest.Server` with `WriteTimeout` 1 s serving `hub.Handler` behind a fake `authn` principal; read `event: ready`; notify; read `event: deal` with `{"deal_id":…}` after 1.5 s (past the write timeout).
- [ ] **Step 2: Run** → build failure.
- [ ] **Step 3: Implement.**
  - The notify payload is `{"accounts":[…],"kind":"deal","hint":{…}}` as JSON; `Notify` runs `SELECT pg_notify('stream', @payload)`.
  - `Hub.Run` follows `events.Bus.listen`: its own `pgx.ConnectConfig`, `LISTEN stream`, `WaitForNotification` in a loop, reconnect after a second on error, return nil when `ctx` is done. Each subscriber has a channel buffered to 16; a full channel drops the hint (the app reloads on its next hint or reconnect).
  - `Handler`: account from `authn.From`; `http.NewResponseController(w).SetWriteDeadline(time.Time{})`; headers `Content-Type: text/event-stream`, `Cache-Control: no-store`; write `event: ready\ndata: {}\n\n`, flush; then loop on the subscription, `r.Context().Done()` and a 25 s ticker that writes `: keep-alive\n\n`; each hint as `event: <kind>\ndata: <json>\n\n`, flushed.
  - `app.New` builds the hub, starts `hub.Run` beside the bus with the same stop and done pattern, and `Close` stops it first. `mountModules` registers `GET /v1/stream` with `protect(hub.Handler(log))`.
  - Deal `Save` calls `stream.Notify(ctx, tx, []uuid.UUID{buyer, seller}, stream.Hint{Kind: stream.KindDeal, DealID: &id})` after its writes, and not on the "already saved" path.
- [ ] **Step 4: API.** `GET /v1/stream` (`openStream`): 200 `text/event-stream` (string schema, described events), 401. The e2e response validator must accept a streamed body; if it reads to EOF, give the e2e client a stream helper that records the status and stops after the first events.
- [ ] **Step 5: e2e** `TestStreamGetsADealHint`: buyer opens the stream, reads `ready`; seller and buyer agree a price; the buyer's stream reads `event: deal` with the deal's ID within 5 s. A request without a token → 401.
- [ ] **Step 6: Run** `make test` → green.

### Task 3: chat domain

**Files:**
- Create: `internal/chat/domain/chat.go`, `errors.go`, `chat_test.go`

**Interfaces:**
- Produces:
  - `MessageStatus` (`processing`, `sent`, `failed`); `Photo{UploadID uuid.UUID; PhotoKey, ThumbKey string}` with JSON tags.
  - `Message` (unexported fields; getters; `MessageState` with JSON tags; `RestoreMessage`), `NewMessage(id, conversation, sender uuid.UUID, body string, photos []uuid.UUID, listing *uuid.UUID, now time.Time) (Message, error)`: trims; 0–1,000 runes; 0–4 photos without duplicates; at least one of the two (field `text` "1 to 1,000 characters, or photos"); status `sent` without photos, `processing` with; `(m *Message) Published(keys map[uuid.UUID]Photo)`, `Failed(reason string)`, `VisibleTo(account uuid.UUID) bool`.
  - `Conversation{ID, AccountA, AccountB uuid.UUID; CreatedAt time.Time}` with `NewConversation(id, one, other uuid.UUID, now) Conversation` ordering the pair by `bytes.Compare`, `Has(account) bool`, `Other(account) uuid.UUID`.
  - `Member{ConversationID, AccountID uuid.UUID; LastRead uuid.UUID; ArchivedAt *time.Time}` with `Read(message uuid.UUID) bool` (true when it moved the marker: a newer UUIDv7 by `bytes.Compare`), `Archive(now)`, `Unarchive()`.
  - Errors: `ErrNotFound` (404 `conversation_not_found`), `ErrInvalidMessage` (422 `invalid_message`), `ErrPhoneRequired` (403 `phone_required`), `ErrOwnListing` (409 `own_listing`), `ErrListingUnavailable` (409 `listing_unavailable`).
- [ ] **Step 1: Failing tests:** the content rules (empty, 1,001 runes, 5 photos, a duplicate photo, text only, photos only); statuses; `VisibleTo` for sender and other on processing, sent, failed; `NewConversation(b, a)` equals `NewConversation(a, b)` on the pair; `Read` with older, equal and newer IDs.
- [ ] **Step 2: Run** → build failure. **Step 3: Implement.** **Step 4: Run** → PASS; `make test` → green.

### Task 4: chat migration and repository

**Files:**
- Create: `migrations/0013_chat.sql`, `internal/chat/repository/repository.go`, `chat_pg.go`, `chat_pg_test.go`

**Interfaces:**
- Produces `repository.Chats`:

  ```go
  type Chats interface {
  	// OpenPair inserts c with both members unless the pair has a
  	// conversation, and returns the pair's conversation.
  	OpenPair(ctx context.Context, c domain.Conversation) (domain.Conversation, error)
  	// Get returns ErrNotFound for an unknown id.
  	Get(ctx context.Context, id uuid.UUID) (domain.Conversation, error)
  	// AddMessage inserts m (a repeat of its ID does nothing), moves the
  	// conversation's last message when m is sent, and notifies the members
  	// m is visible to.
  	AddMessage(ctx context.Context, m domain.Message) error
  	// DeleteMessage removes a message the send flow could not finish.
  	DeleteMessage(ctx context.Context, id uuid.UUID) error
  	// GetMessage returns ErrNotFound for an unknown id.
  	GetMessage(ctx context.Context, id uuid.UUID) (domain.Message, error)
  	// SaveMessage writes a processed or failed message, moves the last
  	// message when it is sent, and notifies as AddMessage.
  	SaveMessage(ctx context.Context, m domain.Message) error
  	Member(ctx context.Context, conversation, account uuid.UUID) (domain.Member, error)
  	// SaveMember writes the marker and the archive; a moved marker
  	// notifies the other member with a read hint.
  	SaveMember(ctx context.Context, m domain.Member, other uuid.UUID, read bool) error
  	// Messages lists the messages viewer may see, IDs below p.Before(),
  	// newest first, at most p.Fetch().
  	Messages(ctx context.Context, conversation, viewer uuid.UUID, p page.Request) ([]domain.Message, error)
  	// Inbox lists viewer's conversations with the last message, the
  	// unread count and the other member, archived or not, without those
  	// with a member viewer blocks, by last message, newest first.
  	Inbox(ctx context.Context, viewer uuid.UUID, archived bool, p page.Request) ([]InboxRow, error)
  	// Unread counts viewer's unread messages over unarchived conversations.
  	Unread(ctx context.Context, viewer uuid.UUID) (int, error)
  }
  ```

  with `InboxRow{Conversation domain.Conversation; Other uuid.UUID; Last domain.Message; Unread int}`.

- [ ] **Step 1: Migration** `0013_chat.sql`:

  ```sql
  -- Chat: one conversation per pair of people, whatever their roles, and
  -- its messages. A member reads up to a message and may archive the
  -- conversation; a message after the archive brings it back.

  CREATE TABLE conversations (
      id              uuid PRIMARY KEY,
      account_a       uuid NOT NULL REFERENCES accounts (id),
      account_b       uuid NOT NULL REFERENCES accounts (id),
      last_message_id uuid,
      last_message_at timestamptz,
      created_at      timestamptz NOT NULL,
      UNIQUE (account_a, account_b),
      CHECK (account_a < account_b)
  );

  CREATE TABLE conversation_members (
      conversation_id      uuid NOT NULL REFERENCES conversations (id),
      account_id           uuid NOT NULL REFERENCES accounts (id),
      last_read_message_id uuid,
      archived_at          timestamptz,
      PRIMARY KEY (conversation_id, account_id)
  );

  CREATE INDEX conversation_members_account ON conversation_members (account_id);

  CREATE TABLE messages (
      id              uuid PRIMARY KEY,
      conversation_id uuid NOT NULL REFERENCES conversations (id),
      sender_id       uuid NOT NULL REFERENCES accounts (id),
      body            text NOT NULL CHECK (char_length(body) <= 1000),
      photos          jsonb NOT NULL,
      listing_id      uuid REFERENCES listings (id),
      status          text NOT NULL CHECK (status IN ('processing', 'sent', 'failed')),
      failure         text,
      created_at      timestamptz NOT NULL
  );

  CREATE INDEX messages_conversation ON messages (conversation_id, id);
  ```
- [ ] **Step 2: Failing tests:** `OpenPair` twice with the pair swapped → one conversation and two members; `AddMessage` twice → one row; a processing message is not the last message and only its sender lists it; `SaveMessage` to sent moves the last message; `Inbox` order by last message, unread counts (`id > last_read` of the other's sent messages), archive filter, a message after `ArchivedAt` back in the unarchived list (Review Focus 4), a blocked member's conversation absent from the blocker's inbox; `Unread` sums unarchived.
- [ ] **Step 3: Run** → FAIL. **Step 4: Implement** with `stream.Notify` in `AddMessage`, `SaveMessage` and `SaveMember`. The inbox query joins `conversation_members m` for the viewer, `messages` for the last message, a correlated count for unread, filters `archived` as `m.archived_at IS NOT NULL AND c.last_message_at <= m.archived_at` (true) or its negation (false), excludes `EXISTS (SELECT 1 FROM account_blocks WHERE blocker_id = viewer AND blocked_id = other)`, pages by `c.last_message_id < @before`, and leaves out conversations without a sent message. **Step 5: Run** → PASS; `make test` → green.

### Task 5: chat service and flows

**Files:**
- Create: `internal/chat/service/service.go`, `views.go`, `conversation_open.go`, `message_send.go`, `message_send_durable.go`, `message_publish_durable.go`, `conversation_read.go` (read, archive, unarchive), `conversation_get.go` (inbox, conversation, messages, unread); tests `helpers_test.go`, `chat_test.go`, `flow_test.go`
- Modify: `internal/deal/service` (add `Between`), `internal/deal/deal.go` (return `Mounted{Services, Service}`), `internal/app/app.go`

**Interfaces:**
- Consumes: `accountsvc.Service.Status`, `Blocked`, `Get` (display names); `authsvc.Service.Identities`; `catalogsvc.Service.Summaries`; `mediasvc.Service.Attach`, `URL`, `MediaProcessService`; `dealsvc.Service.Between`.
- Produces `chatsvc.Service`: `Open(ctx, buyer uuid.UUID, idempotencyKey string, in OpenInput) (ConversationView, error)` with `OpenInput{ListingID uuid.UUID; Text string; Photos []uuid.UUID}`; `Send(ctx, sender, conversation uuid.UUID, idempotencyKey string, in SendInput) (MessageView, error)` with `SendInput{Text string; Photos []uuid.UUID; ListingID *uuid.UUID}`; `Read(ctx, account, conversation, message uuid.UUID) error`; `Archive`, `Unarchive(ctx, account, conversation uuid.UUID) error`; `Inbox(ctx, account uuid.UUID, archived bool, p page.Request) (page.Page[InboxItem], error)`; `Get(ctx, account, conversation uuid.UUID) (ConversationView, error)` (with `Deals []dealsvc.DealView`); `Messages(ctx, account, conversation uuid.UUID, p page.Request) (page.Page[MessageView], error)`; `Unread(ctx, account uuid.UUID) (int, error)`. `dealsvc.Service.Between(ctx, viewer, other uuid.UUID) ([]DealView, error)`.
- [ ] **Step 1: Failing tests** (helpers build account, auth, catalog, media, deal and chat services on the test stack and start chat's and media's flows):
  - `TestOpenAndSend`: the buyer opens from the seller's listing with text → conversation with one sent message naming the listing; opening again from another listing of the same seller reuses it; the seller sends back; `Inbox` of each shows the other and the last message; `Unread` counts 1 for the buyer; `Read` brings it to 0.
  - `TestOpenRefusals`: no phone, suspended, own listing, hidden listing, unknown listing, a block either way.
  - `TestSendRefusals`: a stranger → `conversation_not_found`; a block → `blocked`; empty text and no photos → `invalid_message`.
  - `TestPhotoMessage` (flow): a JPEG upload; the sender sees it processing then sent with URLs; the other member sees it only when sent.
  - `TestFailedPhoto`: an upload whose bytes are not a JPEG → failed for the sender, never visible to the other.
  - `TestRefusedAttachLeavesNoMessage`: another account's upload → `invalid_upload`; `Messages` holds nothing new.
  - `TestRepeatedKeySendsOnce`: two sends with one key → one message.
  - `TestConversationShowsDeals`: a deal between the pair, both ways, appears in `Get`.
  - `TestArchive`: archive, the other sends, the conversation is back.
- [ ] **Step 2: Run** → build failure.
- [ ] **Step 3: Implement** `MessageSend.Run(ctx, in SendFlowInput) (SendResult, error)` with `SendFlowInput{Sender uuid.UUID; ConversationID *uuid.UUID; ListingID *uuid.UUID; Opening bool; Text string; Photos []uuid.UUID}` and `SendResult{ConversationID, MessageID uuid.UUID; Refused *apperr.Error}`:
  1. `at := restatex.Now`; one step checks the sender: suspended → refusal.
  2. Opening: one step reads the listing (`Summaries`), then phone, own listing, active, block; another inserts or finds the pair with `OpenPair` and `restatex.NewID(ctx, at)` as the new ID. Not opening: one step loads the conversation, refuses a non-member with `ErrNotFound`, checks the block.
  3. `domain.NewMessage(restatex.NewID(ctx, at), …)` → refusal on invalid content.
  4. Step `AddMessage`.
  5. With photos: the `attach` step as in `ListingPost` (media's non-internal error is a refusal); a refusal runs a `DeleteMessage` step and returns it. Then `restate.ServiceSend(ctx, prefix+messagePublish, "Run").Send(id, restate.WithIdempotencyKey(id.String()))`.

  `MessagePublish.Run(ctx, id uuid.UUID) error` follows `ListingPublish`: load step, `MediaProcess` futures keyed by upload ID, then `Published` or `Failed`, `SaveMessage` step. `Open` and `Send` call `MessageSend` through `restatex.Caller` with `<sender>/<key>` and read the result back. Deal `Between` lists deals where the pair are buyer and seller either way (`repository.Deals.Between(ctx, a, b)`: `WHERE (buyer_id = @a AND seller_id = @b) OR (buyer_id = @b AND seller_id = @a) ORDER BY d.id DESC`), viewed for `viewer`.
- [ ] **Step 4: Run** `go test ./internal/chat/... ./internal/deal/...` → PASS; `make test` → green.

### Task 6: chat API, handler and e2e

**Files:**
- Create: `api/paths/chat.yaml`, `api/schemas/chat.yaml`, `internal/chat/handler/*.go`, `internal/chat/chat.go`, `e2e/chat_test.go`
- Modify: `api/openapi.yaml`, `internal/app/app.go`, `tmp/gen_depguard.py` (add `chat`) and `.golangci.yml`

- [ ] **Step 1: Spec** for the endpoints of the chat spec, with these statuses:
  - `openConversation` `POST /v1/conversations` + key: 201, 400, 401, 403 (`account_suspended`, `phone_required`, `blocked`), 404 (`listing_not_found`), 409 (`own_listing`, `listing_unavailable`), 422 (`invalid_message`, `invalid_upload`).
  - `listConversations` `GET /v1/conversations?archived=`: 200, 400, 401.
  - `getConversation` `GET /v1/conversations/{id}`: 200, 400, 401, 404.
  - `listMessages` `GET /v1/conversations/{id}/messages`: 200, 400, 401, 404.
  - `sendMessage` `POST /v1/conversations/{id}/messages` + key: 201, 400, 401, 403, 404, 422.
  - `readConversation` `POST /v1/conversations/{id}/read {message_id}`: 204, 400, 401, 404.
  - `archiveConversation`, `unarchiveConversation`: 204, 400, 401, 404.
  - `getUnread` `GET /v1/me/unread`: 200 `{unread}`, 401.
  - Schemas: `ConversationOpen`, `MessageDraft`, `Message {id, sender_id, text, photos[{upload_id, url?, thumb_url?}], listing_id?, status, failure?, created_at}`, `Conversation {id, other {id, display_name}, deals: [Deal], archived}`, `InboxItem {id, other, last_message, unread, archived}`, `ConversationList`, `MessageList`, `Unread`.
- [ ] **Step 2: Run** `go test ./internal/app/` → `TestRoutesMatchSpec` fails for the ten operations.
- [ ] **Step 3: Handlers and Mount** like deal's, with `serve`-style binding; `chat.Mount(d, protect, accounts, auth, catalog, media, deals) []restate.ServiceDefinition`. Regenerate depguard with `chat`.
- [ ] **Step 4: e2e** `TestChat` (open, reply, inbox, unread, read, archive, a photo message reaching sent) and `TestChatRefusals` (every declared status), plus `TestStreamGetsAMessageHint`: the seller's stream reads `event: message` with the conversation ID after the buyer opens it.
- [ ] **Step 5: Run** `make test` → green.

### Task 7: ARCHITECTURE.md

- [ ] **Step 1:** A `### Chat` section and a `### Stream` section, and a blocks bullet under `### Aggregates in auth and account` or the Deal section: the decisions of the spec as facts, the hint-only stream and why there is no replay, the write-deadline clearing, `stream.Notify` in the change's transaction, blocks in account and why (no cycle), `MessageSend` for every send, processing messages visible to their sender only.
- [ ] **Step 2:** Humanizing checker on the new text; fix every hit.
- [ ] **Step 3: Run** `make test` → green.
