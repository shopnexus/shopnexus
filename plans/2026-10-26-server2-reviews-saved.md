# server2 reviews and saved listings: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buyer reviews the seller of a shipped order (stars and text, editable for 7 days), anyone reads a seller's reviews with average and count, and a signed-in person saves listings and reads them back with the price at saving.

**Architecture:** Two new modules in the four-package layout. `trust` owns `reviews` and reads orders through a new `dealsvc.Service.Order`, buyer names through `account` and listing titles through `catalog`. `discovery` owns `saved_listings` and reads listings through `catalogsvc.Service.Summaries`. No Restate: every command is one row written in one statement.

**Tech Stack:** Go 1.27, pgx v5, Postgres 18.

**Spec:** `~/shopnexus/specs/2026-10-26-server2-reviews-saved-design.md`

## Global Constraints

- Review: buyer of an order that is `shipped`, `delivered` or `returned`; stars 1–5; text 0–500 runes after trimming; one per order; edit or delete within 7 days of `created_at` (409 `review_locked` after); a suspended caller cannot PUT.
- Someone else's order is 404 `order_not_found`; an order not shipped yet is 409 `order_not_shipped`.
- Saved: someone else's `active` or `reserved` listing; at most 500 per account; hidden or deleted listings in the list show `listing_id`, status and `saved_at` only.
- Lists page by UUIDv7 IDs, newest first (`page.Request`, `page.Of`).
- No SQL keyword as a column name (`body`). A use case reads top to bottom.
- No commits unless the user asks; each task ends on a green `make test`.
- Comments, docs and migration comments go through the humanizing checker.

## Review Focus

1. A buyer of a returned order reviews it; a buyer of a cancelled order cannot (Task 2 service test).
2. The 7-day lock: an edit at day 6 works, at day 8 is `review_locked`, and a delete after day 7 too (Task 2 domain test with a fixed clock).
3. The seller's average after an edit and after a delete (Task 2 repository test).
4. A listing hidden after it was saved shows status only, no title or price (Task 3 service test).
5. The 501st save is refused, and re-saving one of the 500 is fine (Task 3 repository test).

---

### Task 1: deal exposes an order

**Files:**
- Modify: `internal/deal/repository/repository.go`, `deal_pg.go`, `deal_pg_test.go`; `internal/deal/service/service.go`, `deal_get.go`, `order_test.go`

**Interfaces:**
- Produces: `repository.Deals.Order(ctx, id uuid.UUID) (OrderRow, error)` (`ErrNotFound` for an unknown id); `dealsvc.Service.Order(ctx, id uuid.UUID) (OrderFacts, error)` with `OrderFacts{ID, DealID, BuyerID, SellerID, ListingID uuid.UUID; Status domain.OrderStatus}` and `domain.ErrOrderNotFound` (404 `order_not_found`) for an unknown id.

- [ ] **Step 1: Failing tests:** repository `Order` returns a requested order's row and `ErrNotFound` for a random ID; service `TestOrderFacts` returns buyer, seller, listing and status of a requested order, `ErrOrderNotFound` for a random ID.
- [ ] **Step 2: Run** → build failure. **Step 3: Implement** with the `ordersOf…` select by `o.id = @id`. **Step 4: Run** `make test` → green.

### Task 2: module trust, reviews

**Files:**
- Create: `migrations/0014_reviews.sql`, `internal/trust/{domain,repository,service,handler}/…`, `internal/trust/trust.go`, `api/paths/trust.yaml`, `api/schemas/trust.yaml`, `e2e/review_test.go`
- Modify: `api/openapi.yaml`, `internal/app/app.go`, `tmp/gen_depguard.py` (add `trust`), `.golangci.yml`

**Interfaces:**
- Domain: `Review` (unexported fields, getters, `ReviewState` with JSON tags, `RestoreReview`); `NewReview(id, order, seller, buyer, listing uuid.UUID, stars int, text string, now time.Time) (Review, error)`; `(r *Review) Edit(stars int, text string, now time.Time) error` (422 `invalid_review` fields `stars`, `text`; 409 `review_locked` after `EditWindow = 7 * 24 * time.Hour`); `(r *Review) CanDelete(now) error`; errors `ErrInvalidReview`, `ErrLocked`, `ErrNotFound` (404 `review_not_found`), `ErrOrderNotFound` (404 `order_not_found`), `ErrNotShipped` (409 `order_not_shipped`).
- Repository `Reviews`: `ByOrder(ctx, order) (domain.Review, error)` (`ErrNotFound`); `Save(ctx, r domain.Review) error` (insert or update on `order_id`); `Delete(ctx, order uuid.UUID) error`; `OfSeller(ctx, seller uuid.UUID, p page.Request) ([]domain.Review, error)`; `Summary(ctx, seller uuid.UUID) (average float64, count int, err error)`.
- Service `trustsvc.Service`: `PutReview(ctx, buyer, order uuid.UUID, stars int, text string) (ReviewView, error)`, `DeleteReview(ctx, buyer, order uuid.UUID) error`, `SellerReviews(ctx, seller uuid.UUID, p page.Request) (SellerReviews, error)` with `SellerReviews{Average float64; Count int; page.Page[ReviewView]}` and `ReviewView{ID uuid.UUID; Stars int; Text string; Buyer Person; Listing ListingRef; CreatedAt, UpdatedAt time.Time}`.

- [ ] **Step 1: Migration** `0014_reviews.sql`:

  ```sql
  -- Reviews: the buyer of a shipped order rates its seller, 1 to 5 stars
  -- with an optional text, and may change it for 7 days after the first
  -- submission.

  CREATE TABLE reviews (
      id         uuid PRIMARY KEY,
      order_id   uuid NOT NULL UNIQUE REFERENCES orders (id),
      seller_id  uuid NOT NULL REFERENCES accounts (id),
      buyer_id   uuid NOT NULL REFERENCES accounts (id),
      listing_id uuid NOT NULL REFERENCES listings (id),
      stars      integer NOT NULL CHECK (stars BETWEEN 1 AND 5),
      body       text NOT NULL CHECK (char_length(body) <= 500),
      created_at timestamptz NOT NULL,
      updated_at timestamptz NOT NULL
  );

  CREATE INDEX reviews_seller ON reviews (seller_id, id);
  ```
- [ ] **Step 2: Failing tests.** Domain: stars 0 and 6, text 501 runes, trimming; `Edit` at `created_at + 6 days` passes, at `+ 8 days` is `ErrLocked`; `CanDelete` the same. Repository: save, save again (one row, updated), `Summary` after two reviews (4 and 2 → 3.0, 2) and after a delete; `OfSeller` newest first. Service (helpers build account, auth, catalog, media, deal and trust on the test stack; orders are made by agreeing, requesting COD and shipping through deal's flows, or by writing them with deal's repository): buyer of a shipped order puts a review; edit; a stranger and the seller get `order_not_found`; a requested and a cancelled order give `order_not_shipped`; a returned order works; a suspended buyer gets `account_suspended`; `SellerReviews` has the average, count, buyer name and listing title; delete then delete again → `review_not_found`.
- [ ] **Step 3: Run** → build failure. **Step 4: Implement.** `PutReview`: suspended check; `deals.Order` (`dealdomain.ErrOrderNotFound` or another buyer → `ErrOrderNotFound`); status check; `ByOrder`: found → `Edit`, else `NewReview(uuid.NewV7(), …)`; `Save`; view. `DeleteReview`: order and buyer check; `ByOrder` (`ErrNotFound`); `CanDelete`; `Delete`. `SellerReviews`: `accounts.Get(seller)` (404 for unknown), `Summary`, `OfSeller`, names through `accounts.Get`, titles through `catalog.Summaries` in one call.
- [ ] **Step 5: API, handler, Mount.** `putReview` `PUT /v1/orders/{order_id}/review {stars, text}`: 200, 400, 401, 403, 404, 409, 422. `deleteReview`: 204, 400, 401, 404, 409. `listSellerReviews` `GET /v1/sellers/{id}/reviews` behind `Identify` (signed in or not): 200, 400, 404. `trust.Mount(d, protect, identify, accounts, catalog, deals)`; app passes `auth.Identify(d, cfg.Auth)` and `dealm.Service`. Regenerate depguard with `trust`.
- [ ] **Step 6: e2e** `TestReviews`: a shipped order through the API, the buyer reviews, edits, the seller's page shows it, every declared status observed. A cancelled order gives PUT's 409 `order_not_shipped`. For `review_locked` (PUT and DELETE), the test moves the review's `created_at` back 8 days through the e2e database handle `db`, as other e2e tests set up state the API cannot.
- [ ] **Step 7: Run** `make test` → green.

### Task 3: module discovery, saved listings

**Files:**
- Create: `migrations/0015_saved.sql`, `internal/discovery/{domain,repository,service,handler}/…`, `internal/discovery/discovery.go`, `api/paths/discovery.yaml`, `api/schemas/discovery.yaml`, `e2e/saved_test.go`
- Modify: `api/openapi.yaml`, `internal/app/app.go`, `tmp/gen_depguard.py` (add `discovery`), `.golangci.yml`

**Interfaces:**
- Domain: `MaxSaved = 500`; errors `ErrLimit` (409 `saved_limit_reached`), `ErrOwnListing` (409 `own_listing`), `ErrListingUnavailable` (409 `listing_unavailable`).
- Repository `Saves`: `Save(ctx, id, account, listing uuid.UUID, price int64, at time.Time) error` (a repeat does nothing; the 501st is `domain.ErrLimit`, counted under `pg_advisory_xact_lock` on the account); `Remove(ctx, account, listing uuid.UUID) error`; `List(ctx, account uuid.UUID, p page.Request) ([]Save, error)` with `Save{ID, ListingID uuid.UUID; Price int64; At time.Time}`.
- Service `discoverysvc.Service`: `Save(ctx, account, listing uuid.UUID) error`, `Unsave(ctx, account, listing uuid.UUID) error`, `Saved(ctx, account uuid.UUID, p page.Request) (page.Page[SavedView], error)` with `SavedView{ID, ListingID uuid.UUID; SavedPrice int64; SavedAt time.Time; Listing *SavedListing}` and `SavedListing{Title string; Price int64; CoverThumbURL string; Status catalogdomain.Status}` (for hidden and deleted listings only `Status` is set).

- [ ] **Step 1: Migration** `0015_saved.sql`:

  ```sql
  -- Saved listings: a person keeps a listing with the price it had, to come
  -- back to it. At most 500 per person.

  CREATE TABLE saved_listings (
      id          uuid PRIMARY KEY,
      account_id  uuid NOT NULL REFERENCES accounts (id),
      listing_id  uuid NOT NULL REFERENCES listings (id),
      saved_price bigint NOT NULL,
      created_at  timestamptz NOT NULL,
      UNIQUE (account_id, listing_id)
  );

  CREATE INDEX saved_listings_account ON saved_listings (account_id, id);
  ```
- [ ] **Step 2: Failing tests.** Repository: save twice → one row; 500 saves then a 501st → `ErrLimit`, re-saving one of the 500 → nil; remove; list newest first. Service: save someone's active listing; own listing → `ErrOwnListing`; a hidden listing → `ErrListingUnavailable`; a reserved one works; an unknown one → `catalogdomain.ErrNotFound`; after the seller hides a saved listing, `Saved` shows its status and no title or price; the saved price stays when the listing's price drops.
- [ ] **Step 3: Run** → build failure. **Step 4: Implement** (`Save` reads the listing through `Summaries` and checks seller and status, then `Saves.Save` with the current price; `Saved` reads one page and the listings in one `Summaries` call).
- [ ] **Step 5: API, handler, Mount.** `saveListing` `PUT /v1/saved/{listing_id}`: 204, 400, 401, 404, 409. `unsaveListing` `DELETE /v1/saved/{listing_id}`: 204, 400, 401. `listSaved` `GET /v1/saved`: 200, 400, 401. `discovery.Mount(d, protect, catalog)`. Regenerate depguard with `discovery`.
- [ ] **Step 6: e2e** `TestSaved`: save, list, hide → status only, every declared status observed.
- [ ] **Step 7: Run** `make test` → green.

### Task 4: ARCHITECTURE.md

- [ ] **Step 1:** Sections `### Trust` and `### Discovery`, and in `### Module layout` the list of modules with the planned ones (notification, kyc, billing) and why there is no finance module, from the spec.
- [ ] **Step 2:** Humanizing checker; fix every hit.
- [ ] **Step 3: Run** `make test` → green.
