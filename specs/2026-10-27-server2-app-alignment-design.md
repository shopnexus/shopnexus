# Design: server2 changes for app2

Date: 2026-10-27.
Status: decided in conversation, question by question. When the work
lands, the decisions below go into `~/shopnexus/server2/ARCHITECTURE.md`.

## Scope

App2 runs on fake data. Comparing its models with server2's API showed four
gaps the app cannot fill on its own: a public seller profile, account
fields (avatar, bio, an address book), what a signed-in person sees of
their own relation to a listing, and the deal each inbox row is about.
Photo capture times were considered and dropped.

The app follows server2 on these points, already decided: COD without a
carrier integration, the seller reporting delivered or returned, one
conversation per pair of people, communes and provinces in place of
districts, and a phone number as the only condition for posting.

## Decisions

| Question | Decision |
|---|---|
| Delivery addresses | An address book per account, like Shopee's: name, phone and address; at most 10; one default. |
| COD recipient | `POST /v1/deals/{id}/cod` takes an `address_id` from the book; free-form recipients are gone. |
| Avatar | Uploaded like a listing photo; media turns it into a 400 px square. Public. |
| Bio | 0 to 200 characters, public, no content filter. |
| "Đã bán" | Every listing in status `sold`, through an order or marked by hand. |
| Seller's public listings | `active` and `reserved`, newest first. |
| Listing and viewer | A `viewer` block on `GET /v1/listings/{id}`. |
| Inbox row | The server picks one deal per conversation and says whose turn it is. |
| Capture time | Not built. |

## Account fields (module account)

- `Account` gains `bio` (string, may be empty) and `avatar_url` (absent
  without an avatar).
- `PATCH /v1/accounts/me {display_name?, bio?, avatar_upload_id?}`: at
  least one field. `avatar_upload_id` is an upload of the caller; `null`
  removes the avatar. The call answers once media has processed the photo,
  with 422 `invalid_upload` when media refuses it, and 422
  `invalid_account` with fields `display_name` and `bio` for the text
  rules.
- `Person` (chat) and the review's `buyer` (trust) gain `avatar_url`.

## Address book (module account)

- `Address {id, name, phone, street, commune_code, commune, province,
  is_default, created_at}`. `phone` is in the +84 form.
- `GET /v1/addresses`: the caller's addresses, the default first, then the
  newest.
- `POST /v1/addresses {name, phone, street, commune_code}` with an
  `Idempotency-Key`: 201 with the address. A repeated key returns the
  address its first request added. The first address becomes the default.
  The eleventh is 409 `address_limit_reached`.
- `PUT /v1/addresses/{id}` with the same body: 200.
- `POST /v1/addresses/{id}/default`: 204.
- `DELETE /v1/addresses/{id}`: 204. The row leaves the database, and when
  it was the default the newest remaining address becomes the default.
- The rules of today's `RecipientDraft` apply: name 1 to 50 characters,
  a Vietnamese mobile number, street 1 to 200 characters, a known commune.
  Breaking one is 422 `invalid_address` with an entry per field.
- Only the owner reads or changes an address; anyone else gets 404
  `address_not_found`.
- An advisory lock per account guards the cap, as with blocks and saves.
- `POST /v1/deals/{id}/cod {address_id}` copies the address into the order
  as its recipient, so a later edit or delete of the address leaves the
  order as it was. An address of someone else is 404
  `address_not_found`. `RecipientDraft` and `invalid_recipient` go.

## Seller profile

- `GET /v1/sellers/{id}`, signed in or not, in module trust:
  `{id, display_name, avatar_url, bio, joined_at, rating: {average,
  count}, sold, on_sale}`. `sold` counts the seller's listings in status
  `sold`, `on_sale` those `active` or `reserved`. An unknown account is
  404 `account_not_found`.
- `GET /v1/sellers/{id}/listings?cursor=`, signed in or not, in module
  catalog: `ListingList` of the seller's `active` and `reserved`
  listings, newest first. An unknown account is 404 `account_not_found`.

## Listing viewer block (module catalog)

- `GET /v1/listings/{id}` gains `viewer {saved, deal_id, conversation_id}`
  when the caller is signed in and is not the seller. `deal_id` is the
  caller's deal on the listing and `conversation_id` their conversation
  with the seller; each is absent when there is none.
- Discovery, deal and chat already depend on catalog, so catalog cannot
  call them. The catalog handler takes the viewer lookup as an interface,
  which `internal/app` builds from the three services.

## Inbox deal (module chat)

- `InboxItem` gains `deal` (absent when the pair has no deal) and
  `other_active_deals` (integer).
- `deal`: `{id, role, listing, status, open_price, agreed_price,
  order_status, your_turn}`. `role` is the caller's side, `listing` is
  `DealListing`, `open_price` and `agreed_price` are absent when the deal
  has none, `order_status` is that of the deal's newest order.
- `your_turn` is true when:
  - the deal is `negotiating` and the open price is the other side's;
  - the caller is the buyer of an `agreed` deal without an open order, on
    a listing still `active` (a hidden listing or one reserved for another
    order refuses the COD request);
  - the caller is the seller and the deal's order is `requested` or
    `shipped`.
- Active deals are `negotiating` or `agreed`. The row's deal is the
  newest of the caller's turn, else the newest active, else the newest.
  `other_active_deals` counts the pair's active deals besides it.
- Module deal adds one call that returns these for a page of pairs, so the
  inbox makes one query for its page.

## Tests

- Domain: address rules, the default moving on delete, bio bounds,
  `your_turn` for each case.
- Repository: the cap of 10; one default per account; the sold and on-sale
  counts; the inbox's pick per pair.
- e2e: every declared status, an order keeping its recipient after the
  address is edited and deleted, an avatar shown on the profile and in the
  inbox, the viewer block absent for the seller and for a signed-out
  reader.

## Screen module

Added after the four parts above were built, because those parts added
fields to resources to fit one screen each. Module `screen` serves one
`GET` per view of the app, for mobile and desktop alike; a desktop page
that shows two views calls both at once. It owns no table and calls the
other modules' services. No module calls `screen`.

| Decision | Choice |
|---|---|
| Devices | One endpoint per view, shared by mobile and desktop. |
| First views | Listing, seller, inbox, chat. |
| Overlapping reads | Removed: each piece of data has one read path. |

### Views

- `GET /v1/screens/listing/{id}`, signed in or not: `{listing, seller,
  viewer}`. `listing` is the public `Listing`; a listing that is not
  `active` or `reserved` is 404 `listing_not_found`, also for its seller,
  who reads their own through `GET /v1/listings/{id}`. `seller` is
  `{id, display_name, avatar_url, joined_at, rating {average, count},
  sold}`. `viewer` is present for a signed-in reader who is not the
  seller: `{saved, deal, conversation_id}`, where `deal` is the reader's
  `DealSummary` on the listing and each of `deal` and `conversation_id` is
  absent when there is none.
- `GET /v1/screens/seller/{id}`, signed in or not: `{seller, listings,
  reviews, viewer}`. `seller` adds `bio` and `on_sale` to the listing
  view's seller. `listings` is the first page of the seller's public
  listings with `next_cursor`; `reviews` is `{average, count, items,
  next_cursor}` with the first page. `viewer`, for a signed-in reader who
  is not the seller, is `{blocked, conversation_id}`; `blocked` is true
  when either of the two blocks the other. An unknown account is 404
  `account_not_found`.
- `GET /v1/screens/inbox?archived=&cursor=`, signed in: `{items,
  next_cursor, unread}`. An item is `{id, other, last_message, unread,
  archived, deal, other_active_deals}` with the inbox deal rules above;
  `unread` is the caller's total, as `GET /v1/me/unread` gives it.
- `GET /v1/screens/chat/{conversation_id}`, signed in: `{id, other,
  archived, deals, messages}`. `deals` are the pair's deals as `Deal`,
  newest first; `messages` is the first page of `MessageList`. Anyone but
  a member gets 404 `conversation_not_found`.

"Load more" uses the list endpoints, which return the same item shapes:
`GET /v1/sellers/{id}/listings`, `GET /v1/sellers/{id}/reviews` and
`GET /v1/conversations/{id}/messages`. The inbox pages through its own
view.

### Removed

`GET /v1/conversations`, `GET /v1/conversations/{id}`,
`GET /v1/sellers/{id}`, `viewer` on `Listing` with the lookup `app` gave
catalog, and `deal` and `other_active_deals` on chat's `InboxItem`. The
service calls behind them stay, and `screen` uses them.

### Tests

- e2e: every declared status of the four views; the listing view's
  `viewer` absent for the seller and a signed-out reader; the inbox paging
  through `cursor` with the deal on each page; the chat view refused to a
  non-member.
