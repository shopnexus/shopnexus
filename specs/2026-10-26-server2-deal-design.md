# Design: server2 deal

Date: 2026-10-26.
Status: decided in conversation, question by question and section by
section. When the work lands, the decisions below go into
`~/shopnexus/server2/ARCHITECTURE.md`.

## Scope

The first of three parts of the order work, each with a spec, plan and
merge of its own: deal (a buyer and a seller agree a price on a listing),
COD setup (pickup address, the seller's GHTK or GHN account), then order
(COD request, waybill, reservation, carrier tracking). Chat messages,
ratings, incident records, reputation and notifications come later.

The design follows what app2 needs (`app2/core/model/.../Deal.kt`,
`app2/core/domain/.../DealRules.kt`, `Offers.kt`, `Selling.kt`); app2's
fake engine is not a template.

## Decisions

| Question | Decision |
|---|---|
| Parts | Deal, then COD setup, then order. |
| Chat | One conversation per pair of buyer and seller, holding the deals of that pair. Chat is a later module; every deal move carries its listing so the pair's thread can show it. |
| Deal | One per buyer and listing. |
| Offer expiry | None. An open price stays until the other side answers, its maker withdraws it, the listed price changes, or the listing leaves sale. The seller can decline an offer. |
| Cancel after agreement | Either side cancels; the deal returns to negotiating and the agreed price is dropped. The order spec extends the same rule up to pickup. |
| Who may open a deal | A signed-in account that is not suspended and has a verified phone, on someone else's active listing. |
| Storage | A Postgres aggregate with `write_id`, a table of moves and the events outbox; no Restate. |

## Rules

### States

A deal is `negotiating` or `agreed`. While negotiating it holds at most one
open price, the buyer's offer or the seller's counter. Several buyers may
agree a price on the same listing; agreeing reserves nothing.

### Moves

| Move | Who | Allowed when | Result |
|---|---|---|---|
| `offer {amount}` | buyer | negotiating; the listing allows offers; no open price, or the open price is the seller's counter | the offer is open; a counter it answers is superseded |
| `offer {amount}` | seller | negotiating; the open price is the buyer's offer | the counter is open; the offer is superseded |
| `accept {price}` | the side facing the open price | negotiating; `price` equals the open price | agreed at that price |
| `accept {price}` | buyer | negotiating; `price` equals the listed price | agreed at the listed price; the buyer's own open offer is superseded |
| `decline` | the side facing the open price | an open price exists | no open price |
| `withdraw` | the maker of the open price | an open price exists | no open price |
| `cancel` | buyer or seller | agreed | negotiating, no open price, no agreed price |

A buyer whose offer is open makes a new one only after withdrawing it; a
seller whose counter is open waits for the buyer.

### Amounts

Whole đồng, in multiples of 1,000.

- A buyer's offer is at least half the listed price rounded up to 1,000,
  and below the open counter, or below the listed price when there is no
  counter.
- A seller's counter is above the open offer and below the listed price.
- A listing with `allow_offers` false takes only the buyer's accept of the
  listed price.
- An empty range, as for the seller when the buyer offers one step below
  the listed price, leaves that side accept, decline or withdraw.
- `accept` carries the price the person saw. When the open price or the
  listed price has changed, it is 409 `price_changed`.

### Listing changes

A worker subscribes to `listing.updated`, `listing.hidden`, `listing.sold`
and `listing.deleted`, reads the listing's current state, and for each
deal on it:

- the listing is hidden, sold or deleted: the open price is dropped, with
  a system move `listing_closed`;
- otherwise, the listed price differs from the price recorded with the
  open price: the open price is dropped, with a system move
  `price_changed` carrying the new price; the listing no longer allows
  offers: the open price is dropped, with a system move `offers_closed`;
- the listing is sold or deleted: an agreed deal returns to negotiating,
  with a system move. The order spec keeps a deal with an active order
  out of this.

A listing in processing or rejected, after an edit of its photos, is not
closed: only a new price or offers turned off take its open prices back. The worker reads current state, so a repeated or
late event changes nothing twice. `offer` and `accept` also check that the
listing is active and answer 409 `listing_unavailable` otherwise;
`decline`, `withdraw` and `cancel` take back a price and work in any state
of the listing.

## API

No endpoint invokes Restate, so none takes an `Idempotency-Key`.

| Endpoint | Purpose |
|---|---|
| `POST /v1/deals {listing_id}` | Open the caller's deal on a listing: 201 with a new deal, 200 with the existing one. |
| `GET /v1/deals/{id}` | A deal, to its buyer or seller; anyone else gets 404. |
| `GET /v1/me/deals?role=buying\|selling` | The caller's deals, newest first, cursor pagination. |
| `POST /v1/deals/{id}/offer {amount}` | The buyer's offer or the seller's counter, by the caller's role. |
| `POST /v1/deals/{id}/accept {price}` | Agree. |
| `POST /v1/deals/{id}/decline`, `/withdraw`, `/cancel` | The moves of the same names. |

Opening checks, in order: an existing deal of the caller on the listing
(200); the listing exists (404 `listing_not_found`); account suspended (403
`account_suspended`); no verified phone (403 `phone_required`); the
caller's own listing (409 `own_listing`); the listing not active (409
`listing_unavailable`).

A move may answer 403 `account_suspended` (offer and accept), 404 `deal_not_found`, 409
`move_not_allowed` (wrong role or state), 409 `listing_unavailable` (offer
and accept), 409
`deal_changed` (the other side moved first; the app reloads), 409
`price_changed` (accept) and 422 `invalid_amount` with the field `amount`
(offer).

### Deal view

| Field | Content |
|---|---|
| `id`, `buyer_id`, `seller_id` | |
| `listing` | `{id, title, price, cover_thumb_url, status}`, current. |
| `role` | `buyer` or `seller`, the viewer's. |
| `status` | `negotiating` or `agreed`. |
| `open_price` | `{by, amount, at}` while one is open. |
| `agreed_price`, `agreed_at` | While agreed. |
| `offer_range` | `{min, max}`, the amounts the viewer's next offer may take; absent when the viewer may not offer. The app bounds its input with it, so the amount rules live only in the server. |
| `moves` | Every move, oldest first: `{kind, by, amount, at}`. `kind` is `offer`, `counter`, `accept`, `decline`, `withdraw`, `cancel`, `price_changed`, `offers_closed` or `listing_closed`; `by` is `buyer`, `seller` or `system`. |

## Data

- `deals (id, listing_id, buyer_id, seller_id, status, open_by,
  open_amount, open_at, listed_price, agreed_price, agreed_at, write_id,
  created_at, updated_at)`, unique `(listing_id, buyer_id)`.
  `listed_price` is the listed price when the open price was made.
- `deal_moves (id, deal_id, kind, by_party, amount, moved_at)`, written in the
  transaction of the deal's save.
- Event `deal.moved`, subject the deal, written in the same transaction,
  for notifications and chat later.
- Two moves at once: the first save wins, the second is 409
  `deal_changed`.

## Modules

```
internal/deal/
  domain/      Deal, Move, the move and amount rules
  repository/  deals and deal_moves on Postgres
  service/     one file per use case; listing_changed for the worker
  handler/
  worker/      listing.updated, hidden, sold, deleted → ListingChanged
  deal.go      Mount
```

`deal/service` takes `accountsvc.Service` (suspended), `authsvc.Service`
(phone) and `catalogsvc.Service`. Catalog gains an internal read of
listings by ID in any state (status, price, `allow_offers`, seller, title,
cover thumbnail); its public `Get` hides non-active listings from anyone
but the seller.

## Tests

- Domain: each row of the move table with the right role, the wrong role
  and the wrong state; the amount bounds, including a 10,000 đ listing, a
  listed price not a multiple of 1,000 and a counter one step above the
  offer.
- Repository on Postgres: the unique pair, a stale `write_id`.
- Service: two moves at once; `price_changed`.
- Worker with restatetest: a price change, hide, sale and delete, each
  delivered twice.
- e2e: every status an operation declares is observed.
