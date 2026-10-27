# Design: server2 notifications

Date: 2026-10-27.
Status: decided in conversation, question by question. When the work
lands, the decisions below go into `~/shopnexus/server2/ARCHITECTURE.md`.

## Scope

A person learns what happened to their deals, orders, listings, reviews
and account through a list in the app and a push to their Android phone
when the app is closed. A new chat message is pushed and stays out of the
list, since the inbox already lists it. Notification settings, email or
SMS notices, and the price alerts of saved listings come later.

## Decisions

| Question | Decision |
|---|---|
| Scope | The in-app list with a badge, and push through Firebase Cloud Messaging. |
| What notifies | Negotiation, COD orders, chat messages (push only), listings, reviews, the account. |
| Text | The server writes it in Vietnamese from stored type and parameters, when it lists and when it pushes. |
| Several moves on one deal | A new one replaces the person's unread notice of the same deal and moves it to the top; a read one stays and a new notice starts. |
| Chat push content | The sender's name and the first 100 characters, or "gửi 2 ảnh". |
| Device token | One per sign-in session; logout, revocation or FCM reporting it dead deletes it. |
| Retention | 90 days, then deleted. |
| Suspended accounts | Still notified, so they learn of the suspension. |

## API

| Endpoint (module notification, signed in) | Purpose |
|---|---|
| `GET /v1/notifications?cursor=&limit=` | `{items, next_cursor, unread}`, newest first by `bumped_at`. An item is `{id, type, text, target {kind, id}, unread, at}`. |
| `POST /v1/notifications/{id}/read` | 204; someone else's or an unknown ID is 404 `notification_not_found`. |
| `POST /v1/notifications/read-all` | 204. |
| `PUT /v1/me/push-token {token}` | 204; stores the FCM token for the caller's session, replacing any. |
| `DELETE /v1/me/push-token` | 204; absent is fine. |

The stream sends `notification {id}` to the recipient. `GET
/v1/screens/home` gains `notifications_unread`.

## Types

| Type | To | Text |
|---|---|---|
| `offer` | seller | "Đức Huy trả 1,2 tr cho Xe đạp Asama" |
| `counter` | buyer | "Hoàng Nam trả lại 1,4 tr cho Xe đạp Asama" |
| `agreed` | the other side | "Chốt 1,3 tr Xe đạp Asama với Hoàng Nam" |
| `declined` | who made the price | "Hoàng Nam không đồng ý 1,2 tr cho Xe đạp Asama" |
| `agreement_cancelled` | the other side | "Hoàng Nam huỷ giá đã chốt Xe đạp Asama" |
| `offer_voided` | buyer | "Xe đạp Asama đã đổi, giá bạn đề nghị hết hiệu lực" |
| `cod_requested` | seller | "Đức Huy yêu cầu COD Xe đạp Asama" |
| `shipped` | buyer | "Hoàng Nam đã gửi Xe đạp Asama · GHN 8A2K9" |
| `delivered` | buyer | "Xe đạp Asama đã giao. Đánh giá Hoàng Nam" |
| `returned` | buyer | "Xe đạp Asama bị hoàn về Hoàng Nam" |
| `order_cancelled` | the other side, or the buyer when the system cancels | "Đức Huy huỷ đơn Xe đạp Asama", "Xe đạp Asama đã gửi cho người khác, đơn của bạn đã huỷ", "Xe đạp Asama không còn bán, đơn của bạn đã huỷ" |
| `listing_live` | seller | "Xe đạp Asama đã lên" |
| `listing_rejected` | seller | "Xe đạp Asama chưa lên được: một ảnh bị từ chối" |
| `review` | seller | "Đức Huy chấm 5 sao cho Xe đạp Asama" |
| `suspended`, `unsuspended` | the account | "Tài khoản của bạn bị khoá đến 3/11", "Tài khoản của bạn đã được mở khoá" |

`target.kind` is `deal`, `order`, `listing`, `seller_reviews` or
`account`. Deal and order notices collapse on `deal:<id>`, listing notices
on `listing:<id>`; reviews and account notices do not collapse.

## Events

| Event | Module | Change |
|---|---|---|
| `deal.moved` | deal | Payload `moves`: the IDs of the moves the save wrote. |
| `message.sent` | chat | New, when a message becomes `sent`. |
| `listing.rejected` | catalog | New, when processing refuses a photo. |
| `review.posted` | trust | New, on a review's first submission only. |

`listing.published`, `account.suspended` and `account.unsuspended` exist.

## Flow

The Restate service `NotificationWorker` has one handler per event kind.
Each handler:

1. Reads the facts in one step through the source module's service: for a
   deal its buyer, seller, listing title and the new moves (kind, side,
   amount, waybill, cancel reason); for a message its sender's name, its
   recipient and its first 100 characters; and so on. No module calls
   notification.
2. Decides in notification's domain which moves notify whom with which
   type.
3. Writes in one step: an upsert of each notice, collapsing on
   `(account_id, collapse_key)` among unread rows, with `bumped_at` the
   event's time, so a redelivered event writes the same row; the deletion
   of the recipient's notices older than 90 days; and `stream.Notify` to
   the recipient, in one transaction.
4. Pushes in one step per recipient: every token of the recipient through
   FCM HTTP v1, with `android.notification.tag` set to the collapse key and
   `data {type, target_kind, target_id}`. A token FCM reports
   `UNREGISTERED` or `INVALID_ARGUMENT` is deleted; 429 and 5xx return an
   error, so Restate retries; another 4xx is logged and dropped. The
   journal keeps one event from pushing twice.

A chat message goes to step 4 alone, collapsing on `conversation:<id>`.

Before a push, notification asks auth which of the recipient's token
sessions are still active and deletes the tokens of the others. That
covers logout, logout of every device, revocation, refresh-token reuse
and expiry with one read, and leaves auth's writes as they are.

## Data

- `notifications (id, account_id, type, collapse_key, params jsonb,
  read_at, created_at, bumped_at)`; a unique index on `(account_id,
  collapse_key) WHERE read_at IS NULL AND collapse_key IS NOT NULL`; the
  list pages by `(bumped_at, id)`.
- `push_tokens (session_id PRIMARY KEY, account_id, token, updated_at)`.

## Push provider

`internal/provider/push` holds `Sender` with a `LogSender` for development
and `FCM` for production, as `sms` and `email` do. `FCM_CREDENTIALS` is a
service account's JSON in base64; empty means the log sender, set to the
empty string in `.env.example`. `FCM_PROJECT_ID` names the project. The
OAuth2 token comes from `golang.org/x/oauth2/google`, without the Firebase
Admin SDK.

## Tests

- Domain: each move to its type and recipient; each text.
- Repository: collapsing on unread, read, read-all, the 90-day deletion,
  one token per session.
- Worker with restatetest and a fake sender: a redelivered event writes no
  second notice and pushes once; a dead token is deleted; a chat message
  pushes and lists nothing.
- e2e: an offer notifies the seller; a message reaches the fake sender;
  logout removes the token; every declared status.
