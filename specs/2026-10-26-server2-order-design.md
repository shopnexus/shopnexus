# Design: server2 COD orders

Date: 2026-10-26.
Status: decided in conversation, question by question and section by
section. When the work lands, the decisions below go into
`~/shopnexus/server2/ARCHITECTURE.md`.

## Scope

A buyer who agreed a price asks for cash on delivery; the seller ships the
parcel through a carrier of their choice and records the waybill; the
listing is held while the parcel travels; the seller reports it delivered
or returned. Orders live in module `deal`, next to the negotiation they
come from.

The first version integrates no carrier. Every order is shipped by the
seller on the carrier's own app (GHTK, GHN, SPX, J&T, Viettel Post or
another) and recorded in ShopNexus by hand. Carrier accounts, pickup
addresses, fee quotes, webhooks and polling are out of scope, and with them
the COD setup module planned earlier. The waybill is stored with a
`source`, `self` for now, so an integrated waybill is a new source later
without a new table or endpoint.

Ratings, incident records, reputation, notifications and app2's screens
come later.

## Decisions

| Question | Decision |
|---|---|
| Carrier integration | None in the first version; every order is self-shipped and reported by the seller. The waybill keeps a `source` for integrations later. |
| COD setup module | Dropped with the integration. Posting a listing does not require it. |
| Payout | ShopNexus stores nothing about the seller's bank account with the carrier; it cannot check it. |
| Order states | `requested` → `shipped` → `delivered` or `returned`; `requested` → `cancelled`. Nothing sits between requested and shipped: the seller records the waybill once the parcel is with the carrier, so a buyer cannot cancel on a seller who already packed it (decided 2026-10-26). |
| Who cancels | The buyer or the seller, while the order is `requested`. |
| Reservation | From `shipped`: the listing is `reserved`, and every other `requested` order on it is cancelled. A return puts the listing back on sale. |
| After a return | The deal negotiates again, as after a cancel. |
| Buyer limit | At most 3 open orders (`requested`, `shipped`) per buyer. |
| Recipient data | The buyer always sees it. The seller sees it in full, except on an order cancelled before shipping, where only the name and the commune remain. |
| Module | Orders in module `deal`; the three commands that touch the listing run as Restate flows. |

## Rules

### Order

An order belongs to a deal; a deal has at most one open order and keeps
its earlier ones.

| Field | Rule |
|---|---|
| `id` | UUIDv7. |
| `code` | `SN-` and a number from a Postgres sequence, from 100001. |
| `price` | The deal's agreed price when the buyer asked for COD. |
| `recipient` | `name` 1–50 characters, `phone` a Vietnamese mobile number, `street` 1–200 characters, `commune_code` from the administrative list. |
| `waybill` | `source` (`self`), `carrier` (`ghtk`, `ghn`, `spx`, `jt`, `viettel_post`, `other`), `carrier_name` 1–50 characters with `other` only, `tracking_code` 1–50 characters, `fee` whole đồng from 0 to 5,000,000. |
| `status` | `requested`, `shipped`, `delivered`, `returned`, `cancelled`. |
| `cancelled_by` | `buyer`, `seller` or `system`. |
| `cancel_reason` | `buyer`, `seller`, `sent_to_another` (the seller shipped to another buyer), `listing_closed` (the listing was hidden, sold off the app or deleted). |
| times | `requested_at`, `shipped_at`, `closed_at`. |

### Commands

A deal gains the status `sold`, which takes no move.

| Command | Who | Allowed when | Result |
|---|---|---|---|
| Request COD | buyer | deal `agreed`, no open order, listing `active`, fewer than 3 open orders, account not suspended | order `requested` |
| Ship | seller | order `requested`, listing `active` | order `shipped` with its waybill; listing `reserved`; every other `requested` order on the listing cancelled with `sent_to_another`, and their deals negotiate again |
| Deliver | seller | order `shipped` | order `delivered`, deal `sold`, listing `sold` |
| Return | seller | order `shipped` | order `returned`, deal negotiating, listing `active` |
| Cancel | buyer or seller | deal `agreed` with no order, or order `requested` | a `requested` order `cancelled`, deal negotiating |

Only Request COD refuses a suspended account; the other commands finish or
take back what is under way.

Each command is also a move of the deal's thread: `cod_requested`,
`shipped` (amount: the fee), `delivered`, `returned`,
`order_cancelled`. The deal's `cancel` move becomes `order_cancelled` when
an order was open.

### Listing changes

- A listing with a `shipped` order is `reserved`; the seller
  cannot hide, edit, mark sold or delete it (409 `listing_state_conflict`).
- A listing with only `requested` orders stays `active`. When the seller
  hides it, marks it sold or deletes it, the deal worker cancels those
  orders with `listing_closed` and their deals negotiate again.
- Other buyers' deals on a `reserved` listing keep their open prices and
  take no offer or accept (409 `listing_unavailable`); the deal rules read
  `reserved` as paused.
- The deal worker leaves a deal with an open order out of the cleanup the
  deal spec describes, except for the cancel above.

## API

| Endpoint | Who | Restate | Errors |
|---|---|---|---|
| `POST /v1/deals/{id}/cod {recipient}` | buyer | no | 403 `account_suspended`; 404 `deal_not_found`; 409 `move_not_allowed`, `listing_unavailable`, `cod_limit_reached`, `deal_changed`; 422 `invalid_recipient` |
| `POST /v1/deals/{id}/ship {carrier, carrier_name, tracking_code, fee}` with `Idempotency-Key` | seller | yes | 404; 409 `move_not_allowed`, `listing_unavailable`; 422 `invalid_waybill` |
| `POST /v1/deals/{id}/delivered` with `Idempotency-Key` | seller | yes | 404; 409 `move_not_allowed` |
| `POST /v1/deals/{id}/returned` with `Idempotency-Key` | seller | yes | 404; 409 `move_not_allowed` |
| `POST /v1/deals/{id}/cancel` | buyer or seller | no | 404; 409 `move_not_allowed`, `deal_changed` |
| `GET /v1/me/orders?role=buying\|selling` | | | the caller's orders, newest first, cursor pagination |

`cancel` keeps the shape of the deal spec. The deal view gains `order`, the deal's latest order: code, status, price,
recipient (masked by the rule above), waybill, cancellation and times. An
order list item is the order with its deal ID and the listing's current
`{id, title, price, cover_thumb_url, status}`.

## Flows

Each runs as a Restate service in `deal/service/*_durable.go`, called
through `restatex.Caller` with the invocation key `<caller>/<Idempotency-Key>`.

- `DealShip`: `catalog.Reserve(listing, order)` first; a listing that is
  not active refuses, and nothing is written. Then it saves the shipped
  order. The listing's other `requested` orders are cancelled by the deal
  worker, which subscribes to `listing.reserved`, reads the listing's
  `reserved_for` and cancels every `requested` order of another deal with
  `sent_to_another`; another buyer cannot ship meanwhile, since the listing
  is no longer active. When that
  save refuses (the buyer cancelled meanwhile), `catalog.Release(listing,
  order)` gives the listing back.
- `DealDeliver`: save `delivered`, then `catalog.SellTo(listing, order)`.
- `DealReturn`: save `returned`, then `catalog.Release(listing, order)`.

Every catalog call names the order, so a repeated call does nothing more;
Restate retries it until it succeeds.

## Catalog changes

- Status `reserved` and column `reserved_for` (the order ID).
  `Reserve(listing, order)`: `active` → `reserved`, nothing for the same
  order again, `listing_unavailable` otherwise. `Release(listing, order)`:
  `reserved` for that order → `active`, nothing otherwise. `SellTo(listing,
  order)`: `reserved` for that order → `sold`, nothing when already sold
  for it.
- Events `listing.reserved` and `listing.released`; `SellTo` writes
  `listing.sold`.
- A reserved listing is visible to anyone at `GET /v1/listings/{id}`,
  counts toward the 20-listing cap and shows in the `on_sale` pane.

## Data

- Migration `0010_listing_reserved.sql`: the `reserved` status and column
  `listings.reserved_for`. Migration `0011_orders.sql`: table `orders`,
  sequence `order_codes`, a unique partial index for one open order per
  deal and one for one `shipped` order per listing, and new values in the
  checks of `deals.status` and `deal_moves.kind`.
- The 3-order limit is counted under `pg_advisory_xact_lock` on the buyer,
  as catalog holds its listing cap.

## Tests

- Domain: each command with the right role, the wrong role and the wrong
  state; the recipient and waybill rules; the masking.
- Repository on Postgres: two COD requests at once at the limit; two
  shipments of one listing at once; a repeated save under one write ID
  writes its moves once.
- Flows with restatetest: a reserve that refuses writes nothing; a shipment
  whose save refuses releases the listing; a return puts the listing back
  on sale; deliver sells it; a repeated key runs once.
- Catalog: reserve, release, sell-to, and the commands a reserved listing
  refuses.
- e2e: every status an operation declares is observed.
