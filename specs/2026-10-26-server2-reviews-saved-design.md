# Design: server2 reviews and saved listings

Date: 2026-10-26.
Status: decided in conversation, question by question. When the work
lands, the decisions below go into `~/shopnexus/server2/ARCHITECTURE.md`.

## Scope

A buyer reviews the seller of a shipped order; anyone reads a seller's
reviews. A signed-in person saves listings and reads them back with the
price they had when saved. Two new modules: `trust` for reviews, where
reports, incident records and reputation come later, and `discovery` for
saved listings, where search, the feed, followed searches and price alerts
come later. Notifying savers when a listing comes back on sale belongs to a
later notification module.

## Modules of server2

The old server's split is not a template. Server2 keeps `account` (with
blocks), `auth`, `staff`, `media`, `catalog`, `deal` (negotiation and COD
orders) and `chat`; it has no wallet or finance module, since ShopNexus
holds no money. Planned after this work: `notification` (in-app list and
push), `kyc` (card checks, replacing the phone rule for posting) and
`billing` (boosts and seller plans). Moderation works on `trust`'s reports
through `staff`.

## Decisions

| Question | Decision |
|---|---|
| Modules | Reviews in `trust`, saved listings in `discovery`. |
| Who reviews | The buyer of an order reviews its seller. |
| When | Once the order is `shipped`, `delivered` or `returned`; no deadline for the first review. |
| Content | 1 to 5 stars and a text of 0 to 500 characters after trimming. |
| One per | Order: a deal can hold several orders over time. |
| Changes | Edit or delete within 7 days of the first submission, then fixed. |

## Reviews (module trust)

- `PUT /v1/orders/{order_id}/review {stars, text}` creates or replaces the
  caller's review of the order: 200 with the review.
- `DELETE /v1/orders/{order_id}/review`: 204.
- `GET /v1/sellers/{id}/reviews`, signed in or not: `{average, count,
  items, next_cursor}`, newest first. An item has `{id, stars, text,
  buyer: {id, display_name}, listing: {id, title}, created_at,
  updated_at}`.
- Errors:

  | Status | Code | When |
  |---|---|---|
  | 403 | `account_suspended` | The caller is suspended (PUT). |
  | 404 | `order_not_found` | No order, or the caller is not its buyer. |
  | 404 | `review_not_found` | DELETE without a review. |
  | 404 | `account_not_found` | An unknown seller (GET). |
  | 409 | `order_not_shipped` | The order is `requested` or `cancelled`. |
  | 409 | `review_locked` | More than 7 days after the first submission. |
  | 422 | `invalid_review` | Fields `stars`, `text`. |

- `trust` reads the order through a new `dealsvc.Service.Order(ctx,
  orderID)` returning its buyer, seller, listing and status, so the only
  dependency is `trust → deal`. It reads buyer names through `account` and
  listing titles through `catalog`.
- Table `reviews (id, order_id UNIQUE, seller_id, buyer_id, listing_id,
  stars, body, created_at, updated_at)`, with an index on `(seller_id,
  id)`. `body` because `text` is an SQL keyword. `created_at` is the first
  submission and starts the 7 days.

## Saved listings (module discovery)

- `PUT /v1/saved/{listing_id}` saves a listing of someone else's that is
  `active` or `reserved`; saving again changes nothing: 204.
- `DELETE /v1/saved/{listing_id}`: 204, absent is fine.
- `GET /v1/saved`: the caller's saves, newest first: `{listing_id,
  saved_price, saved_at, listing}`, where `listing` is the current
  `{title, price, cover_thumb_url, status}`. A hidden or deleted listing
  shows its status alone, since its seller took it down.
- At most 500 saves per account: 409 `saved_limit_reached`. Other errors:
  404 `listing_not_found`, 409 `own_listing`, 409 `listing_unavailable`.
- Table `saved_listings (id, account_id, listing_id, saved_price,
  created_at)`, unique `(account_id, listing_id)`. Each save has a UUIDv7
  `id`, so the list pages by it, newest save first, as the blocks list
  does.

## Tests

- Domain: stars and text bounds; the 7-day lock on edit and delete.
- Repository: one review per order; the seller's average and count;
  saving twice; the 500 limit.
- Service: the buyer and the order status rules; a suspended reviewer;
  hidden and deleted saved listings shown by status alone.
- e2e: every declared status observed.
