# server2 COD orders: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buyer with an agreed price asks for COD with a recipient; the seller ships it on a carrier's own app and records the waybill, which holds the listing; the seller reports it delivered (listing sold) or returned (listing back on sale); either side cancels while it is requested.

**Architecture:** Orders live in module `deal`: the `Deal` aggregate holds its latest order, and the deal repository writes deal, order, moves and `deal.moved` in one transaction. Catalog gains the listing status `reserved` with `Reserve`, `Release` and `SellTo`, each keyed by the order. The three commands that change the listing (ship, deliver, return) run as Restate flows in `deal/service/*_durable.go`; the deal worker, subscribed to `listing.reserved` as well, cancels other buyers' requested orders.

**Tech Stack:** Go 1.27 (stdlib `uuid`), pgx v5, Restate Go SDK v1.1.0, Postgres 18, golangci-lint v2.

**Spec:** `~/shopnexus/specs/2026-10-26-server2-order-design.md` (deal rules: `~/shopnexus/specs/2026-10-26-server2-deal-design.md`)

## Global Constraints

- Order states: `requested` → `shipped` → `delivered` | `returned`; `requested` → `cancelled`. Nothing between requested and shipped.
- Cancel (buyer or seller) only while the order is `requested`, or on an agreed deal without an open order; it never touches the listing and stays a plain command without `Idempotency-Key`.
- `ship`, `delivered`, `returned` take an `Idempotency-Key`; the invocation key is `<caller id>/<Idempotency-Key>`.
- At most 3 open orders (`requested`, `shipped`) per buyer: 409 `cod_limit_reached`.
- Recipient: name 1–50, Vietnamese mobile phone (`contact.ParsePhone`), street 1–200, a known commune code. Waybill: carrier `ghtk|ghn|spx|jt|viettel_post|other`, `carrier_name` 1–50 with `other` only, `tracking_code` 1–50, fee 0–5,000,000 đồng, source `self`.
- The seller sees a cancelled order's recipient with only name and commune; otherwise both sides see it in full.
- Only Request COD refuses a suspended account.
- A reserved listing: anyone may GET it, it counts toward the cap and the `on_sale` pane, and hide, edit, mark sold and delete answer 409 `listing_state_conflict`. The deal rules treat it as not on sale (no offer, no accept), and keep open prices.
- No SQL keyword as a column name. No update callbacks in business code (ARCHITECTURE "Use cases"). A use case reads top to bottom; a helper exists when several places call it.
- No commits unless the user asks; each task ends on a green `make test`.
- Comments, docs and migration comments go through `python3 ~/.claude/skills/humanizing-writing/ai-tells.py`.

## Review Focus

1. A ship flow retried after its save committed: one `shipped` move, one event, the listing reserved once (Task 3 `TestSaveTwiceWritesOnce`, Task 5 `TestShipRunsOnce`).
2. A buyer cancels while the seller's ship flow runs: either the cancel wins and the listing is released, or the ship wins and the cancel is `move_not_allowed`; never a shipped order on an active listing (Task 5 `TestShipLosesToACancel`).
3. Two buyers requested; the seller ships to one: the other's order ends `cancelled` with `sent_to_another` and that deal negotiates again (Task 4 `TestReservedCancelsOtherRequests`).
4. A buyer at 3 open orders requests two more at once: both refused (Task 3 `TestCodLimitHoldsUnderRace`).
5. The seller reads a cancelled order: no phone, no street (Task 2 `TestRecipientFor`, Task 6 e2e).

Ruling recorded before execution: the spec's single migration is split in two, `0010_listing_reserved.sql` (Task 1, catalog) and `0011_orders.sql` (Task 3, deal), so each task's migration ships with its code.

---

### Task 1: catalog `reserved`

**Files:**
- Create: `migrations/0010_listing_reserved.sql`
- Modify: `internal/catalog/domain/listing.go`, `internal/catalog/domain/listing_test.go`
- Modify: `internal/catalog/repository/listing_pg.go` (column `reserved_for`), `listing_pg_test.go`
- Modify: `internal/catalog/service/service.go`, `listing_state.go`, `listing_get.go`, `views.go`, `listing_test.go`
- Modify: `internal/platform/events/events.go`, `api/schemas/catalog.yaml` (`ListingStatus` gains `reserved`)

**Interfaces:**
- Produces: `domain.StatusReserved`; `domain.OnSale` includes it; `(*Listing).Reserve(order uuid.UUID, now) (bool, error)`, `Release(order, now) bool`, `SellTo(order, now) bool`, `ReservedFor() uuid.UUID`; `ListingState.ReservedFor uuid.UUID` (`json:"reserved_for"`, zero ↔ NULL); `events.ListingReserved = "listing.reserved"`, `events.ListingReleased = "listing.released"`; on `catalogsvc.Service`: `Reserve(ctx, listingID, orderID uuid.UUID) error`, `Release(ctx, listingID, orderID uuid.UUID) error`, `SellTo(ctx, listingID, orderID uuid.UUID) error`, `Place(ctx context.Context, communeCode string) (Location, error)`; `catalogsvc.Summary` gains `ReservedFor uuid.UUID` and JSON tags on every field (deal journals it).

- [ ] **Step 1: Failing domain tests** (`listing_test.go`):
  - `TestReserveReleaseSell`: an active listing; `Reserve(o, now)` → true, status reserved, `ReservedFor() == o`; `Reserve(o)` again → false, nil; `Reserve(other)` → `ErrStateConflict`; `Release(other)` → false; `Release(o)` → true, active, zero `ReservedFor`; reserve again and `SellTo(o)` → true, sold, `SoldAt` set, zero `ReservedFor`; `SellTo(o)` again → false.
  - `TestReservedRefuses`: on a reserved listing `Hide`, `MarkSold`, `Delete` and `Edit` → `ErrStateConflict`; `Reserve` on hidden, sold, processing → `ErrStateConflict`.
- [ ] **Step 2: Run** `go test ./internal/catalog/domain/` → build failure (no `Reserve`).
- [ ] **Step 3: Implement the domain.** `StatusReserved Status = "reserved"`; `OnSale` = processing, active, hidden, rejected, reserved; field `reservedFor uuid.UUID` with state, restore and getter. `Edit` and `Delete` refuse `StatusReserved` as they refuse sold/deleted. Then:

  ```go
  // Reserve holds an active listing for an order. Holding it again for the
  // same order changes nothing and reports false.
  func (l *Listing) Reserve(order uuid.UUID, now time.Time) (bool, error) {
  	if l.status == StatusReserved && l.reservedFor == order {
  		return false, nil
  	}
  	if l.status != StatusActive {
  		return false, ErrStateConflict
  	}
  	l.status, l.reservedFor, l.updatedAt = StatusReserved, order, now
  	return true, nil
  }

  // Release puts a listing held for order back on sale and reports whether
  // it did; a listing held for another order, or not held, stays as it is.
  func (l *Listing) Release(order uuid.UUID, now time.Time) bool {
  	if l.status != StatusReserved || l.reservedFor != order {
  		return false
  	}
  	l.status, l.reservedFor, l.updatedAt = StatusActive, uuid.UUID{}, now
  	return true
  }

  // SellTo marks a listing held for order sold and reports whether it did.
  func (l *Listing) SellTo(order uuid.UUID, now time.Time) bool {
  	if l.status != StatusReserved || l.reservedFor != order {
  		return false
  	}
  	l.status, l.reservedFor, l.soldAt, l.updatedAt = StatusSold, uuid.UUID{}, &now, now
  	return true
  }
  ```
- [ ] **Step 4: Migration** `0010_listing_reserved.sql`:

  ```sql
  -- A listing is reserved while an order's parcel travels (decided
  -- 2026-10-26); reserved_for names the order.

  ALTER TABLE listings DROP CONSTRAINT listings_status_check;
  ALTER TABLE listings ADD CONSTRAINT listings_status_check
  CHECK (status IN ('processing', 'active', 'hidden', 'rejected', 'reserved', 'sold', 'deleted'));
  ALTER TABLE listings ADD COLUMN reserved_for uuid;
  ```

  The repository adds `reserved_for` to `listingColumns`, scan (`*uuid.UUID`, nil → zero), `args` (zero → nil) and `saveListing`. Repository test: a reserved listing round-trips with its `ReservedFor`.
- [ ] **Step 5: Failing service tests** (`listing_test.go`):
  - `TestReserveFlow`: `e.active` listing; `Reserve(ctx, id, o)` twice → nil; `kindsOf` ends with one `listing.reserved`; `Get` as a stranger → status reserved (visible); `Hide` → `ErrStateConflict`; `Release(other)` → nil and still reserved; `Release(o)` → active, event `listing.released`; reserve, `SellTo(o)` twice → sold, one more `listing.sold`.
  - `TestReserveRefusesHidden`: hidden listing, `Reserve` → `domain.ErrStateConflict`; unknown id → `domain.ErrNotFound`.
  - `TestPlace`: `Place(ctx, "00004")` → commune and province display names set; `Place(ctx, "nope")` → `domain.ErrNotFound`.
  - `TestSummaryCarriesReservedFor`.
- [ ] **Step 6: Implement the service.** In `listing_state.go`, each of the three loads with `c.listings.Get` (not-found → `domain.ErrNotFound`), calls the domain method, returns nil when nothing changed, and otherwise `c.save(ctx, l, kind, now)` with `events.ListingReserved`, `events.ListingReleased` or `events.ListingSold`. `Get` lets anyone see `StatusReserved` as it does `StatusActive`. `Place` wraps `c.regions.Commune` into `Location`. `Summaries` fills `ReservedFor`.
- [ ] **Step 7: Run** `make test` → green. The deal module still compiles: `statusOf` lacks `reserved`, which reads as the zero status (no rule treats it as active).

### Task 2: deal domain orders

**Files:**
- Create: `internal/deal/domain/order.go`, `internal/deal/domain/order_test.go`
- Modify: `internal/deal/domain/deal.go`, `errors.go`, `deal_test.go`

**Interfaces:**
- Consumes: none from Task 1 except the idea of `ListingReserved`.
- Produces:
  - `StatusSold Status = "sold"`; `ListingReserved ListingStatus = "reserved"`; `Listing.ReservedFor uuid.UUID`.
  - Move kinds `MoveCodRequested`, `MoveShipped`, `MoveDelivered`, `MoveReturned`, `MoveOrderCancelled`.
  - `OrderStatus` with `OrderRequested`, `OrderShipped`, `OrderDelivered`, `OrderReturned`, `OrderCancelled`; `CancelReason` with `CancelByBuyer` ("buyer"), `CancelBySeller` ("seller"), `CancelSentToAnother`, `CancelListingClosed`; `Carrier` with `CarrierGHTK` ("ghtk"), `CarrierGHN`, `CarrierSPX`, `CarrierJT`, `CarrierViettelPost`, `CarrierOther`.
  - `Recipient{Name, Phone, Street, CommuneCode string}`, `Waybill{Source string; Carrier Carrier; CarrierName, TrackingCode string; Fee int64}`, `Order{ID uuid.UUID; Code string; Status OrderStatus; Price int64; Recipient Recipient; Waybill *Waybill; CancelledBy Party; CancelReason CancelReason; RequestedAt time.Time; ShippedAt, ClosedAt *time.Time}`, all with snake_case JSON tags.
  - `NewRecipient(name, phone, street, communeCode string, communeExists bool) (Recipient, error)`, `NewWaybill(carrier Carrier, carrierName, trackingCode string, fee int64) (Waybill, error)`.
  - `(*Deal).RequestCod(by Party, r Recipient, l Listing, now time.Time) error`, `Ship(by Party, w Waybill, l Listing, now time.Time) error`, `Deliver(by Party, now time.Time) error`, `Return(by Party, now time.Time) error`; `Cancel` and `ListingChanged` extended; `Order() *Order` (copy of the latest order or nil); `(Order).Open() bool`; `(Order).RecipientFor(viewer Party) Recipient`.
  - `DealState` gains `Order *Order` and JSON tags on every field (flows journal it).
  - Errors `ErrInvalidRecipient` (422 `invalid_recipient`), `ErrInvalidWaybill` (422 `invalid_waybill`), `ErrCodLimit` (409 `cod_limit_reached`, "at most 3 open COD orders").
- [ ] **Step 1: Failing tests** (`order_test.go`), with an agreed deal helper (`Accept(Buyer, 1_500_000, onSale, now)`) and a valid recipient (`NewRecipient("Hân", "0912345678", "12 Lý Thường Kiệt", "00004", true)`):
  - `TestNewRecipient`: trims; empty name, 51-rune name, a landline or junk phone, empty street, 201-rune street, unknown commune each set their field (`name`, `phone`, `street`, `commune_code`); the phone is stored as `contact.ParsePhone(...).Value()`.
  - `TestNewWaybill`: each carrier accepted with `Source == "self"`; `other` without name → `carrier_name`; `ghn` with a name → `carrier_name`; unknown carrier → `carrier`; empty or 51-rune tracking → `tracking_code`; fee -1 and 5,000,001 → `fee`; fee 0 accepted.
  - `TestOrderLifecycle`: agreed deal; seller `RequestCod` → `ErrMoveNotAllowed`; buyer `RequestCod` → order requested at price 1,500,000, move `cod_requested`; second `RequestCod` → `ErrMoveNotAllowed`; buyer `Ship` → not allowed; seller `Ship` on a reserved listing → `ErrListingUnavailable`; seller `Ship` → shipped with the waybill, move `shipped` with amount = fee; `Cancel` by either → not allowed; `Return` by buyer → not allowed; `Deliver` by seller → order delivered, `ClosedAt` set, deal `StatusSold`; then `Offer`, `Accept`, `Cancel`, `RequestCod` → not allowed.
  - `TestReturnNegotiatesAgain`: shipped, `Return` → order returned, deal negotiating, no agreed price; a new `Accept` and `RequestCod` start a second order (the new one is `Order()`).
  - `TestCancelARequest`: requested, buyer `Cancel` → order cancelled by buyer, reason `buyer`, deal negotiating, move `order_cancelled`; same with the seller (reason `seller`). `Cancel` of an agreed deal with no order still records `cancel`.
  - `TestRequestNeedsAnActiveListing`: reserved, hidden, paused → `ErrListingUnavailable`.
  - `TestListingChangedCancelsRequests`: requested order; listing reserved for its own order → false; reserved for another → cancelled by system with `sent_to_another`, deal negotiating; hidden or gone → `listing_closed`; a price change → false and the order stays. A shipped order: any listing → false.
  - `TestRecipientFor`: a cancelled order read by the seller has empty `Phone` and `Street`, the buyer sees them; a shipped order shows the seller everything.
  - In `deal_test.go`: `Offer` and `Accept` on `ListingReserved` → `ErrListingUnavailable`; `ListingChanged` with `ListingReserved` keeps an open price.
- [ ] **Step 2: Run** `go test ./internal/deal/domain/` → build failure.
- [ ] **Step 3: Implement** `order.go` (types, `NewRecipient`, `NewWaybill`, `Open`, `RecipientFor`) and in `deal.go`:

  ```go
  // openOrder is the deal's order in requested or shipped, nil otherwise.
  func (d *Deal) openOrder() *Order {
  	if d.order != nil && d.order.Open() {
  		return d.order
  	}
  	return nil
  }

  // RequestCod asks for cash on delivery to r at the agreed price.
  func (d *Deal) RequestCod(by Party, r Recipient, l Listing, now time.Time) error {
  	if by != Buyer || d.status != StatusAgreed || d.openOrder() != nil {
  		return ErrMoveNotAllowed
  	}
  	if l.Status != ListingActive {
  		return ErrListingUnavailable
  	}
  	d.order = &Order{ID: uuid.NewV7(), Status: OrderRequested, Price: d.agreedPrice, Recipient: r, RequestedAt: now}
  	d.record(MoveCodRequested, by, d.agreedPrice, now)
  	return nil
  }

  // Ship records the waybill of a requested order: the parcel is with the
  // carrier.
  func (d *Deal) Ship(by Party, w Waybill, l Listing, now time.Time) error {
  	o := d.openOrder()
  	if by != Seller || o == nil || o.Status != OrderRequested {
  		return ErrMoveNotAllowed
  	}
  	if l.Status != ListingActive {
  		return ErrListingUnavailable
  	}
  	o.Status, o.Waybill, o.ShippedAt = OrderShipped, &w, &now
  	d.record(MoveShipped, by, w.Fee, now)
  	return nil
  }

  // Deliver ends a shipped order delivered; the deal is sold.
  func (d *Deal) Deliver(by Party, now time.Time) error {
  	o := d.openOrder()
  	if by != Seller || o == nil || o.Status != OrderShipped {
  		return ErrMoveNotAllowed
  	}
  	o.Status, o.ClosedAt, d.status = OrderDelivered, &now, StatusSold
  	d.record(MoveDelivered, by, 0, now)
  	return nil
  }

  // Return ends a shipped order returned; the deal negotiates again.
  func (d *Deal) Return(by Party, now time.Time) error {
  	o := d.openOrder()
  	if by != Seller || o == nil || o.Status != OrderShipped {
  		return ErrMoveNotAllowed
  	}
  	o.Status, o.ClosedAt = OrderReturned, &now
  	d.status, d.agreedPrice, d.agreedAt = StatusNegotiating, 0, nil
  	d.record(MoveReturned, by, 0, now)
  	return nil
  }
  ```

  `Cancel` becomes: not agreed → not allowed; an open order not `requested` → not allowed; an open requested order → `cancelOrder(by, reason(by), now)` and the move `order_cancelled`; then negotiating as before. `ListingChanged` starts with:

  ```go
  	if o := d.openOrder(); o != nil {
  		if o.Status != OrderRequested {
  			return false
  		}
  		switch {
  		case l.Status == ListingHidden || l.Status == ListingGone:
  			d.cancelOrder(System, CancelListingClosed, now)
  		case l.Status == ListingReserved && l.ReservedFor != o.ID:
  			d.cancelOrder(System, CancelSentToAnother, now)
  		default:
  			return false
  		}
  		return true
  	}
  ```

  with

  ```go
  // cancelOrder ends the requested order and drops the agreement.
  func (d *Deal) cancelOrder(by Party, reason CancelReason, now time.Time) {
  	d.order.Status, d.order.CancelledBy, d.order.CancelReason, d.order.ClosedAt = OrderCancelled, by, reason, &now
  	d.status, d.agreedPrice, d.agreedAt = StatusNegotiating, 0, nil
  	d.record(MoveOrderCancelled, by, 0, now)
  }
  ```

  `Cancel` calls `cancelOrder` and returns; the no-order path keeps its `cancel` move. `live` voids nothing for `ListingReserved`, and `OfferRange`, `Offer` and `Accept` already require `ListingActive`.
- [ ] **Step 4: Run** `go test ./internal/deal/domain/` → PASS; `make test` → green.

### Task 3: orders table and repository

**Files:**
- Create: `migrations/0011_orders.sql`
- Modify: `internal/deal/repository/repository.go`, `deal_pg.go`, `deal_pg_test.go`

**Interfaces:**
- Consumes: Task 2's `Order`, `DealState.Order`, `ErrCodLimit`.
- Produces: `Save` writes the deal's latest order (insert or update), counts the buyer's open orders under `pg_advisory_xact_lock(hashtext(buyer_id::text))` when the order is `requested` and refuses the fourth with `domain.ErrCodLimit`; a save whose row already has `writeID` returns nil and writes nothing more. `Get`, `Find`, `OfListing`, `ListByParty` load each deal with its latest order (its `Code` filled). New `ListOrders(ctx, account uuid.UUID, as domain.Party, p page.Request) ([]OrderRow, error)` with `type OrderRow struct{ DealID, ListingID, BuyerID, SellerID uuid.UUID; Order domain.Order }`, newest order first, IDs below `p.Before()`.

- [ ] **Step 1: Migration** `0011_orders.sql`:

  ```sql
  -- COD orders: a buyer's request for cash on delivery on an agreed deal,
  -- shipped by the seller on a carrier's own app. A deal has at most one
  -- open order and keeps its earlier ones; a listing has at most one
  -- shipped order, the one it is reserved for.

  CREATE SEQUENCE order_codes START 100001;

  CREATE TABLE orders (
      id                 uuid PRIMARY KEY,
      code               text NOT NULL UNIQUE DEFAULT 'SN-' || nextval('order_codes'),
      deal_id            uuid NOT NULL REFERENCES deals (id),
      listing_id         uuid NOT NULL REFERENCES listings (id),
      buyer_id           uuid NOT NULL REFERENCES accounts (id),
      seller_id          uuid NOT NULL REFERENCES accounts (id),
      status             text NOT NULL
      CHECK (status IN ('requested', 'shipped', 'delivered', 'returned', 'cancelled')),
      price              bigint NOT NULL,
      recipient_name     text NOT NULL,
      recipient_phone    text NOT NULL,
      recipient_street   text NOT NULL,
      recipient_commune  text NOT NULL REFERENCES communes (code),
      waybill_source     text CHECK (waybill_source IN ('self')),
      carrier            text CHECK (carrier IN ('ghtk', 'ghn', 'spx', 'jt', 'viettel_post', 'other')),
      carrier_name       text,
      tracking_code      text,
      fee                bigint,
      cancelled_by       text CHECK (cancelled_by IN ('buyer', 'seller', 'system')),
      cancel_reason      text CHECK (cancel_reason IN ('buyer', 'seller', 'sent_to_another', 'listing_closed')),
      requested_at       timestamptz NOT NULL,
      shipped_at         timestamptz,
      closed_at          timestamptz
  );

  CREATE UNIQUE INDEX orders_open_per_deal ON orders (deal_id) WHERE status IN ('requested', 'shipped');
  CREATE UNIQUE INDEX orders_shipped_per_listing ON orders (listing_id) WHERE status = 'shipped';
  CREATE INDEX orders_buyer ON orders (buyer_id, id);
  CREATE INDEX orders_seller ON orders (seller_id, id);

  ALTER TABLE deals DROP CONSTRAINT deals_status_check;
  ALTER TABLE deals ADD CONSTRAINT deals_status_check CHECK (status IN ('negotiating', 'agreed', 'sold'));
  ```

  Replace `deals`' agreed check so a sold deal keeps its agreed price: find its generated name with `\d deals` on the test database and recreate it as `CHECK ((status IN ('agreed', 'sold')) = (agreed_price IS NOT NULL) AND (agreed_price IS NULL) = (agreed_at IS NULL))`. Recreate `deal_moves_kind_check` with the five new kinds. Run `sqlfluff lint`.
- [ ] **Step 2: Failing tests** (`deal_pg_test.go`; the listing helper also needs the commune `00004`, which exists):
  - `TestOrderRoundTrip`: agree, `RequestCod`, save; `Get` has the order with `Code` like `SN-1…`, recipient and `RequestedAt`; ship with a waybill, save; `Get` shows it; `ListOrders(buyer, Buyer)` and `ListOrders(seller, Seller)` return one row with the deal and listing IDs.
  - `TestSaveTwiceWritesOnce`: a deal with a pending move saved under `w`; restore the same pre-save state, apply the same move (new move ID), save under the same `w` → nil; `Moves` holds one move and `events` one row for the event ID used.
  - `TestCodLimitHoldsUnderRace`: a buyer with 3 open orders on 3 listings saved; two more deals agreed and requested, saved in two goroutines → both `domain.ErrCodLimit`; with 2 open orders, the two goroutines → exactly one succeeds.
  - `TestOneShippedOrderPerListing`: two deals on one listing, both requested and shipped; the second save fails (unique index), returning an error.
- [ ] **Step 3: Run** `go test ./internal/deal/repository/` → FAIL.
- [ ] **Step 4: Implement.**
  - Select deals with `LEFT JOIN LATERAL (SELECT ... FROM orders o WHERE o.deal_id = d.id ORDER BY o.id DESC LIMIT 1) o ON true`; scan the order columns as nullable and build `*domain.Order` when `o.id` is set.
  - `Save` in one transaction:
    1. `UPDATE deals ... WHERE id = @id AND write_id = @read_write_id`. With no row, `SELECT write_id = @write_id`: true → return nil (an earlier attempt of this save committed); false → `ErrConflict`.
    2. When the order is `requested`: lock the buyer, `SELECT count(*) FROM orders WHERE buyer_id = @buyer AND status IN ('requested','shipped') AND id <> @order` and refuse at 3 with `domain.ErrCodLimit`.
    3. `INSERT INTO orders (...) VALUES (...) ON CONFLICT (id) DO UPDATE SET status, waybill columns, cancelled_by, cancel_reason, shipped_at, closed_at`.
    4. Moves and events as before.
  - `ListOrders` as `ListByParty`, on `orders` by `buyer_id` or `seller_id`.
- [ ] **Step 5: Run** `go test ./internal/deal/...` → PASS; `make test` → green.

### Task 4: plain commands, views and the worker

**Files:**
- Modify: `internal/deal/service/service.go`, `views.go`, `deal_move.go`, `deal_get.go`, `listing_changed.go`; create `order_request.go`
- Modify: `internal/deal/deal.go` (subscribe `listing.reserved`)
- Modify tests: `helpers_test.go`, create `order_test.go`; `listing_changed_test.go`

**Interfaces:**
- Consumes: Task 1's `Place`, `Summary.ReservedFor`; Tasks 2 and 3.
- Produces on `service.Service`: `RequestCod(ctx, caller, id uuid.UUID, r RecipientInput) (DealView, error)` with `RecipientInput{Name, Phone, Street, CommuneCode string}`; `ListOrders(ctx, viewer uuid.UUID, as domain.Party, p page.Request) (page.Page[OrderItem], error)`. `DealView.Order *OrderView`; `OrderView{ID, Code, Status, Price, Recipient RecipientView, Waybill *domain.Waybill, CancelledBy, CancelReason, RequestedAt, ShippedAt, ClosedAt}` where `RecipientView{Name, Phone?, Street?, CommuneCode, Commune, Province}`; `OrderItem{OrderView; DealID uuid.UUID; Listing ListingRef}`.
- [ ] **Step 1: Failing tests** (`order_test.go`; helpers gain `agreed(t, buyer, listing) DealView` and `recipient()`):
  - `TestRequestCod`: agreed deal, `RequestCod` → order requested, recipient with commune and province names; the seller's `Get` shows the full recipient.
  - `TestRequestCodRefusals`: suspended buyer → `ErrSuspended`; unknown commune → `invalid_recipient` with `commune_code`; not agreed → `move_not_allowed`; a hidden listing → `listing_unavailable`; a fourth open order → `cod_limit_reached`.
  - `TestCancelARequestedOrder`: buyer cancels → order cancelled; the seller's view has no phone or street.
  - `TestReservedCancelsOtherRequests`: two buyers request; `e.catalog.Reserve(listing, first order)`; `ListingChanged` → the second order cancelled `sent_to_another`, the first untouched.
  - `TestListOrders`: buyer and seller each list one order with its listing.
  - `listing_changed_test.go`: hiding a listing with a requested order cancels it `listing_closed`.
- [ ] **Step 2: Run** → build failure.
- [ ] **Step 3: Implement.**
  - `statusOf` gains `catalogdomain.StatusReserved: domain.ListingReserved`, and `facts` copies `ReservedFor`.
  - `RequestCod`: `s.load(ctx, caller, id, true)`; `place, err := s.catalog.Place(ctx, r.CommuneCode)` with `catalogdomain.ErrNotFound` → `communeExists = false`; `domain.NewRecipient`; `m.deal.RequestCod(...)`; `s.save(ctx, caller, m)`. `save` keeps returning `ErrChanged` on a conflict and passes `domain.ErrCodLimit` through.
  - `view` builds `OrderView` from `d.Order()` with `RecipientFor(by)` and `catalog.Place` for the names. `read` and `ListMine` give the view what it needs, so `view` takes the place.
  - `ListOrders` reads `ListOrders` rows, the listings through `Summaries`, and each recipient's place.
  - `deal.Mount` subscribes `Changed` to `events.ListingReserved` too.
- [ ] **Step 4: Run** `go test ./internal/deal/...` → PASS; `make test` → green.

### Task 5: ship, deliver and return flows

**Files:**
- Create: `internal/deal/service/order_flow.go` (input, result, shared steps), `order_ship_durable.go`, `order_deliver_durable.go`, `order_return_durable.go`, `order_ship.go` (the three `Service` methods)
- Modify: `service.go` (`Deps` gains `Ingress *ingress.Client`, `Prefix string`; `Durable()`), `internal/deal/deal.go` (Mount returns `Durable()` plus the worker)
- Test: `internal/deal/service/flow_test.go`; `helpers_test.go` starts the flows with `restatetest.Start`.

**Interfaces:**
- Produces on `service.Service`: `Ship(ctx, caller, id uuid.UUID, idempotencyKey string, w WaybillInput) (DealView, error)` with `WaybillInput{Carrier, CarrierName, TrackingCode string; Fee int64}`; `Deliver(ctx, caller, id uuid.UUID, idempotencyKey string) (DealView, error)`; `Return(...)` likewise. Restate services `DealShip`, `DealDeliver`, `DealReturn`, each `Run(ctx restate.Context, in FlowInput) (FlowResult, error)`.

- [ ] **Step 1: Shared pieces** (`order_flow.go`):

  ```go
  // FlowInput names the deal a flow moves, the caller and, for a ship, the
  // waybill.
  type FlowInput struct {
  	Caller  uuid.UUID       `json:"caller"`
  	DealID  uuid.UUID       `json:"deal_id"`
  	Waybill *domain.Waybill `json:"waybill,omitempty"`
  }

  // FlowResult carries the refusal of a flow, or none.
  type FlowResult struct {
  	Refused *apperr.Error `json:"refused,omitempty"`
  }

  func (r FlowResult) Refusal() *apperr.Error { return r.Refused }

  // loaded is a deal as a flow's first step journals it.
  type loaded struct {
  	Deal    domain.DealState   `json:"deal"`
  	By      domain.Party       `json:"by"`
  	Listing catalogsvc.Summary `json:"listing"`
  	Refused *apperr.Error      `json:"refused,omitempty"`
  }

  // loadStep reads the caller's deal and its listing in one journaled step;
  // a caller who is not a side gets domain.ErrNotFound as data.
  func loadStep(ctx restate.Context, s *Deals, caller, id uuid.UUID) (loaded, error)

  // saveStep saves d under writeID with deal.moved as eventID, in one
  // journaled step; a deal changed meanwhile is domain.ErrChanged as data.
  func saveStep(ctx restate.Context, deals repository.Deals, d *domain.Deal, writeID, eventID uuid.UUID, at time.Time) (*apperr.Error, error)

  // reserveStep holds the listing for the order in a journaled step;
  // catalogdomain.ErrStateConflict comes back as
  // domain.ErrListingUnavailable, as data.
  func reserveStep(ctx restate.Context, catalog catalogsvc.Service, listing, order uuid.UUID) (*apperr.Error, error)

  // releaseStep and sellStep run catalog.Release and catalog.SellTo in a
  // journaled step each.
  func releaseStep(ctx restate.Context, catalog catalogsvc.Service, listing, order uuid.UUID) error
  func sellStep(ctx restate.Context, catalog catalogsvc.Service, listing, order uuid.UUID) error
  ```

  Each flow is a struct with one field, `Deals *Deals`, so its steps use the service's repository, catalog and clock; `ServiceName()` is `s.Deals.prefix + "DealShip"` (and `DealDeliver`, `DealReturn`). `Durable()` builds them with `c` itself.
- [ ] **Step 2: Failing tests** (`flow_test.go`):
  - `TestShipDeliver`: agreed and requested; `Ship(key)` → shipped; listing reserved for the order; same key again → same view, one `shipped` move, one `listing.reserved` event (`TestShipRunsOnce` part); `Deliver(key2)` → delivered, deal sold, listing sold.
  - `TestShipReturn`: ship, `Return` → returned, deal negotiating, listing active.
  - `TestShipRefusesAHiddenListing`: seller hides the listing between request and ship → `listing_unavailable`; the order is still requested.
  - `TestShipLosesToACancel`: a test store `cancelFirst` wraps `repository.Deals`; on the first `Save` of a deal whose order is `shipped`, it loads the deal, applies the buyer's `Cancel` and saves that, then forwards the flow's save, which now conflicts. `Ship` through a service built on it → `deal_changed`; the order is `cancelled` by the buyer; the listing is `active` with a `listing.released` event after its `listing.reserved`.
  - `TestShipRefusals`: buyer ships → `move_not_allowed`; stranger → `deal_not_found`; invalid waybill → `invalid_waybill` before any flow runs.
- [ ] **Step 3: Implement** `DealShip.Run`:

  ```go
  func (s DealShip) Run(ctx restate.Context, in FlowInput) (FlowResult, error) {
  	at, err := restatex.Now(ctx, s.Deals.now)
  	if err != nil {
  		return FlowResult{}, err
  	}
  	m, err := loadStep(ctx, s.Deals, in.Caller, in.DealID)
  	if err != nil || m.Refused != nil {
  		return FlowResult{Refused: m.Refused}, err
  	}
  	d := domain.RestoreDeal(m.Deal)
  	if err = d.Ship(m.By, *in.Waybill, facts(m.Listing), at); err != nil {
  		return FlowResult{Refused: apperr.From(err)}, nil
  	}
  	order := d.Order().ID
  	refused, err := reserveStep(ctx, s.Deals.catalog, m.Listing.ID, order)
  	if err != nil || refused != nil {
  		return FlowResult{Refused: refused}, err
  	}
  	refused, err = saveStep(ctx, s.Deals.deals, &d, restatex.NewID(ctx, at), restatex.NewID(ctx, at), at)
  	if err != nil {
  		return FlowResult{}, err
  	}
  	if refused != nil {
  		if err = releaseStep(ctx, s.Deals.catalog, m.Listing.ID, order); err != nil {
  			return FlowResult{}, err
  		}
  		return FlowResult{Refused: refused}, nil
  	}
  	return FlowResult{}, nil
  }
  ```

  `DealDeliver` and `DealReturn`: load, `d.Deliver`/`d.Return`, `saveStep`, then `sellStep`/`releaseStep`. The `Service` methods: `Ship` checks `domain.NewWaybill` first, then `s.ship.Call(ctx, caller.String()+"/"+key, FlowInput{...})` and `s.Get(ctx, caller, id)`; `Deliver` and `Return` likewise. `Durable()` returns the three; `deal.Mount` passes `Ingress` and `Prefix` and returns them with the worker.
- [ ] **Step 4: Run** `go test ./internal/deal/...` → PASS; `make test` → green.

### Task 6: API, handler and e2e

**Files:**
- Modify: `api/schemas/deal.yaml`, `api/paths/deal.yaml`, `api/openapi.yaml`, `api/schemas/catalog.yaml` (done in Task 1)
- Modify: `internal/deal/handler/handler.go`, `deal.go`; create `internal/deal/handler/order.go`
- Create: `e2e/order_test.go`

- [ ] **Step 1: Spec.**
  - Schemas: `RecipientDraft {name, phone, street, commune_code}`; `CodRequest {recipient: RecipientDraft}`; `WaybillDraft {carrier, carrier_name?, tracking_code, fee}`; `Recipient {name, phone?, street?, commune_code, commune, province}`; `Waybill {source, carrier, carrier_name?, tracking_code, fee}`; `Order {id, code, status, price, recipient, waybill?, cancelled_by?, cancel_reason?, requested_at, shipped_at?, closed_at?}`; `OrderItem` (Order's fields plus `deal_id`, `listing: DealListing`); `OrderList`.
  - `Deal` gains `order` (optional); `DealStatus` gains `sold`; `Move.kind` gains the five kinds; `DealListing.status` gains `reserved`.
  - Paths, with statuses each e2e must observe:
    - `dealCod` `POST /v1/deals/{id}/cod` `requestCod`: 200, 400, 401, 403, 404, 409 (`move_not_allowed`, `listing_unavailable`, `cod_limit_reached`, `deal_changed`), 422 (`invalid_recipient`).
    - `dealShip` `POST /v1/deals/{id}/ship` `shipOrder`, `IdempotencyKey`: 200, 400, 401, 404, 409 (`move_not_allowed`, `listing_unavailable`, `deal_changed`), 422 (`invalid_waybill`).
    - `dealDelivered` `deliverOrder` and `dealReturned` `returnOrder`, `IdempotencyKey`: 200, 400, 401, 404, 409.
    - `myOrders` `GET /v1/me/orders` `listMyOrders`, `role` required: 200, 400, 401.
  - Update `cancelDeal`'s description: it also cancels a requested order.
- [ ] **Step 2: Run** `go test ./internal/app/` → `TestRoutesMatchSpec` fails for the five new operations.
- [ ] **Step 3: Handlers** in `order.go`: `RequestCod` and the three flow commands through `serve`, with request structs carrying `IdempotencyKey string \`header:"Idempotency-Key" json:"-"\`` where needed; `ListOrders` like `ListMine`. Register the five routes behind `protect`.
- [ ] **Step 4: e2e** (`order_test.go`):
  - `TestOrderShipDeliver`: two buyers agree and request COD; seller ships to buyer 1 → 200 shipped; `GET /v1/listings/{id}` by a stranger → `reserved`; seller hide → 409; poll buyer 2's deal until its order is `cancelled` with `sent_to_another`; seller reads buyer 2's order → no phone; delivered → deal `sold`, listing `sold`; `GET /v1/me/orders?role=selling` lists both orders.
  - `TestOrderReturn`: ship, returned → listing active, deal negotiating.
  - `TestOrderRefusals`: one case per declared status of each new operation (401 without token, 400 bad id or body, 403 suspended buyer, 404 stranger, 409 `move_not_allowed`/`listing_unavailable`/`cod_limit_reached` with three open orders, 422 recipient and waybill).
- [ ] **Step 5: Run** `make test` → green, status coverage included.

### Task 7: ARCHITECTURE.md

- [ ] **Step 1:** Add an `Orders` part to `### Deal` and a `reserved` bullet to `### Catalog`: states, cancel window, the 3-order limit, recipient masking, the three flows and their keys, `Reserve`/`Release`/`SellTo` keyed by order, the worker on `listing.reserved` cancelling other requests, the repository's "already saved" rule, no carrier integration and the `source` kept for it (decided 2026-10-26), the dropped COD setup module.
- [ ] **Step 2:** Run the humanizing checker on the new text and fix every hit.
- [ ] **Step 3: Run** `make test` → green.
