# Design: server2 chat

Date: 2026-10-26.
Status: decided in conversation, question by question and section by
section. When the work lands, the decisions below go into
`~/shopnexus/server2/ARCHITECTURE.md`.

## Scope

A buyer messages a seller from a listing; the two then write back and
forth, with photos, in one conversation per pair of people that also shows
their deals. The app learns of new messages and deal moves while it is
open through a server-sent event stream. Each person reads, archives and
blocks. Reports, push notifications to a closed app, typing indicators and
message editing are out of scope.

## Decisions

| Question | Decision |
|---|---|
| Conversation | One per pair of people, whatever their roles; it holds every deal between them, both ways. |
| Realtime | Server-sent events at `GET /v1/stream` while the app is open; sending stays a plain POST. |
| Stream content | Hints only (`message`, `read`, `deal` with an ID); the app reloads what it shows. Nothing is replayed, so a reconnect needs no `Last-Event-ID`. |
| Starting a chat | From a listing: the buyer writes first on someone else's active listing. |
| Content | Text 1–1,000 characters and/or 1–4 photos; a message may name a listing. |
| Inbox state | Per member: read up to a message, archived. |
| Blocking | Now, in module account; reports come with moderation. |

## Rules

### Conversation

- One row per pair, stored as `(account_a, account_b)` with `account_a <
  account_b`, unique.
- Each member has `last_read_message_id` and `archived_at`. A message sent
  after `archived_at` brings the conversation back to that member's inbox.
- `POST /v1/conversations {listing_id, text, photos}` opens it: the caller
  is not suspended, has a verified phone, writes about someone else's
  active listing, and is not blocked by its seller. A pair that already has
  a conversation reuses it, and the first message of the call names the
  listing.

### Message

- Text 1–1,000 characters after trimming, photos 1–4 uploads of the
  sender; at least one of the two. A message may name a listing of either
  member.
- A message without photos is `sent` at once. A message with photos is
  `processing` until media has processed them, then `sent`, or `failed`
  with the reason. Only the sender sees a message that is not `sent`.
- No edit, no delete.
- `POST /v1/conversations/{id}/messages` with `Idempotency-Key`: the
  sender is a member, not suspended, and neither member blocks the other.

### Reading and archiving

- `POST /v1/conversations/{id}/read {message_id}` sets the caller's marker
  to that message when it is newer than the marker; an older one leaves
  the marker where it is.
- Unread: the other member's `sent` messages after the caller's marker.
- `POST /v1/conversations/{id}/archive` and `/unarchive`.

### Blocking

- `POST /v1/blocks {account_id}`, `DELETE /v1/blocks/{account_id}`, `GET
  /v1/blocks`.
- A person who is blocked cannot send to the blocker, open a conversation
  with them or open a deal on their listings (403 `blocked`). The blocker's
  inbox leaves the conversation out; the blocker cannot send either until
  they unblock. Running deals and orders are left as they are.

## API

| Endpoint | Purpose |
|---|---|
| `POST /v1/conversations {listing_id, text, photos}` + `Idempotency-Key` | Open or reuse the pair's conversation and send the first message. 201 with the conversation. |
| `GET /v1/conversations?archived=false\|true` | The inbox, newest message first: the other person, the last message the caller may see, unread count. |
| `GET /v1/conversations/{id}` | The conversation with the deals between the two (the deal views of module deal). |
| `GET /v1/conversations/{id}/messages` | Messages, newest first, cursor pagination. |
| `POST /v1/conversations/{id}/messages {text, photos, listing_id}` + `Idempotency-Key` | Send. |
| `POST /v1/conversations/{id}/read {message_id}` | Mark read. |
| `POST /v1/conversations/{id}/archive`, `/unarchive` | Archive, unarchive. |
| `GET /v1/me/unread` | The caller's unread count over unarchived conversations. |
| `GET /v1/stream` | Server-sent events. |
| `POST /v1/blocks`, `DELETE /v1/blocks/{account_id}`, `GET /v1/blocks` | Blocking. |

Errors: 403 `account_suspended`, `phone_required`, `blocked`; 404
`conversation_not_found` (anyone but a member), `listing_not_found`; 409
`own_listing`, `listing_unavailable`; 422 `invalid_message` with fields
`text`, `photos`, `listing_id`, and `invalid_upload` from media.

## Stream

- `stream.Notify(ctx, tx, accounts, hint)` runs `pg_notify('stream',
  payload)` in the transaction of the change, so Postgres sends it on
  commit and drops it on rollback, as `events.Insert` does.
- `stream.Hub` listens on channel `stream` on a connection of its own and
  hands each hint to the open streams of the accounts it names. App starts
  it with the events bus and stops it on close.
- `GET /v1/stream` answers `text/event-stream`: an event `ready` on
  connect, then `message {conversation_id, message_id}`, `read
  {conversation_id}` and `deal {deal_id}`, and a comment every 25 seconds.
- The chat repository notifies both members when a message becomes `sent`,
  the sender alone while it is `processing` or `failed`, and the other
  member on a read. The deal repository notifies the buyer and the seller
  on every save.

## Flows

- `MessageSend.Run`, called through `restatex.Caller` with the key
  `<sender id>/<Idempotency-Key>`: check the sender and the conversation,
  insert the message (`sent`, or `processing` with photos), attach its
  photos to it in media (holder: the message), then send `MessagePublish`
  with the message ID as key. A refused attach deletes the message again,
  as `ListingPost` does with a listing.
- `MessagePublish.Run`: `MediaProcess` for each photo, then `sent` with the
  photo keys, or `failed` with the reason.
- Opening a conversation runs the same flow after the conversation row is
  inserted or found.

## Modules

```
internal/platform/stream/  Notify, Hub, the SSE handler
internal/chat/
  domain/  repository/  service/ (message_send_durable.go, message_publish_durable.go)
  handler/  chat.go (Mount)
internal/account/          blocks: repository, Block, Unblock, Blocks, Blocked(a, b), /v1/blocks
internal/deal/             Open refuses a blocked buyer; Between(a, b) lists the pair's deals
```

`chat` calls `account` (suspended, blocks), `auth` (phone), `catalog`
(listing), `media` (attach, process, URLs) and `deal` (the pair's deals).
`deal` calls `account` for blocks, so no module calls back into `chat`.

## Data

- `conversations (id, account_a, account_b, last_message_id, created_at)`,
  unique `(account_a, account_b)`, check `account_a < account_b`. The inbox
  pages by `last_message_id`, a UUIDv7, newest first.
- `conversation_members (conversation_id, account_id, last_read_message_id,
  archived_at)`, primary key `(conversation_id, account_id)`.
- `messages (id, conversation_id, sender_id, body, photos jsonb,
  listing_id, status, failure, created_at)`; `body` because `text` is an
  SQL keyword.
- `account_blocks (blocker_id, blocked_id, created_at)`, primary key
  `(blocker_id, blocked_id)`.

## Tests

- Domain: message content rules, an older read marker leaving the newer
  one, archive and a new message.
- Repository: one conversation per pair in either order; unread counts;
  inbox paging and archive filter.
- Stream: a hint reaches only the accounts it names; a rolled-back
  transaction sends nothing.
- Flows with restatetest: a text message; a photo message from processing
  to sent; a failed photo; a repeated key sends one message; a refused
  attach leaves no message.
- Blocking: send, open and a deal open refused.
- e2e: every declared status observed, and one test that reads
  `/v1/stream` and gets a `message` hint after the other member sends.
