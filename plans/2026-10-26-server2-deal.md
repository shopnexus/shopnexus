# server2 deal: implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A buyer opens a deal on someone else's active listing, the buyer and the seller trade offers and counters until one accepts, either side cancels an agreement, and deals follow their listing's price and status changes.

**Architecture:** A new module `deal` in the five-package layout (`domain`, `repository`, `service`, `handler`, `worker`). The deal is a Postgres aggregate with `write_id`; every save writes its new moves to `deal_moves` and a `deal.moved` event in one transaction. No Restate flow: commands are plain service methods. The `worker` package is the first in server2: a Restate service subscribed to four listing events that calls `Service.ListingChanged`. Catalog gains `Summaries`, a read of listings in any status for other modules, and its `Mount` returns its service.

**Tech Stack:** Go 1.27 (stdlib `uuid`), pgx v5 with `StrictNamedArgs`, Restate Go SDK v1.1.0, Postgres 18, golangci-lint v2.

**Spec:** `~/shopnexus/specs/2026-10-26-server2-deal-design.md`

## Global Constraints

- Spec first: every endpoint, schema and error is in `api/` before its handler; `TestRoutesMatchSpec` holds routes and operations to one set; e2e must observe every status an operation declares.
- Amounts are whole đồng in multiples of 1,000 (`domain.Step`). A buyer's offer is at least half the listed price rounded up to 1,000 and below the open counter, or below the listed price; a seller's counter is above the open offer and below the listed price.
- Opening checks in order: existing deal 200; unknown listing 404 `listing_not_found`; 403 `account_suspended`; 403 `phone_required`; 409 `own_listing`; 409 `listing_unavailable`.
- `offer` and `accept` need an active listing and refuse a suspended caller; `decline`, `withdraw` and `cancel` work in any listing state and for a suspended caller.
- A write that loses a race is 409 `deal_changed` (the spec's choice; it differs from the `try_again` other modules use, since a retried move may mean something else after the other side moved).
- Someone else's deal is 404 `deal_not_found`, never 403.
- No SQL keyword as a column name (sqlfluff RF04): `deal_moves.moved_at`, `deal_moves.by_party`.
- A use case reads top to bottom; a helper exists only when several places call it.
- No commits unless the user asks; each task ends on a green `make test`.
- Comments, ARCHITECTURE.md and the migration's comments go through `python3 ~/.claude/skills/humanizing-writing/ai-tells.py`.

## Review Focus

1. Two buyers on one listing: one agreeing, or one's offer dropped by a price change, leaves the other buyer's deal as it was (Task 4 `TestListingChanged`).
2. An event delivered late, after the buyer made a new offer at the new price: the new offer stays (Task 4 `TestListingChanged`, the last call).
3. A listing whose `allow_offers` is false: the buyer can still accept the listed price and cannot offer (Task 2 `TestMoveRules` and `TestAllowedMoves`).
4. A listed price that is not a multiple of 1,000 (10,500 đ): the range is 6,000 to 10,000 and accepting 10,500 works (Task 2 `TestOfferRange`, `TestAllowedMoves`).
5. A stranger probing deal IDs: every read and move answers `deal_not_found` (Task 4 `TestStrangerSeesNoDeal`).

---

### Task 1: catalog `Summaries` and a `Mounted` result

**Files:**
- Modify: `internal/catalog/repository/repository.go`, `internal/catalog/repository/listing_pg.go`, `internal/catalog/repository/listing_pg_test.go`
- Modify: `internal/catalog/service/service.go`, `internal/catalog/service/views.go`, `internal/catalog/service/listing_get.go`, `internal/catalog/service/listing_test.go`
- Modify: `internal/catalog/catalog.go`, `internal/app/app.go`

**Interfaces:**
- Produces: `repository.Listings.GetMany(ctx, ids []uuid.UUID) ([]domain.Listing, error)`; `catalogsvc.Summary{ID, SellerID uuid.UUID; Title string; Price int64; AllowOffers bool; Status domain.Status; CoverThumbURL string}`; `catalogsvc.Service.Summaries(ctx, ids []uuid.UUID) (map[uuid.UUID]Summary, error)`; `catalog.Mounted{Services []restate.ServiceDefinition; Service service.Service}`.

- [ ] **Step 1: Failing tests.** In `listing_pg_test.go`:

  ```go
  func TestGetMany(t *testing.T) {
  	t.Parallel()
  	db := pgtest.New(t)
  	s := repository.NewListings(db)
  	ctx := context.Background()
  	seller := newAccount(t, db)
  	a, b := listing(t, seller), listing(t, seller)
  	for _, l := range []domain.Listing{a, b} {
  		if err := s.Insert(ctx, l); err != nil {
  			t.Fatal(err)
  		}
  	}
  	got, err := s.GetMany(ctx, []uuid.UUID{a.ID(), b.ID(), uuid.NewV7()})
  	if err != nil || len(got) != 2 {
  		t.Fatalf("%d %v", len(got), err)
  	}
  }
  ```

  In `listing_test.go` (service):

  ```go
  func TestSummariesReadEveryStatus(t *testing.T) {
  	t.Parallel()
  	e := newEnv(t)
  	seller := e.seller(t)
  	l := e.active(t, seller)
  	ctx := context.Background()
  	if _, err := e.catalog.Hide(ctx, seller, l.ID); err != nil {
  		t.Fatal(err)
  	}
  	unknown := uuid.NewV7()
  	got, err := e.catalog.Summaries(ctx, []uuid.UUID{l.ID, unknown})
  	if err != nil {
  		t.Fatal(err)
  	}
  	s, ok := got[l.ID]
  	if !ok || s.Status != domain.StatusHidden || s.SellerID != seller || s.Price != 9_500_000 || !s.AllowOffers ||
  		s.CoverThumbURL == "" {
  		t.Fatalf("%+v", got)
  	}
  	if _, ok := got[unknown]; ok {
  		t.Fatal("an unknown id is in the map")
  	}
  	if err := e.catalog.Delete(ctx, seller, l.ID); err != nil {
  		t.Fatal(err)
  	}
  	got, err = e.catalog.Summaries(ctx, []uuid.UUID{l.ID})
  	if err != nil || got[l.ID].Status != domain.StatusDeleted {
  		t.Fatalf("%+v %v", got, err)
  	}
  }
  ```
- [ ] **Step 2: Run** `go test ./internal/catalog/...`. Expected: build failure, `GetMany` and `Summaries` undefined.
- [ ] **Step 3: Implement.** Add to the `Listings` interface:

  ```go
  // GetMany returns the listings among ids in any status and order; an
  // unknown ID is left out.
  GetMany(ctx context.Context, ids []uuid.UUID) ([]domain.Listing, error)
  ```

  In `listing_pg.go`, move the row loop of `ListBySeller` into a helper both use:

  ```go
  // collect scans every row of a listings query.
  func collect(rows pgx.Rows) ([]domain.Listing, error) {
  	defer rows.Close()
  	var out []domain.Listing
  	for rows.Next() {
  		l, err := scanListing(rows)
  		if err != nil {
  			return nil, err
  		}
  		out = append(out, l)
  	}
  	if err := rows.Err(); err != nil {
  		return nil, fmt.Errorf("read listings: %w", err)
  	}
  	return out, nil
  }

  func (s pgListings) GetMany(ctx context.Context, ids []uuid.UUID) ([]domain.Listing, error) {
  	rows, err := s.db.Query(ctx, `SELECT `+listingColumns+` FROM listings WHERE id = ANY(@ids)`, pgx.StrictNamedArgs{"ids": ids})
  	if err != nil {
  		return nil, fmt.Errorf("select listings: %w", err)
  	}
  	return collect(rows)
  }
  ```

  `ListBySeller` ends with `return collect(rows)` after its query.

  In `views.go`:

  ```go
  // Summary is what another module reads of a listing, in any status.
  // CoverThumbURL is empty until the cover is processed.
  type Summary struct {
  	ID            uuid.UUID
  	SellerID      uuid.UUID
  	Title         string
  	Price         int64
  	AllowOffers   bool
  	Status        domain.Status
  	CoverThumbURL string
  }
  ```

  In the `Service` interface, after `ListMine`:

  ```go
  // Summaries reads listings in any status for other modules; an unknown
  // ID is left out of the map.
  Summaries(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID]Summary, error)
  ```

  In `listing_get.go`:

  ```go
  // Summaries reads listings in any status, deleted included, for other
  // modules.
  func (c *Catalog) Summaries(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID]Summary, error) {
  	rows, err := c.listings.GetMany(ctx, ids)
  	if err != nil {
  		return nil, fmt.Errorf("get listings: %w", err)
  	}
  	out := make(map[uuid.UUID]Summary, len(rows))
  	for i := range rows {
  		l := &rows[i]
  		s := Summary{
  			ID: l.ID(), SellerID: l.SellerID(), Title: l.Title(), Price: l.Price(), AllowOffers: l.AllowOffers(),
  			Status: l.Status(),
  		}
  		if p := l.Photos(); len(p) > 0 && p[0].Keys.Thumb != "" {
  			s.CoverThumbURL = c.media.URL(p[0].Keys.Thumb)
  		}
  		out[l.ID()] = s
  	}
  	return out, nil
  }
  ```

  In `catalog.go`, `Mount` returns `Mounted`, the way `media.Mount` does:

  ```go
  // Mounted is what catalog's Mount gives app and other modules.
  type Mounted struct {
  	Services []restate.ServiceDefinition
  	Service  service.Service
  }
  ```

  and ends with `return Mounted{Services: svc.Durable(), Service: svc}`; its doc says it returns catalog's Restate services and the Service other modules read listings through. In `app.go`, `catalogm := catalog.Mount(...)` and `slices.Concat(authm.Services, mediam.Services, catalogm.Services)`.
- [ ] **Step 4: Run** `go test ./internal/catalog/... ./internal/app/`. Expected: PASS.
- [ ] **Step 5: Run** `make test`. Expected: every package ok, `golangci-lint` 0 issues.

### Task 2: deal domain

**Files:**
- Create: `internal/deal/domain/deal.go`, `internal/deal/domain/errors.go`, `internal/deal/domain/deal_test.go`

**Interfaces:**
- Produces (package `github.com/shopnexus/server2/internal/deal/domain`):
  - `const Step = 1_000`
  - `type Status string` with `StatusNegotiating`, `StatusAgreed`
  - `type Party string` with `Buyer`, `Seller`, `System`
  - `type MoveKind string` with `MoveOffer`, `MoveCounter`, `MoveAccept`, `MoveDecline`, `MoveWithdraw`, `MoveCancel`, `MovePriceChanged`, `MoveOffersClosed`, `MoveListingClosed`
  - `type Move struct{ ID uuid.UUID; Kind MoveKind; By Party; Amount int64; At time.Time }` (Amount 0 = none)
  - `type OpenPrice struct{ By Party; Amount int64; At time.Time }` with JSON tags `by`, `amount`, `at`
  - `type ListingStatus string` with `ListingActive`, `ListingPaused`, `ListingHidden`, `ListingGone`
  - `type Listing struct{ Price int64; AllowOffers bool; Status ListingStatus }`
  - `type Range struct{ Min, Max int64 }` with JSON tags `min`, `max`
  - `func Open(id, listingID, buyer, seller uuid.UUID, now time.Time) Deal`
  - methods on `*Deal`: `PartyOf(account uuid.UUID) (Party, bool)`, `Offer(by Party, amount int64, l Listing, now time.Time) error`, `Accept(by Party, price int64, l Listing, now time.Time) error`, `Decline(by Party, now time.Time) error`, `Withdraw(by Party, now time.Time) error`, `Cancel(by Party, now time.Time) error`, `OfferRange(by Party, l Listing) (Range, bool)`, `ListingChanged(l Listing, now time.Time) bool`, getters `ID`, `ListingID`, `BuyerID`, `SellerID`, `Status`, `Open() *OpenPrice`, `AgreedPrice() int64`, `AgreedAt() *time.Time`, `WriteID`, `CreatedAt`, `UpdatedAt`; store-only `Pending() []Move`, `State() DealState`, `Saved(writeID uuid.UUID)`; `RestoreDeal(st DealState) Deal`
  - `type DealState struct{ ID, ListingID, BuyerID, SellerID uuid.UUID; Status Status; Open *OpenPrice; ListedPrice, AgreedPrice int64; AgreedAt *time.Time; WriteID uuid.UUID; CreatedAt, UpdatedAt time.Time }`
  - errors `ErrNotFound`, `ErrMoveNotAllowed`, `ErrListingUnavailable`, `ErrPriceChanged`, `ErrInvalidAmount`, `ErrOwnListing`, `ErrChanged`, `ErrPhoneRequired`

- [ ] **Step 1: Failing tests** in `deal_test.go` (package `domain_test`):

  ```go
  var now = time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)

  // onSale is an active listing at 1,500,000 đ that takes offers.
  var onSale = domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingActive}

  func newDeal() domain.Deal {
  	return domain.Open(uuid.NewV7(), uuid.NewV7(), uuid.NewV7(), uuid.NewV7(), now)
  }

  func kinds(d *domain.Deal) []domain.MoveKind {
  	var out []domain.MoveKind
  	for _, m := range d.Pending() {
  		out = append(out, m.Kind)
  	}
  	return out
  }

  // must fails t on an error from a setup move.
  func must(t *testing.T, err error) {
  	t.Helper()
  	if err != nil {
  		t.Fatal(err)
  	}
  }

  func TestOfferCounterAccept(t *testing.T) {
  	t.Parallel()
  	d := newDeal()
  	must(t, d.Offer(domain.Buyer, 1_000_000, onSale, now))
  	must(t, d.Offer(domain.Seller, 1_300_000, onSale, now))
  	must(t, d.Accept(domain.Buyer, 1_300_000, onSale, now))
  	if d.Status() != domain.StatusAgreed || d.AgreedPrice() != 1_300_000 || d.AgreedAt() == nil || d.Open() != nil {
  		t.Fatalf("%+v", d.State())
  	}
  	want := []domain.MoveKind{domain.MoveOffer, domain.MoveCounter, domain.MoveAccept}
  	if !slices.Equal(kinds(&d), want) {
  		t.Fatalf("%v", kinds(&d))
  	}
  	if p := d.Pending(); p[2].By != domain.Buyer || p[2].Amount != 1_300_000 {
  		t.Fatalf("%+v", p[2])
  	}
  	d.Saved(uuid.NewV7())
  	if len(d.Pending()) != 0 {
  		t.Fatal("Saved keeps the pending moves")
  	}
  }

  func TestMoveRules(t *testing.T) {
  	t.Parallel()
  	noOffers := domain.Listing{Price: 1_500_000, Status: domain.ListingActive}
  	hidden := domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingHidden}
  	offered := func(t *testing.T, d *domain.Deal) { must(t, d.Offer(domain.Buyer, 1_000_000, onSale, now)) }
  	countered := func(t *testing.T, d *domain.Deal) {
  		offered(t, d)
  		must(t, d.Offer(domain.Seller, 1_300_000, onSale, now))
  	}
  	agreed := func(t *testing.T, d *domain.Deal) { must(t, d.Accept(domain.Buyer, 1_500_000, onSale, now)) }
  	none := func(*testing.T, *domain.Deal) {}
  	cases := []struct {
  		name  string
  		setup func(*testing.T, *domain.Deal)
  		move  func(*domain.Deal) error
  		want  error
  	}{
  		{"the seller offers first", none, func(d *domain.Deal) error { return d.Offer(domain.Seller, 1_200_000, onSale, now) }, domain.ErrMoveNotAllowed},
  		{"the buyer offers twice", offered, func(d *domain.Deal) error { return d.Offer(domain.Buyer, 1_100_000, onSale, now) }, domain.ErrMoveNotAllowed},
  		{"the seller counters twice", countered, func(d *domain.Deal) error { return d.Offer(domain.Seller, 1_400_000, onSale, now) }, domain.ErrMoveNotAllowed},
  		{"the buyer accepts their own offer", offered, func(d *domain.Deal) error { return d.Accept(domain.Buyer, 1_000_000, onSale, now) }, domain.ErrPriceChanged},
  		{"the seller accepts with no offer", none, func(d *domain.Deal) error { return d.Accept(domain.Seller, 1_500_000, onSale, now) }, domain.ErrMoveNotAllowed},
  		{"the seller accepts their own counter", countered, func(d *domain.Deal) error { return d.Accept(domain.Seller, 1_300_000, onSale, now) }, domain.ErrMoveNotAllowed},
  		{"the seller accepts a stale offer", offered, func(d *domain.Deal) error { return d.Accept(domain.Seller, 900_000, onSale, now) }, domain.ErrPriceChanged},
  		{"the buyer accepts an old listed price", none, func(d *domain.Deal) error { return d.Accept(domain.Buyer, 1_400_000, onSale, now) }, domain.ErrPriceChanged},
  		{"the buyer declines their own offer", offered, func(d *domain.Deal) error { return d.Decline(domain.Buyer, now) }, domain.ErrMoveNotAllowed},
  		{"decline with nothing open", none, func(d *domain.Deal) error { return d.Decline(domain.Seller, now) }, domain.ErrMoveNotAllowed},
  		{"the seller withdraws the buyer's offer", offered, func(d *domain.Deal) error { return d.Withdraw(domain.Seller, now) }, domain.ErrMoveNotAllowed},
  		{"cancel while negotiating", offered, func(d *domain.Deal) error { return d.Cancel(domain.Buyer, now) }, domain.ErrMoveNotAllowed},
  		{"offer after agreeing", agreed, func(d *domain.Deal) error { return d.Offer(domain.Buyer, 1_000_000, onSale, now) }, domain.ErrMoveNotAllowed},
  		{"accept after agreeing", agreed, func(d *domain.Deal) error { return d.Accept(domain.Buyer, 1_500_000, onSale, now) }, domain.ErrMoveNotAllowed},
  		{"offer on a listing without offers", none, func(d *domain.Deal) error { return d.Offer(domain.Buyer, 1_000_000, noOffers, now) }, domain.ErrMoveNotAllowed},
  		{"offer on a hidden listing", none, func(d *domain.Deal) error { return d.Offer(domain.Buyer, 1_000_000, hidden, now) }, domain.ErrListingUnavailable},
  		{"accept on a hidden listing", none, func(d *domain.Deal) error { return d.Accept(domain.Buyer, 1_500_000, hidden, now) }, domain.ErrListingUnavailable},
  	}
  	for _, c := range cases {
  		t.Run(c.name, func(t *testing.T) {
  			t.Parallel()
  			d := newDeal()
  			c.setup(t, &d)
  			before := len(d.Pending())
  			if err := c.move(&d); !errors.Is(err, c.want) {
  				t.Fatalf("got %v, want %v", err, c.want)
  			}
  			if len(d.Pending()) != before {
  				t.Fatal("a refused move was recorded")
  			}
  		})
  	}
  }

  func TestAllowedMoves(t *testing.T) {
  	t.Parallel()
  	d := newDeal()
  	must(t, d.Offer(domain.Buyer, 1_000_000, onSale, now))
  	must(t, d.Withdraw(domain.Buyer, now))
  	must(t, d.Offer(domain.Buyer, 1_000_000, onSale, now))
  	must(t, d.Decline(domain.Seller, now))
  	must(t, d.Offer(domain.Buyer, 1_000_000, onSale, now))
  	must(t, d.Offer(domain.Seller, 1_300_000, onSale, now))
  	must(t, d.Decline(domain.Buyer, now))
  	must(t, d.Offer(domain.Buyer, 1_100_000, onSale, now))
  	// The buyer takes the listed price over their own open offer.
  	must(t, d.Accept(domain.Buyer, 1_500_000, onSale, now))
  	must(t, d.Cancel(domain.Seller, now))
  	if d.Status() != domain.StatusNegotiating || d.AgreedPrice() != 0 || d.AgreedAt() != nil || d.Open() != nil {
  		t.Fatalf("%+v", d.State())
  	}
  	fixed := newDeal()
  	must(t, fixed.Accept(domain.Buyer, 1_500_000, domain.Listing{Price: 1_500_000, Status: domain.ListingActive}, now))
  	odd := newDeal()
  	must(t, odd.Accept(domain.Buyer, 10_500, domain.Listing{Price: 10_500, AllowOffers: true, Status: domain.ListingActive}, now))
  }

  func TestOfferRange(t *testing.T) {
  	t.Parallel()
  	at := func(price int64) domain.Listing {
  		return domain.Listing{Price: price, AllowOffers: true, Status: domain.ListingActive}
  	}
  	cases := []struct {
  		name    string
  		l       domain.Listing
  		offer   int64 // the buyer's open offer, 0 for none
  		counter int64 // the seller's counter to it, 0 for none
  		by      domain.Party
  		want    domain.Range
  		ok      bool
  	}{
  		{"buyer, listed price", at(1_500_000), 0, 0, domain.Buyer, domain.Range{Min: 750_000, Max: 1_499_000}, true},
  		{"buyer, cheapest listing", at(10_000), 0, 0, domain.Buyer, domain.Range{Min: 5_000, Max: 9_000}, true},
  		{"buyer, odd price", at(10_500), 0, 0, domain.Buyer, domain.Range{Min: 6_000, Max: 10_000}, true},
  		{"buyer, under a counter", at(1_500_000), 1_000_000, 1_200_000, domain.Buyer, domain.Range{Min: 750_000, Max: 1_199_000}, true},
  		{"seller, over an offer", at(1_500_000), 1_000_000, 0, domain.Seller, domain.Range{Min: 1_001_000, Max: 1_499_000}, true},
  		{"seller, offer one step under", at(1_500_000), 1_499_000, 0, domain.Seller, domain.Range{}, false},
  		{"buyer with an open offer", at(1_500_000), 1_000_000, 0, domain.Buyer, domain.Range{}, false},
  		{"seller with nothing open", at(1_500_000), 0, 0, domain.Seller, domain.Range{}, false},
  		{"buyer, no offers", domain.Listing{Price: 1_500_000, Status: domain.ListingActive}, 0, 0, domain.Buyer, domain.Range{}, false},
  		{"buyer, paused listing", domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingPaused}, 0, 0, domain.Buyer, domain.Range{}, false},
  	}
  	for _, c := range cases {
  		t.Run(c.name, func(t *testing.T) {
  			t.Parallel()
  			d := newDeal()
  			if c.offer != 0 {
  				must(t, d.Offer(domain.Buyer, c.offer, at(c.l.Price), now))
  			}
  			if c.counter != 0 {
  				must(t, d.Offer(domain.Seller, c.counter, at(c.l.Price), now))
  			}
  			got, ok := d.OfferRange(c.by, c.l)
  			if got != c.want || ok != c.ok {
  				t.Fatalf("got %+v %v", got, ok)
  			}
  		})
  	}
  }

  func TestOfferAmounts(t *testing.T) {
  	t.Parallel()
  	cases := []struct {
  		name    string
  		by      domain.Party
  		amount  int64
  		problem string
  	}{
  		{"not a multiple of 1,000", domain.Buyer, 1_000_500, "step"},
  		{"under half the price", domain.Buyer, 749_000, "out_of_range"},
  		{"the listed price", domain.Buyer, 1_500_000, "out_of_range"},
  		{"a counter at the offer", domain.Seller, 1_000_000, "out_of_range"},
  		{"a counter at the listed price", domain.Seller, 1_500_000, "out_of_range"},
  	}
  	for _, c := range cases {
  		t.Run(c.name, func(t *testing.T) {
  			t.Parallel()
  			d := newDeal()
  			if c.by == domain.Seller {
  				must(t, d.Offer(domain.Buyer, 1_000_000, onSale, now))
  			}
  			err := d.Offer(c.by, c.amount, onSale, now)
  			if !errors.Is(err, domain.ErrInvalidAmount) || apperr.From(err).Fields["amount"] != c.problem {
  				t.Fatalf("%v", err)
  			}
  		})
  	}
  }

  func TestListingChanged(t *testing.T) {
  	t.Parallel()
  	offered := func(t *testing.T) domain.Deal {
  		t.Helper()
  		d := newDeal()
  		must(t, d.Offer(domain.Buyer, 1_000_000, onSale, now))
  		d.Saved(uuid.NewV7())
  		return d
  	}
  	cases := []struct {
  		name string
  		l    domain.Listing
  		want domain.MoveKind // "" for no change
  	}{
  		{"same listing", onSale, ""},
  		{"paused at the same price", domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingPaused}, ""},
  		{"new price", domain.Listing{Price: 1_400_000, AllowOffers: true, Status: domain.ListingActive}, domain.MovePriceChanged},
  		{"new price while paused", domain.Listing{Price: 1_400_000, AllowOffers: true, Status: domain.ListingPaused}, domain.MovePriceChanged},
  		{"offers off", domain.Listing{Price: 1_500_000, Status: domain.ListingActive}, domain.MoveOffersClosed},
  		{"hidden", domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingHidden}, domain.MoveListingClosed},
  		{"gone", domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingGone}, domain.MoveListingClosed},
  	}
  	for _, c := range cases {
  		t.Run(c.name, func(t *testing.T) {
  			t.Parallel()
  			d := offered(t)
  			changed := d.ListingChanged(c.l, now)
  			if changed != (c.want != "") {
  				t.Fatalf("changed %v", changed)
  			}
  			if !changed {
  				if d.Open() == nil {
  					t.Fatal("the open price went")
  				}
  				return
  			}
  			p := d.Pending()
  			if d.Open() != nil || len(p) != 1 || p[0].Kind != c.want || p[0].By != domain.System {
  				t.Fatalf("%+v %+v", d.State(), p)
  			}
  			if c.want == domain.MovePriceChanged && p[0].Amount != c.l.Price {
  				t.Fatalf("amount %d", p[0].Amount)
  			}
  			d.Saved(uuid.NewV7())
  			if d.ListingChanged(c.l, now) {
  				t.Fatal("a second call changed the deal again")
  			}
  		})
  	}
  }

  func TestListingGoneEndsTheAgreement(t *testing.T) {
  	t.Parallel()
  	d := newDeal()
  	must(t, d.Accept(domain.Buyer, 1_500_000, onSale, now))
  	d.Saved(uuid.NewV7())
  	if d.ListingChanged(domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingHidden}, now) {
  		t.Fatal("a hidden listing ended the agreement")
  	}
  	if !d.ListingChanged(domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingGone}, now) ||
  		d.Status() != domain.StatusNegotiating || d.AgreedPrice() != 0 || kinds(&d)[0] != domain.MoveListingClosed {
  		t.Fatalf("%+v %v", d.State(), kinds(&d))
  	}
  }

  func TestPartyOf(t *testing.T) {
  	t.Parallel()
  	buyer, seller := uuid.NewV7(), uuid.NewV7()
  	d := domain.Open(uuid.NewV7(), uuid.NewV7(), buyer, seller, now)
  	if p, ok := d.PartyOf(buyer); p != domain.Buyer || !ok {
  		t.Fatal("buyer")
  	}
  	if p, ok := d.PartyOf(seller); p != domain.Seller || !ok {
  		t.Fatal("seller")
  	}
  	if _, ok := d.PartyOf(uuid.NewV7()); ok {
  		t.Fatal("a stranger is a party")
  	}
  }
  ```
- [ ] **Step 2: Run** `go test ./internal/deal/...`. Expected: build failure, package `domain` has no Go files.
- [ ] **Step 3: Implement** `errors.go`:

  ```go
  package domain

  import "github.com/shopnexus/server2/internal/platform/apperr"

  var (
  	ErrNotFound           = apperr.New(apperr.KindNotFound, "deal_not_found", "no such deal of the caller's")
  	ErrMoveNotAllowed     = apperr.New(apperr.KindConflict, "move_not_allowed", "the deal's state or the caller's side does not allow this move")
  	ErrListingUnavailable = apperr.New(apperr.KindConflict, "listing_unavailable", "the listing is not on sale")
  	ErrPriceChanged       = apperr.New(apperr.KindConflict, "price_changed", "the price to accept has changed")
  	ErrInvalidAmount      = apperr.New(apperr.KindInvalid, "invalid_amount", "the amount is outside the offer range; see fields")
  	ErrOwnListing         = apperr.New(apperr.KindConflict, "own_listing", "a seller cannot open a deal on their own listing")
  	ErrChanged            = apperr.New(apperr.KindConflict, "deal_changed", "the other side moved first; read the deal again")
  	ErrPhoneRequired      = apperr.New(apperr.KindForbidden, "phone_required", "add a verified phone number before dealing")
  )
  ```

  and `deal.go`:

  ```go
  // Package domain holds module deal's entity: a buyer and a seller agreeing
  // a price on one listing, move by move.
  package domain

  import (
  	"time"
  	"uuid"
  )

  // Step is the unit of every offer and counter, in đồng.
  const Step = 1_000

  type Status string

  const (
  	StatusNegotiating Status = "negotiating"
  	StatusAgreed      Status = "agreed"
  )

  // Party is who made a move. System is the server, following a change of
  // the listing.
  type Party string

  const (
  	Buyer  Party = "buyer"
  	Seller Party = "seller"
  	System Party = "system"
  )

  type MoveKind string

  const (
  	MoveOffer         MoveKind = "offer"
  	MoveCounter       MoveKind = "counter"
  	MoveAccept        MoveKind = "accept"
  	MoveDecline       MoveKind = "decline"
  	MoveWithdraw      MoveKind = "withdraw"
  	MoveCancel        MoveKind = "cancel"
  	MovePriceChanged  MoveKind = "price_changed"
  	MoveOffersClosed  MoveKind = "offers_closed"
  	MoveListingClosed MoveKind = "listing_closed"
  )

  // Move is one step of a deal's thread. Amount is 0 on a move without one;
  // on price_changed it is the new listed price.
  type Move struct {
  	ID     uuid.UUID
  	Kind   MoveKind
  	By     Party
  	Amount int64
  	At     time.Time
  }

  // OpenPrice is the offer or counter waiting for the other side.
  type OpenPrice struct {
  	By     Party     `json:"by"`
  	Amount int64     `json:"amount"`
  	At     time.Time `json:"at"`
  }

  // ListingStatus is what the rules see of a listing's status.
  type ListingStatus string

  const (
  	ListingActive ListingStatus = "active"
  	// ListingPaused is a listing in processing or rejected after an edit
  	// of its photos. It is not closed, and takes no new price.
  	ListingPaused ListingStatus = "paused"
  	ListingHidden ListingStatus = "hidden"
  	// ListingGone is a listing sold or deleted.
  	ListingGone ListingStatus = "gone"
  )

  // Listing is what the rules read of a deal's listing, as it is now.
  type Listing struct {
  	Price       int64
  	AllowOffers bool
  	Status      ListingStatus
  }

  // Range is the amounts an offer may take, both ends included.
  type Range struct {
  	Min int64 `json:"min"`
  	Max int64 `json:"max"`
  }

  // Deal is a buyer's negotiation with a seller over one listing. It holds
  // at most one open price; agreeing reserves nothing.
  type Deal struct {
  	id          uuid.UUID
  	listingID   uuid.UUID
  	buyerID     uuid.UUID
  	sellerID    uuid.UUID
  	status      Status
  	open        *OpenPrice
  	listedPrice int64
  	agreedPrice int64
  	agreedAt    *time.Time
  	writeID     uuid.UUID
  	createdAt   time.Time
  	updatedAt   time.Time
  	pending     []Move
  }

  // Open starts the buyer's deal on a listing, negotiating with nothing
  // open. The first write ID is the id.
  func Open(id, listingID, buyer, seller uuid.UUID, now time.Time) Deal {
  	return Deal{
  		id: id, listingID: listingID, buyerID: buyer, sellerID: seller, status: StatusNegotiating,
  		writeID: id, createdAt: now, updatedAt: now,
  	}
  }

  // PartyOf returns account's side of the deal; false for anyone else.
  func (d *Deal) PartyOf(account uuid.UUID) (Party, bool) {
  	switch account {
  	case d.buyerID:
  		return Buyer, true
  	case d.sellerID:
  		return Seller, true
  	}
  	return "", false
  }

  // OfferRange is the amounts by's next offer may take: the buyer's with
  // nothing open or under the seller's counter, the seller's counter over
  // the buyer's offer. False when by may not offer now or no amount fits.
  func (d *Deal) OfferRange(by Party, l Listing) (Range, bool) {
  	if d.status != StatusNegotiating || l.Status != ListingActive {
  		return Range{}, false
  	}
  	var r Range
  	switch {
  	case by == Buyer && l.AllowOffers && (d.open == nil || d.open.By == Seller):
  		ceiling := l.Price
  		if d.open != nil {
  			ceiling = d.open.Amount
  		}
  		r = Range{Min: roundUp((l.Price + 1) / 2), Max: below(ceiling)}
  	case by == Seller && d.open != nil && d.open.By == Buyer:
  		r = Range{Min: d.open.Amount/Step*Step + Step, Max: below(l.Price)}
  	default:
  		return Range{}, false
  	}
  	return r, r.Min <= r.Max
  }

  // Offer opens a price: the buyer's offer, or the seller's counter to it.
  func (d *Deal) Offer(by Party, amount int64, l Listing, now time.Time) error {
  	if l.Status != ListingActive {
  		return ErrListingUnavailable
  	}
  	r, ok := d.OfferRange(by, l)
  	if !ok {
  		return ErrMoveNotAllowed
  	}
  	if amount%Step != 0 {
  		return ErrInvalidAmount.WithField("amount", "step")
  	}
  	if amount < r.Min || amount > r.Max {
  		return ErrInvalidAmount.WithField("amount", "out_of_range")
  	}
  	kind := MoveOffer
  	if by == Seller {
  		kind = MoveCounter
  	}
  	d.open, d.listedPrice = &OpenPrice{By: by, Amount: amount, At: now}, l.Price
  	d.record(kind, by, amount, now)
  	return nil
  }

  // Accept agrees the deal at price, the price the person saw: the other
  // side's open price or, for the buyer, the listed price.
  func (d *Deal) Accept(by Party, price int64, l Listing, now time.Time) error {
  	if l.Status != ListingActive {
  		return ErrListingUnavailable
  	}
  	if d.status != StatusNegotiating {
  		return ErrMoveNotAllowed
  	}
  	facing := d.open != nil && d.open.By != by
  	switch {
  	case facing && price == d.open.Amount, by == Buyer && price == l.Price:
  	case facing || by == Buyer:
  		return ErrPriceChanged
  	default:
  		return ErrMoveNotAllowed
  	}
  	d.status, d.agreedPrice, d.agreedAt, d.open = StatusAgreed, price, &now, nil
  	d.record(MoveAccept, by, price, now)
  	return nil
  }

  // Decline turns down the other side's open price.
  func (d *Deal) Decline(by Party, now time.Time) error {
  	if d.open == nil || d.open.By == by {
  		return ErrMoveNotAllowed
  	}
  	d.open = nil
  	d.record(MoveDecline, by, 0, now)
  	return nil
  }

  // Withdraw takes back by's own open price.
  func (d *Deal) Withdraw(by Party, now time.Time) error {
  	if d.open == nil || d.open.By != by {
  		return ErrMoveNotAllowed
  	}
  	d.open = nil
  	d.record(MoveWithdraw, by, 0, now)
  	return nil
  }

  // Cancel drops the agreed price; the deal negotiates again.
  func (d *Deal) Cancel(by Party, now time.Time) error {
  	if d.status != StatusAgreed {
  		return ErrMoveNotAllowed
  	}
  	d.status, d.agreedPrice, d.agreedAt = StatusNegotiating, 0, nil
  	d.record(MoveCancel, by, 0, now)
  	return nil
  }

  // ListingChanged brings the deal in line with its listing and reports
  // whether it changed. A hidden or gone listing takes the open price back,
  // a gone one the agreement too; a new listed price, or offers turned off,
  // takes the open price back. A second call with the same listing changes
  // nothing.
  func (d *Deal) ListingChanged(l Listing, now time.Time) bool {
  	if d.status == StatusAgreed {
  		if l.Status != ListingGone {
  			return false
  		}
  		d.status, d.agreedPrice, d.agreedAt = StatusNegotiating, 0, nil
  		d.record(MoveListingClosed, System, 0, now)
  		return true
  	}
  	if d.open == nil {
  		return false
  	}
  	var (
  		kind   MoveKind
  		amount int64
  	)
  	switch {
  	case l.Status == ListingHidden || l.Status == ListingGone:
  		kind = MoveListingClosed
  	case l.Price != d.listedPrice:
  		kind, amount = MovePriceChanged, l.Price
  	case !l.AllowOffers:
  		kind = MoveOffersClosed
  	default:
  		return false
  	}
  	d.open = nil
  	d.record(kind, System, amount, now)
  	return true
  }

  // record adds a move to the ones the next save writes.
  func (d *Deal) record(kind MoveKind, by Party, amount int64, now time.Time) {
  	d.pending = append(d.pending, Move{ID: uuid.NewV7(), Kind: kind, By: by, Amount: amount, At: now})
  	d.updatedAt = now
  }

  // roundUp is the smallest multiple of Step at or above v.
  func roundUp(v int64) int64 { return (v + Step - 1) / Step * Step }

  // below is the largest multiple of Step under v.
  func below(v int64) int64 { return (v - 1) / Step * Step }

  func (d *Deal) ID() uuid.UUID        { return d.id }
  func (d *Deal) ListingID() uuid.UUID { return d.listingID }
  func (d *Deal) BuyerID() uuid.UUID   { return d.buyerID }
  func (d *Deal) SellerID() uuid.UUID  { return d.sellerID }
  func (d *Deal) Status() Status       { return d.status }
  func (d *Deal) AgreedPrice() int64   { return d.agreedPrice }
  func (d *Deal) AgreedAt() *time.Time { return d.agreedAt }
  func (d *Deal) WriteID() uuid.UUID   { return d.writeID }
  func (d *Deal) CreatedAt() time.Time { return d.createdAt }
  func (d *Deal) UpdatedAt() time.Time { return d.updatedAt }

  // Open returns a copy of the open price, nil when none is open.
  func (d *Deal) Open() *OpenPrice {
  	if d.open == nil {
  		return nil
  	}
  	return new(*d.open)
  }

  // Pending returns the moves made since the deal was loaded. Stores only.
  func (d *Deal) Pending() []Move { return append([]Move{}, d.pending...) }

  // DealState is every stored field of a deal. Stores only.
  type DealState struct {
  	ID          uuid.UUID
  	ListingID   uuid.UUID
  	BuyerID     uuid.UUID
  	SellerID    uuid.UUID
  	Status      Status
  	Open        *OpenPrice
  	ListedPrice int64
  	AgreedPrice int64
  	AgreedAt    *time.Time
  	WriteID     uuid.UUID
  	CreatedAt   time.Time
  	UpdatedAt   time.Time
  }

  // RestoreDeal rebuilds a stored deal. Stores only.
  func RestoreDeal(st DealState) Deal {
  	return Deal{
  		id: st.ID, listingID: st.ListingID, buyerID: st.BuyerID, sellerID: st.SellerID, status: st.Status,
  		open: st.Open, listedPrice: st.ListedPrice, agreedPrice: st.AgreedPrice, agreedAt: st.AgreedAt,
  		writeID: st.WriteID, createdAt: st.CreatedAt, updatedAt: st.UpdatedAt,
  	}
  }

  // State returns every stored field. Stores only.
  func (d *Deal) State() DealState {
  	return DealState{
  		ID: d.id, ListingID: d.listingID, BuyerID: d.buyerID, SellerID: d.sellerID, Status: d.status,
  		Open: d.Open(), ListedPrice: d.listedPrice, AgreedPrice: d.agreedPrice, AgreedAt: d.agreedAt,
  		WriteID: d.writeID, CreatedAt: d.createdAt, UpdatedAt: d.updatedAt,
  	}
  }

  // Saved records that a store wrote d and its pending moves under
  // writeID. Stores only.
  func (d *Deal) Saved(writeID uuid.UUID) { d.writeID, d.pending = writeID, nil }
  ```

  If `funcorder` asks for the exported methods before the unexported ones, move `record`, `roundUp` and `below` to the end of the file.
- [ ] **Step 4: Run** `go test ./internal/deal/domain/`. Expected: PASS.
- [ ] **Step 5: Run** `make test`. Expected: green, 0 lint issues.

### Task 3: migration, repository and the `deal.moved` kind

**Files:**
- Create: `migrations/0008_deal.sql`
- Create: `internal/deal/repository/repository.go`, `internal/deal/repository/deal_pg.go`, `internal/deal/repository/deal_pg_test.go`
- Modify: `internal/platform/events/events.go`

**Interfaces:**
- Consumes: Task 2's `domain` package.
- Produces: `events.DealMoved Kind = "deal.moved"`; `repository.ErrNotFound`, `repository.ErrConflict`; `repository.NewDeals(db *pgxpool.Pool) Deals` with

  ```go
  type Deals interface {
  	// Insert adds d and reports true, or false when the buyer already has
  	// a deal on the listing; then nothing is written.
  	Insert(ctx context.Context, d domain.Deal) (bool, error)
  	// Get returns ErrNotFound for an unknown id.
  	Get(ctx context.Context, id uuid.UUID) (domain.Deal, error)
  	// Find returns the buyer's deal on a listing, or ErrNotFound.
  	Find(ctx context.Context, listingID, buyer uuid.UUID) (domain.Deal, error)
  	// Save writes d, its pending moves and evs when its row still has
  	// d.WriteID() or already has writeID, then sets its write ID.
  	// Otherwise ErrConflict and nothing is written.
  	Save(ctx context.Context, d *domain.Deal, writeID uuid.UUID, evs ...events.Event) error
  	// OfListing returns every deal on a listing, oldest first.
  	OfListing(ctx context.Context, listingID uuid.UUID) ([]domain.Deal, error)
  	// ListByParty is a query: account's deals on side as (buyer or
  	// seller) with IDs below p.Before(), newest first, at most p.Fetch().
  	ListByParty(ctx context.Context, account uuid.UUID, as domain.Party, p page.Request) ([]domain.Deal, error)
  	// Moves returns each deal's moves, oldest first; a deal without moves
  	// is absent.
  	Moves(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID][]domain.Move, error)
  }
  ```

- [ ] **Step 1: Migration** `migrations/0008_deal.sql`:

  ```sql
  -- Deals: a buyer and a seller agreeing a price on one listing. A deal holds
  -- at most one open price, the buyer's offer or the seller's counter;
  -- deal_moves keeps every move for the thread.

  CREATE TABLE deals (
      id           uuid PRIMARY KEY,
      listing_id   uuid NOT NULL REFERENCES listings (id),
      buyer_id     uuid NOT NULL REFERENCES accounts (id),
      seller_id    uuid NOT NULL REFERENCES accounts (id),
      status       text NOT NULL CHECK (status IN ('negotiating', 'agreed')),
      open_by      text CHECK (open_by IN ('buyer', 'seller')),
      open_amount  bigint,
      open_at      timestamptz,
      -- The listed price when the open price was made.
      listed_price bigint NOT NULL,
      agreed_price bigint,
      agreed_at    timestamptz,
      write_id     uuid NOT NULL,
      created_at   timestamptz NOT NULL,
      updated_at   timestamptz NOT NULL,
      UNIQUE (listing_id, buyer_id),
      CHECK ((open_by IS NULL) = (open_amount IS NULL) AND (open_by IS NULL) = (open_at IS NULL)),
      CHECK ((status = 'agreed') = (agreed_price IS NOT NULL) AND (agreed_price IS NULL) = (agreed_at IS NULL))
  );

  CREATE INDEX deals_buyer ON deals (buyer_id, id);
  CREATE INDEX deals_seller ON deals (seller_id, id);

  CREATE TABLE deal_moves (
      id       uuid PRIMARY KEY,
      deal_id  uuid NOT NULL REFERENCES deals (id),
      kind     text NOT NULL CHECK (kind IN (
          'offer', 'counter', 'accept', 'decline', 'withdraw', 'cancel', 'price_changed', 'offers_closed',
          'listing_closed'
      )),
      by_party text NOT NULL CHECK (by_party IN ('buyer', 'seller', 'system')),
      -- The offered or agreed price, or the new listed price; NULL otherwise.
      amount   bigint,
      moved_at timestamptz NOT NULL
  );

  CREATE INDEX deal_moves_deal ON deal_moves (deal_id, id);
  ```

  Run `sqlfluff lint migrations/0008_deal.sql` and fix what it reports in the layout of `0007_catalog.sql`.
- [ ] **Step 2: Failing tests** `deal_pg_test.go` (package `repository_test`). Setup inserts accounts as catalog's repository test does and a listing through `catalogrepo.NewListings(db).Insert` of a `catalogdomain.NewListing(...)` (tests may import other modules' repositories):

  ```go
  var now = time.Date(2026, 10, 26, 9, 0, 0, 0, time.UTC)

  var onSale = domain.Listing{Price: 1_500_000, AllowOffers: true, Status: domain.ListingActive}

  func newAccount(t *testing.T, db *pgxpool.Pool) uuid.UUID {
  	t.Helper()
  	id := uuid.NewV7()
  	if _, err := db.Exec(context.Background(), `INSERT INTO accounts (id, write_id) VALUES (@id, @id)`, pgx.StrictNamedArgs{"id": id}); err != nil {
  		t.Fatal(err)
  	}
  	return id
  }

  // newListing inserts a listing of seller's and returns its ID.
  func newListing(t *testing.T, db *pgxpool.Pool, seller uuid.UUID) uuid.UUID {
  	t.Helper()
  	l, err := catalogdomain.NewListing(uuid.NewV7(), seller, catalogdomain.Draft{
  		Title: "Xe đạp", Price: 1_500_000, CategoryCode: "vehicles.bicycle", Condition: catalogdomain.ConditionUsed,
  		AllowOffers: true, CommuneCode: "00004", Photos: []uuid.UUID{uuid.NewV7()},
  	}, catalogdomain.Refs{CategoryIsLeaf: true, CommuneExists: true}, now)
  	if err != nil {
  		t.Fatal(err)
  	}
  	if err = catalogrepo.NewListings(db).Insert(context.Background(), l); err != nil {
  		t.Fatal(err)
  	}
  	return l.ID()
  }
  ```

  Tests:
  - `TestInsertFindGet`: `Insert` → true; a second `domain.Open` for the same listing and buyer → false; `Find` returns the first deal's ID; `Get` of it has status negotiating and no open price; `Get(uuid.NewV7())` and `Find(listing, otherBuyer)` → `ErrNotFound`.
  - `TestSaveWritesMovesAndEvent`: `d.Offer(domain.Buyer, 1_000_000, onSale, now)`, `Save(ctx, &d, uuid.NewV7(), events.Event{ID: uuid.NewV7(), Kind: events.DealMoved, SubjectID: d.ID(), OccurredAt: now})`; `Get` has `Open()` `{buyer, 1_000_000}` and `State().ListedPrice` 1,500,000; `Moves(ctx, []uuid.UUID{d.ID()})[d.ID()]` is one offer by buyer, amount 1,000,000; `SELECT count(*) FROM events WHERE subject_id = @id AND kind = 'deal.moved'` is 1. Then `d.Accept(domain.Buyer, 1_500_000, onSale, now)`, save, `Get`: agreed, `AgreedPrice` 1,500,000, `AgreedAt` set, no open price; `d.Cancel(domain.Seller, now)`, save, `Get`: negotiating, `AgreedAt` nil; three moves, the cancel with amount 0.
  - `TestSaveRefusesAStaleDeal`: load the deal twice; first copy offers and saves; second copy offers and saves → `errors.Is(err, repository.ErrConflict)`; `Moves` still holds one move.
  - `TestListByPartyAndOfListing`: one listing, two buyers each with a deal, a second listing with a third deal of buyer 1. `ListByParty(seller, domain.Seller, page.Request{Limit: 1})` returns 2 rows (Fetch), newest first; `ListByParty(buyer1, domain.Buyer, page.Request{})` returns buyer 1's two deals newest first; `OfListing(listing1)` returns the two deals of listing 1, oldest first.
- [ ] **Step 3: Run** `go test ./internal/deal/repository/`. Expected: build failure, `repository` undefined.
- [ ] **Step 4: Implement.** Add `DealMoved Kind = "deal.moved"` to the kinds in `events.go`. `repository.go` holds the package doc ("Package repository stores module deal's deals and their moves in Postgres. Each method is its own transaction."), the two errors (`errors.New("deal: not found")`, `errors.New("deal: changed meanwhile")`) and the interface above. `deal_pg.go`:

  ```go
  type pgDeals struct{ db *pgxpool.Pool }

  func NewDeals(db *pgxpool.Pool) Deals { return pgDeals{db} }

  const dealColumns = `id, listing_id, buyer_id, seller_id, status, open_by, open_amount, open_at, listed_price,
         agreed_price, agreed_at, write_id, created_at, updated_at`

  const selectDeal = `SELECT ` + dealColumns + ` FROM deals `

  func scanDeal(row pgx.Row) (domain.Deal, error) {
  	var (
  		st         domain.DealState
  		openBy     *domain.Party
  		openAmount *int64
  		openAt     *time.Time
  		agreed     *int64
  	)
  	if err := row.Scan(&st.ID, &st.ListingID, &st.BuyerID, &st.SellerID, &st.Status, &openBy, &openAmount, &openAt,
  		&st.ListedPrice, &agreed, &st.AgreedAt, &st.WriteID, &st.CreatedAt, &st.UpdatedAt); err != nil {
  		return domain.Deal{}, fmt.Errorf("scan deal: %w", err)
  	}
  	if openBy != nil {
  		st.Open = &domain.OpenPrice{By: *openBy, Amount: *openAmount, At: *openAt}
  	}
  	if agreed != nil {
  		st.AgreedPrice = *agreed
  	}
  	return domain.RestoreDeal(st), nil
  }

  // dealArgs are a deal's columns as named arguments, NULL where the state
  // has nothing.
  func dealArgs(st domain.DealState) pgx.StrictNamedArgs {
  	a := pgx.StrictNamedArgs{
  		"id": st.ID, "listing_id": st.ListingID, "buyer_id": st.BuyerID, "seller_id": st.SellerID,
  		"status": st.Status, "open_by": nil, "open_amount": nil, "open_at": nil, "listed_price": st.ListedPrice,
  		"agreed_price": nil, "agreed_at": st.AgreedAt, "write_id": st.WriteID, "created_at": st.CreatedAt,
  		"updated_at": st.UpdatedAt,
  	}
  	if o := st.Open; o != nil {
  		a["open_by"], a["open_amount"], a["open_at"] = o.By, o.Amount, o.At
  	}
  	if st.Status == domain.StatusAgreed {
  		a["agreed_price"] = st.AgreedPrice
  	}
  	return a
  }

  const insertDeal = `
  INSERT INTO deals (` + dealColumns + `)
  VALUES (@id, @listing_id, @buyer_id, @seller_id, @status, @open_by, @open_amount, @open_at, @listed_price,
          @agreed_price, @agreed_at, @write_id, @created_at, @updated_at)
  ON CONFLICT (listing_id, buyer_id) DO NOTHING`

  func (s pgDeals) Insert(ctx context.Context, d domain.Deal) (bool, error) {
  	tag, err := s.db.Exec(ctx, insertDeal, dealArgs(d.State()))
  	if err != nil {
  		return false, fmt.Errorf("insert deal: %w", err)
  	}
  	return tag.RowsAffected() == 1, nil
  }

  func (s pgDeals) Get(ctx context.Context, id uuid.UUID) (domain.Deal, error) {
  	return s.one(ctx, selectDeal+`WHERE id = @id`, pgx.StrictNamedArgs{"id": id})
  }

  func (s pgDeals) Find(ctx context.Context, listingID, buyer uuid.UUID) (domain.Deal, error) {
  	return s.one(ctx, selectDeal+`WHERE listing_id = @listing_id AND buyer_id = @buyer_id`,
  		pgx.StrictNamedArgs{"listing_id": listingID, "buyer_id": buyer})
  }

  // one reads the deal query q finds, or ErrNotFound.
  func (s pgDeals) one(ctx context.Context, q string, a pgx.StrictNamedArgs) (domain.Deal, error) {
  	d, err := scanDeal(s.db.QueryRow(ctx, q, a))
  	if errors.Is(err, pgx.ErrNoRows) {
  		return domain.Deal{}, ErrNotFound
  	}
  	if err != nil {
  		return domain.Deal{}, fmt.Errorf("select deal: %w", err)
  	}
  	return d, nil
  }

  const saveDeal = `
  UPDATE deals
  SET status = @status, open_by = @open_by, open_amount = @open_amount, open_at = @open_at,
      listed_price = @listed_price, agreed_price = @agreed_price, agreed_at = @agreed_at,
      updated_at = @updated_at, write_id = @write_id
  WHERE id = @id AND (write_id = @read_write_id OR write_id = @write_id)`

  const insertMove = `
  INSERT INTO deal_moves (id, deal_id, kind, by_party, amount, moved_at)
  VALUES (@id, @deal_id, @kind, @by_party, @amount, @moved_at)
  ON CONFLICT (id) DO NOTHING`

  func (s pgDeals) Save(ctx context.Context, d *domain.Deal, writeID uuid.UUID, evs ...events.Event) error {
  	st := d.State()
  	a := dealArgs(st)
  	a["read_write_id"], a["write_id"] = st.WriteID, writeID
  	for _, k := range []string{"listing_id", "buyer_id", "seller_id", "created_at"} {
  		delete(a, k)
  	}
  	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
  		tag, err := tx.Exec(ctx, saveDeal, a)
  		if err != nil {
  			return fmt.Errorf("update deal: %w", err)
  		}
  		if tag.RowsAffected() == 0 {
  			return ErrConflict
  		}
  		for _, m := range d.Pending() {
  			var amount *int64
  			if m.Amount != 0 {
  				amount = &m.Amount
  			}
  			if _, err := tx.Exec(ctx, insertMove, pgx.StrictNamedArgs{
  				"id": m.ID, "deal_id": st.ID, "kind": m.Kind, "by_party": m.By, "amount": amount, "moved_at": m.At,
  			}); err != nil {
  				return fmt.Errorf("insert move: %w", err)
  			}
  		}
  		for _, e := range evs {
  			if err := events.Insert(ctx, tx, e); err != nil {
  				return err
  			}
  		}
  		return nil
  	})
  	if err != nil {
  		return fmt.Errorf("save deal: %w", err)
  	}
  	d.Saved(writeID)
  	return nil
  }

  func (s pgDeals) OfListing(ctx context.Context, listingID uuid.UUID) ([]domain.Deal, error) {
  	return s.many(ctx, selectDeal+`WHERE listing_id = @listing_id ORDER BY id`, pgx.StrictNamedArgs{"listing_id": listingID})
  }

  const (
  	dealsOfBuyer  = selectDeal + `WHERE buyer_id = @account AND id < @before ORDER BY id DESC LIMIT @limit`
  	dealsOfSeller = selectDeal + `WHERE seller_id = @account AND id < @before ORDER BY id DESC LIMIT @limit`
  )

  func (s pgDeals) ListByParty(ctx context.Context, account uuid.UUID, as domain.Party, p page.Request) ([]domain.Deal, error) {
  	q := dealsOfBuyer
  	if as == domain.Seller {
  		q = dealsOfSeller
  	}
  	return s.many(ctx, q, pgx.StrictNamedArgs{"account": account, "before": p.Before(), "limit": p.Fetch()})
  }

  // many reads every deal query q finds.
  func (s pgDeals) many(ctx context.Context, q string, a pgx.StrictNamedArgs) ([]domain.Deal, error) {
  	rows, err := s.db.Query(ctx, q, a)
  	if err != nil {
  		return nil, fmt.Errorf("select deals: %w", err)
  	}
  	defer rows.Close()
  	var out []domain.Deal
  	for rows.Next() {
  		d, err := scanDeal(rows)
  		if err != nil {
  			return nil, err
  		}
  		out = append(out, d)
  	}
  	if err := rows.Err(); err != nil {
  		return nil, fmt.Errorf("read deals: %w", err)
  	}
  	return out, nil
  }

  func (s pgDeals) Moves(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID][]domain.Move, error) {
  	rows, err := s.db.Query(ctx, `SELECT deal_id, id, kind, by_party, amount, moved_at FROM deal_moves
  WHERE deal_id = ANY(@ids) ORDER BY id`, pgx.StrictNamedArgs{"ids": ids})
  	if err != nil {
  		return nil, fmt.Errorf("select moves: %w", err)
  	}
  	defer rows.Close()
  	out := map[uuid.UUID][]domain.Move{}
  	for rows.Next() {
  		var (
  			deal   uuid.UUID
  			m      domain.Move
  			amount *int64
  		)
  		if err := rows.Scan(&deal, &m.ID, &m.Kind, &m.By, &amount, &m.At); err != nil {
  			return nil, fmt.Errorf("scan move: %w", err)
  		}
  		if amount != nil {
  			m.Amount = *amount
  		}
  		out[deal] = append(out[deal], m)
  	}
  	if err := rows.Err(); err != nil {
  		return nil, fmt.Errorf("read moves: %w", err)
  	}
  	return out, nil
  }
  ```

  Rename shadowed `err` variables where govet's shadow check asks.
- [ ] **Step 5: Run** `go test ./internal/deal/... ./internal/platform/events/`. Expected: PASS.
- [ ] **Step 6: Run** `make test`. Expected: green, sqlfluff clean, 0 lint issues.

### Task 4: deal service

**Files:**
- Create: `internal/deal/service/service.go`, `views.go`, `deal_open.go`, `deal_move.go`, `deal_get.go`, `listing_changed.go`
- Create: `internal/deal/service/helpers_test.go`, `deal_test.go`, `listing_changed_test.go`

**Interfaces:**
- Consumes: Task 1's `catalogsvc.Service.Summaries` and `catalogsvc.Summary`; Tasks 2 and 3.
- Produces (package `github.com/shopnexus/server2/internal/deal/service`):

  ```go
  type Service interface {
  	// Open returns the buyer's deal on a listing, starting one when there is
  	// none; created reports a new deal.
  	Open(ctx context.Context, buyer, listingID uuid.UUID) (v DealView, created bool, err error)
  	// Get reads a deal for one of its two sides.
  	Get(ctx context.Context, viewer, id uuid.UUID) (DealView, error)
  	// ListMine lists viewer's deals on side as, newest first.
  	ListMine(ctx context.Context, viewer uuid.UUID, as domain.Party, p page.Request) (page.Page[DealView], error)
  	Offer(ctx context.Context, caller, id uuid.UUID, amount int64) (DealView, error)
  	Accept(ctx context.Context, caller, id uuid.UUID, price int64) (DealView, error)
  	Decline(ctx context.Context, caller, id uuid.UUID) (DealView, error)
  	Withdraw(ctx context.Context, caller, id uuid.UUID) (DealView, error)
  	Cancel(ctx context.Context, caller, id uuid.UUID) (DealView, error)
  	// ListingChanged brings a listing's deals in line with its current
  	// state; the worker calls it for every change of the listing.
  	ListingChanged(ctx context.Context, listingID uuid.UUID) error
  }

  type Deps struct {
  	Deals    repository.Deals
  	Accounts accountsvc.Service
  	Auth     authsvc.Service
  	Catalog  catalogsvc.Service
  	Now      func() time.Time
  }

  func New(d Deps) *Deals
  ```

  `DealView`, `ListingRef`, `MoveView` as in Step 3.

- [ ] **Step 1: Test helpers** `helpers_test.go` (package `service_test`):

  ```go
  type env struct {
  	db       *pgxpool.Pool
  	accounts accountsvc.Service
  	catalog  *catalogsvc.Catalog
  	listings catalogrepo.Listings
  	repo     repository.Deals
  	deps     service.Deps
  	deals    *service.Deals
  }

  // newEnv builds the deal service on a database, with the account, auth and
  // catalog services it calls. deps lets a test build a second service with
  // one dependency replaced.
  func newEnv(t *testing.T) env {
  	t.Helper()
  	db := pgtest.New(t)
  	url, _, err := restatetest.URLs()
  	if err != nil {
  		t.Fatal(err)
  	}
  	in, p := ingress.NewClient(url), restatetest.Prefix()
  	accounts := accountsvc.New(accountrepo.NewAccounts(db), time.Now)
  	auth := authsvc.New(authsvc.Deps{Credentials: authrepo.NewCredentials(db)})
  	media := mediasvc.New(mediasvc.Deps{Uploads: mediarepo.NewUploads(db), Store: objectstoretest.New(t), Ingress: in, Prefix: p, Now: time.Now})
  	listings := catalogrepo.NewListings(db)
  	c := catalogsvc.New(catalogsvc.Deps{
  		Listings: listings, Categories: catalogrepo.NewCategories(db), Regions: catalogrepo.NewRegions(db),
  		Accounts: accounts, Auth: auth, Media: media, Ingress: in, Prefix: p, Now: time.Now,
  	})
  	repo := repository.NewDeals(db)
  	deps := service.Deps{Deals: repo, Accounts: accounts, Auth: auth, Catalog: c, Now: time.Now}
  	return env{db: db, accounts: accounts, catalog: c, listings: listings, repo: repo, deps: deps, deals: service.New(deps)}
  }
  ```

  plus `person(t)` (an account with a verified phone, the body of catalog's `seller` helper), `emailOnly(t)` (an account with no identity, catalog's `account`), `suspend(t, id)` (`e.accounts.Suspend(ctx, accountsvc.SuspendInput{ID: id, Reason: "spam", By: audit.ByCLI("test")})`), `kindsOf` (catalog's helper), and:

  ```go
  // listing puts a listing of seller's on sale at price, its one photo
  // processed, and returns its ID.
  func (e env) listing(t *testing.T, seller uuid.UUID, price int64, allowOffers bool) uuid.UUID {
  	t.Helper()
  	photo := uuid.NewV7()
  	now := time.Now()
  	l, err := catalogdomain.NewListing(uuid.NewV7(), seller, catalogdomain.Draft{
  		Title: "Xe đạp Asama", Price: price, CategoryCode: "vehicles.bicycle", Condition: catalogdomain.ConditionUsed,
  		AllowOffers: allowOffers, CommuneCode: "00004", Photos: []uuid.UUID{photo},
  	}, catalogdomain.Refs{CategoryIsLeaf: true, CommuneExists: true}, now)
  	if err != nil {
  		t.Fatal(err)
  	}
  	l.Published(map[uuid.UUID]catalogdomain.PhotoKeys{photo: {Photo: "media/a.jpg", Thumb: "media/a_thumb.jpg"}}, now)
  	if err = e.listings.Insert(context.Background(), l); err != nil {
  		t.Fatal(err)
  	}
  	return l.ID()
  }

  // edit changes a listing's draft and saves it, as an edit with the same
  // photos does: the listing stays on sale.
  func (e env) edit(t *testing.T, id uuid.UUID, change func(*catalogdomain.Draft)) {
  	t.Helper()
  	ctx := context.Background()
  	l, err := e.listings.Get(ctx, id)
  	if err != nil {
  		t.Fatal(err)
  	}
  	d := catalogdomain.Draft{
  		Title: l.Title(), Price: l.Price(), CategoryCode: l.CategoryCode(), Condition: l.Condition(),
  		AllowOffers: l.AllowOffers(), CommuneCode: l.CommuneCode(), Photos: l.Uploads(),
  	}
  	change(&d)
  	if err = l.Edit(d, catalogdomain.Refs{CategoryIsLeaf: true, CommuneExists: true}, time.Now()); err != nil {
  		t.Fatal(err)
  	}
  	if err = e.listings.Save(ctx, &l, uuid.NewV7()); err != nil {
  		t.Fatal(err)
  	}
  }

  // open opens buyer's deal on listing.
  func (e env) open(t *testing.T, buyer, listing uuid.UUID) service.DealView {
  	t.Helper()
  	v, _, err := e.deals.Open(context.Background(), buyer, listing)
  	if err != nil {
  		t.Fatal(err)
  	}
  	return v
  }

  // moveKinds lists a view's move kinds.
  func moveKinds(v service.DealView) []domain.MoveKind
  ```

  `staleGet` wraps `repository.Deals` so `Get` returns a deal read earlier:

  ```go
  type staleGet struct {
  	repository.Deals

  	stale domain.Deal
  }

  func (s staleGet) Get(context.Context, uuid.UUID) (domain.Deal, error) { return s.stale, nil }
  ```
- [ ] **Step 2: Failing tests.** `deal_test.go`:
  - `TestNegotiateToAgreement`: seller and buyer are `person`s; listing at 1,500,000 with offers. `Open` → created, role buyer, status negotiating, `OfferRange` `{750_000, 1_499_000}`, `Listing.CoverThumbURL` set; a second `Open` → not created, same ID. Buyer `Offer` 1,000,000. Seller `Get`: role seller, `OpenPrice` `{buyer, 1_000_000}`, `OfferRange` `{1_001_000, 1_499_000}`. Seller `Offer` 1,300,000. Buyer `Accept` 1,300,000 → agreed, `AgreedPrice` 1,300,000, no `OfferRange`, moves offer, counter, accept. `kindsOf(deal ID)` is three `deal.moved`. `ListMine(buyer, Buyer)` and `ListMine(seller, Seller)` hold the deal; `ListMine(buyer, Seller)` is empty. Seller `Cancel` → negotiating, `AgreedPrice` nil, last move cancel by seller.
  - `TestTwoBuyersDealApart`: two buyers open deals on one listing; buyer 1 accepts the listed price; buyer 2's deal is still negotiating, and buyer 2 can offer.
  - `TestOpenRefusals`, each with `errors.Is`: `emailOnly` → `domain.ErrPhoneRequired`; the seller on their own listing → `domain.ErrOwnListing`; a suspended `person` → `accountdomain.ErrSuspended`; a listing hidden through `e.catalog.Hide` → `domain.ErrListingUnavailable`; `uuid.NewV7()` → `catalogdomain.ErrNotFound`. A buyer who opened a deal before the listing was hidden gets it back (not created) after the hide.
  - `TestStrangerSeesNoDeal`: a third `person` gets `domain.ErrNotFound` from `Get`, `Offer`, `Accept`, `Decline`, `Withdraw` and `Cancel`; an unknown deal ID gives the same.
  - `TestAcceptAfterThePriceChanged`: buyer opens, `e.edit` sets the price to 1,400,000; `Accept(1_500_000)` → `domain.ErrPriceChanged`; `Accept(1_400_000)` → agreed.
  - `TestTakeBackOnAHiddenListing`: buyer offers; seller hides the listing; seller `Offer` and seller `Accept` → `domain.ErrListingUnavailable` (the listing check comes before the move rules); buyer `Withdraw` works. A second deal agreed before the hide: `Cancel` works on the hidden listing.
  - `TestSuspendedCallerTakesBackOnly`: buyer offers, then is suspended; `Offer` and `Accept` → `accountdomain.ErrSuspended`; `Withdraw` works.
  - `TestMoveThatLostARace`: buyer offers; `stale, _ := e.repo.Get(ctx, id)`; the seller counters through `e.deals`; `deps := e.deps; deps.Deals = staleGet{Deals: e.repo, stale: stale}`; buyer `Withdraw` through `service.New(deps)` → `domain.ErrChanged`; `e.deals.Get` still shows the seller's counter open.

  `listing_changed_test.go`:
  - `TestListingChanged`: buyer A offers 1,000,000; buyer B accepts the listed price. `e.edit` price 1,400,000; `ListingChanged` twice → A has no open price and exactly one `price_changed` move with amount 1,400,000; B still agreed. A offers 900,000 at the new price; `ListingChanged` again → A's offer stays. `e.catalog.MarkSold(seller, listing)`; `ListingChanged` → A has no open price (`listing_closed`), B negotiating with a last move `listing_closed` by system; `kindsOf` B shows a `deal.moved` for it.
  - `TestListingChangedOffersOff`: buyer offers; `e.edit` sets `AllowOffers` false; `ListingChanged` → `offers_closed`.
  - `TestListingChangedHidden`: buyer offers; hide; `ListingChanged` → `listing_closed`; unhide; `ListingChanged` → nothing new.
  - `TestListingChangedUnknownListing`: `ListingChanged(ctx, uuid.NewV7())` → nil.
- [ ] **Step 3: Run** `go test ./internal/deal/service/`. Expected: build failure, `service` undefined.
- [ ] **Step 4: Implement.** `service.go`: package doc ("Package service holds module deal's use cases: a buyer opens a deal on a listing, the two sides move until they agree a price, and the deals follow their listings' changes."), the interface, `Deps`, and

  ```go
  // Deals implements Service in this process.
  type Deals struct {
  	deals    repository.Deals
  	accounts accountsvc.Service
  	auth     authsvc.Service
  	catalog  catalogsvc.Service
  	now      func() time.Time
  }

  var _ Service = (*Deals)(nil)

  func New(d Deps) *Deals {
  	return &Deals{deals: d.Deals, accounts: d.Accounts, auth: d.Auth, catalog: d.Catalog, now: d.Now}
  }

  // refuseSuspended returns accountdomain.ErrSuspended for a suspended
  // account.
  func (s *Deals) refuseSuspended(ctx context.Context, id uuid.UUID) error {
  	st, err := s.accounts.Status(ctx, id)
  	if err != nil {
  		return fmt.Errorf("read account status: %w", err)
  	}
  	if st == accountdomain.StatusSuspended {
  		return accountdomain.ErrSuspended
  	}
  	return nil
  }

  // listing reads one listing through catalog, in any status; an unknown
  // one is catalogdomain.ErrNotFound.
  func (s *Deals) listing(ctx context.Context, id uuid.UUID) (catalogsvc.Summary, error) {
  	got, err := s.catalog.Summaries(ctx, []uuid.UUID{id})
  	if err != nil {
  		return catalogsvc.Summary{}, fmt.Errorf("read listing: %w", err)
  	}
  	l, ok := got[id]
  	if !ok {
  		return catalogsvc.Summary{}, catalogdomain.ErrNotFound
  	}
  	return l, nil
  }

  // own loads a deal and the caller's side of it. Anyone else gets
  // domain.ErrNotFound, so a deal's existence does not leak.
  func (s *Deals) own(ctx context.Context, caller, id uuid.UUID) (domain.Deal, domain.Party, error) {
  	d, err := s.deals.Get(ctx, id)
  	if errors.Is(err, repository.ErrNotFound) {
  		return domain.Deal{}, "", domain.ErrNotFound
  	}
  	if err != nil {
  		return domain.Deal{}, "", fmt.Errorf("get deal: %w", err)
  	}
  	by, ok := d.PartyOf(caller)
  	if !ok {
  		return domain.Deal{}, "", domain.ErrNotFound
  	}
  	return d, by, nil
  }

  // moved is the event of a deal's new moves.
  func moved(id uuid.UUID, now time.Time) events.Event {
  	return events.Event{ID: uuid.NewV7(), Kind: events.DealMoved, SubjectID: id, OccurredAt: now}
  }
  ```

  `views.go`:

  ```go
  // DealView is the Deal schema in api/schemas/deal.yaml.
  type DealView struct {
  	ID          uuid.UUID         `json:"id"`
  	BuyerID     uuid.UUID         `json:"buyer_id"`
  	SellerID    uuid.UUID         `json:"seller_id"`
  	Listing     ListingRef        `json:"listing"`
  	Role        domain.Party      `json:"role"`
  	Status      domain.Status     `json:"status"`
  	OpenPrice   *domain.OpenPrice `json:"open_price,omitempty"`
  	AgreedPrice *int64            `json:"agreed_price,omitempty"`
  	AgreedAt    *time.Time        `json:"agreed_at,omitempty"`
  	OfferRange  *domain.Range     `json:"offer_range,omitempty"`
  	Moves       []MoveView        `json:"moves"`
  }

  // ListingRef is the deal's listing as it is now.
  type ListingRef struct {
  	ID            uuid.UUID            `json:"id"`
  	Title         string               `json:"title"`
  	Price         int64                `json:"price"`
  	CoverThumbURL string               `json:"cover_thumb_url,omitempty"`
  	Status        catalogdomain.Status `json:"status"`
  }

  // MoveView is one move of the thread; Amount is absent on a move without
  // one.
  type MoveView struct {
  	Kind   domain.MoveKind `json:"kind"`
  	By     domain.Party    `json:"by"`
  	Amount *int64          `json:"amount,omitempty"`
  	At     time.Time       `json:"at"`
  }

  // facts is what the deal's rules read of its listing.
  func facts(l catalogsvc.Summary) domain.Listing {
  	var st domain.ListingStatus
  	switch l.Status {
  	case catalogdomain.StatusActive:
  		st = domain.ListingActive
  	case catalogdomain.StatusProcessing, catalogdomain.StatusRejected:
  		st = domain.ListingPaused
  	case catalogdomain.StatusHidden:
  		st = domain.ListingHidden
  	case catalogdomain.StatusSold, catalogdomain.StatusDeleted:
  		st = domain.ListingGone
  	}
  	return domain.Listing{Price: l.Price, AllowOffers: l.AllowOffers, Status: st}
  }

  // view builds the DealView of d for viewer, one of its sides, from its
  // listing and moves.
  func view(viewer uuid.UUID, d domain.Deal, l catalogsvc.Summary, moves []domain.Move) DealView {
  	by, _ := d.PartyOf(viewer)
  	v := DealView{
  		ID: d.ID(), BuyerID: d.BuyerID(), SellerID: d.SellerID(),
  		Listing: ListingRef{ID: l.ID, Title: l.Title, Price: l.Price, CoverThumbURL: l.CoverThumbURL, Status: l.Status},
  		Role:    by, Status: d.Status(), OpenPrice: d.Open(), AgreedAt: d.AgreedAt(),
  		Moves:   make([]MoveView, 0, len(moves)),
  	}
  	if d.Status() == domain.StatusAgreed {
  		v.AgreedPrice = new(d.AgreedPrice())
  	}
  	if r, ok := d.OfferRange(by, facts(l)); ok {
  		v.OfferRange = &r
  	}
  	for _, m := range moves {
  		mv := MoveView{Kind: m.Kind, By: m.By, At: m.At}
  		if m.Amount != 0 {
  			mv.Amount = new(m.Amount)
  		}
  		v.Moves = append(v.Moves, mv)
  	}
  	return v
  }

  // read builds d's view for viewer, reading its moves.
  func (s *Deals) read(ctx context.Context, viewer uuid.UUID, d domain.Deal, l catalogsvc.Summary) (DealView, error) {
  	moves, err := s.deals.Moves(ctx, []uuid.UUID{d.ID()})
  	if err != nil {
  		return DealView{}, fmt.Errorf("read moves: %w", err)
  	}
  	return view(viewer, d, l, moves[d.ID()]), nil
  }
  ```

  `deal_open.go`:

  ```go
  // Open returns the buyer's deal on the listing or starts one. Starting
  // needs an account that is not suspended and has a verified phone, on
  // someone else's active listing. Two opens at once start one deal.
  func (s *Deals) Open(ctx context.Context, buyer, listingID uuid.UUID) (DealView, bool, error) {
  	l, err := s.listing(ctx, listingID)
  	if err != nil {
  		return DealView{}, false, err
  	}
  	d, err := s.deals.Find(ctx, listingID, buyer)
  	if err == nil {
  		v, readErr := s.read(ctx, buyer, d, l)
  		return v, false, readErr
  	}
  	if !errors.Is(err, repository.ErrNotFound) {
  		return DealView{}, false, fmt.Errorf("find deal: %w", err)
  	}
  	if err = s.refuseSuspended(ctx, buyer); err != nil {
  		return DealView{}, false, err
  	}
  	ids, err := s.auth.Identities(ctx, buyer)
  	if err != nil {
  		return DealView{}, false, fmt.Errorf("read identities: %w", err)
  	}
  	if !slices.ContainsFunc(ids, func(i authsvc.Identity) bool { return i.Kind == authdomain.KindPhone }) {
  		return DealView{}, false, domain.ErrPhoneRequired
  	}
  	if l.SellerID == buyer {
  		return DealView{}, false, domain.ErrOwnListing
  	}
  	if l.Status != catalogdomain.StatusActive {
  		return DealView{}, false, domain.ErrListingUnavailable
  	}
  	d = domain.Open(uuid.NewV7(), listingID, buyer, l.SellerID, s.now())
  	created, err := s.deals.Insert(ctx, d)
  	if err != nil {
  		return DealView{}, false, fmt.Errorf("insert deal: %w", err)
  	}
  	if !created {
  		if d, err = s.deals.Find(ctx, listingID, buyer); err != nil {
  			return DealView{}, false, fmt.Errorf("find deal: %w", err)
  		}
  	}
  	v, err := s.read(ctx, buyer, d, l)
  	return v, created, err
  }
  ```

  `deal_move.go`:

  ```go
  func (s *Deals) Offer(ctx context.Context, caller, id uuid.UUID, amount int64) (DealView, error) {
  	return s.move(ctx, caller, id, true, func(d *domain.Deal, by domain.Party, l domain.Listing, now time.Time) error {
  		return d.Offer(by, amount, l, now)
  	})
  }

  func (s *Deals) Accept(ctx context.Context, caller, id uuid.UUID, price int64) (DealView, error) {
  	return s.move(ctx, caller, id, true, func(d *domain.Deal, by domain.Party, l domain.Listing, now time.Time) error {
  		return d.Accept(by, price, l, now)
  	})
  }

  func (s *Deals) Decline(ctx context.Context, caller, id uuid.UUID) (DealView, error) {
  	return s.move(ctx, caller, id, false, func(d *domain.Deal, by domain.Party, _ domain.Listing, now time.Time) error {
  		return d.Decline(by, now)
  	})
  }

  // Withdraw and Cancel follow Decline with d.Withdraw and d.Cancel.

  // move loads the caller's deal and its listing, applies change as the
  // caller's side and saves the deal with deal.moved. commits refuses a
  // suspended caller: an offer or an accept binds them, while a decline, a
  // withdrawal or a cancel takes a price back.
  func (s *Deals) move(ctx context.Context, caller, id uuid.UUID, commits bool,
  	change func(d *domain.Deal, by domain.Party, l domain.Listing, now time.Time) error,
  ) (DealView, error) {
  	d, by, err := s.own(ctx, caller, id)
  	if err != nil {
  		return DealView{}, err
  	}
  	if commits {
  		if err = s.refuseSuspended(ctx, caller); err != nil {
  			return DealView{}, err
  		}
  	}
  	l, err := s.listing(ctx, d.ListingID())
  	if err != nil {
  		return DealView{}, err
  	}
  	now := s.now()
  	if err = change(&d, by, facts(l), now); err != nil {
  		return DealView{}, err
  	}
  	err = s.deals.Save(ctx, &d, uuid.NewV7(), moved(d.ID(), now))
  	if errors.Is(err, repository.ErrConflict) {
  		return DealView{}, domain.ErrChanged
  	}
  	if err != nil {
  		return DealView{}, fmt.Errorf("save deal: %w", err)
  	}
  	return s.read(ctx, caller, d, l)
  }
  ```

  `deal_get.go`:

  ```go
  func (s *Deals) Get(ctx context.Context, viewer, id uuid.UUID) (DealView, error) {
  	d, _, err := s.own(ctx, viewer, id)
  	if err != nil {
  		return DealView{}, err
  	}
  	l, err := s.listing(ctx, d.ListingID())
  	if err != nil {
  		return DealView{}, err
  	}
  	return s.read(ctx, viewer, d, l)
  }

  // ListMine reads one page of the viewer's deals with their listings and
  // moves in three queries.
  func (s *Deals) ListMine(ctx context.Context, viewer uuid.UUID, as domain.Party, p page.Request) (page.Page[DealView], error) {
  	rows, err := s.deals.ListByParty(ctx, viewer, as, p)
  	if err != nil {
  		return page.Page[DealView]{}, fmt.Errorf("list deals: %w", err)
  	}
  	listingIDs, dealIDs := make([]uuid.UUID, 0, len(rows)), make([]uuid.UUID, 0, len(rows))
  	for i := range rows {
  		listingIDs, dealIDs = append(listingIDs, rows[i].ListingID()), append(dealIDs, rows[i].ID())
  	}
  	listings, err := s.catalog.Summaries(ctx, listingIDs)
  	if err != nil {
  		return page.Page[DealView]{}, fmt.Errorf("read listings: %w", err)
  	}
  	moves, err := s.deals.Moves(ctx, dealIDs)
  	if err != nil {
  		return page.Page[DealView]{}, fmt.Errorf("read moves: %w", err)
  	}
  	items := make([]DealView, 0, len(rows))
  	for i := range rows {
  		items = append(items, view(viewer, rows[i], listings[rows[i].ListingID()], moves[rows[i].ID()]))
  	}
  	return page.Of(items, p, func(v DealView) uuid.UUID { return v.ID }), nil
  }
  ```

  `listing_changed.go`:

  ```go
  // ListingChanged brings every deal on the listing in line with the
  // listing's current state. It reads current state, so a repeated or late
  // call changes nothing more. A deal a user moved meanwhile fails the call,
  // and the worker's retry reads it again.
  func (s *Deals) ListingChanged(ctx context.Context, listingID uuid.UUID) error {
  	l, err := s.listing(ctx, listingID)
  	if errors.Is(err, catalogdomain.ErrNotFound) {
  		return nil
  	}
  	if err != nil {
  		return err
  	}
  	deals, err := s.deals.OfListing(ctx, listingID)
  	if err != nil {
  		return fmt.Errorf("list deals: %w", err)
  	}
  	now := s.now()
  	for i := range deals {
  		if !deals[i].ListingChanged(facts(l), now) {
  			continue
  		}
  		if err = s.deals.Save(ctx, &deals[i], uuid.NewV7(), moved(deals[i].ID(), now)); err != nil {
  			return fmt.Errorf("save deal: %w", err)
  		}
  	}
  	return nil
  }
  ```
- [ ] **Step 5: Run** `go test ./internal/deal/...`. Expected: PASS.
- [ ] **Step 6: Run** `make test`. Expected: green. depguard has no deal rules yet; Task 6 adds them.

### Task 5: worker

**Files:**
- Create: `internal/deal/worker/listing.go`, `internal/deal/worker/listing_test.go`

**Interfaces:**
- Consumes: `service.Service.ListingChanged`.
- Produces: `worker.ListingWatch{Prefix string; Deals service.Service}` with `ServiceName() string` (`Prefix + "DealListingWatch"`) and the Restate handler `Changed(ctx restate.Context, e events.Event) error`.

- [ ] **Step 1: Failing test** `listing_test.go` (package `worker_test`):

  ```go
  // recorder is a deal service that records the listings ListingChanged
  // was called with.
  type recorder struct {
  	service.Service

  	mu   *sync.Mutex
  	seen *[]uuid.UUID
  }

  func (r recorder) ListingChanged(_ context.Context, id uuid.UUID) error {
  	r.mu.Lock()
  	defer r.mu.Unlock()
  	*r.seen = append(*r.seen, id)
  	return nil
  }

  func TestChangedCallsListingChanged(t *testing.T) {
  	t.Parallel()
  	var seen []uuid.UUID
  	mu := &sync.Mutex{}
  	w := worker.ListingWatch{Prefix: restatetest.Prefix(), Deals: recorder{mu: mu, seen: &seen}}
  	client := restatetest.Start(t, restate.Reflect(w))
  	e := events.Event{ID: uuid.NewV7(), Kind: events.ListingUpdated, SubjectID: uuid.NewV7(), OccurredAt: time.Now()}
  	changed := ingress.Service[events.Event, restate.Void](client, w.ServiceName(), "Changed")
  	for range 2 {
  		if _, err := changed.Request(context.Background(), e); err != nil {
  			t.Fatal(err)
  		}
  	}
  	mu.Lock()
  	defer mu.Unlock()
  	if len(seen) != 2 || seen[0] != e.SubjectID || seen[1] != e.SubjectID {
  		t.Fatalf("%v", seen)
  	}
  }
  ```
- [ ] **Step 2: Run** `go test ./internal/deal/worker/`. Expected: build failure.
- [ ] **Step 3: Implement** `listing.go`:

  ```go
  // Package worker holds module deal's Restate handlers for the events it
  // reacts to.
  package worker

  // ListingWatch keeps deals in line with their listings: Mount subscribes
  // Changed to listing.updated, listing.hidden, listing.sold and
  // listing.deleted.
  type ListingWatch struct {
  	Prefix string
  	Deals  service.Service
  }

  func (w ListingWatch) ServiceName() string { return w.Prefix + "DealListingWatch" }

  // Changed reads the listing of e and brings its deals in line with it.
  func (w ListingWatch) Changed(ctx restate.Context, e events.Event) error {
  	if err := restate.RunVoid(ctx, func(rc restate.RunContext) error {
  		return w.Deals.ListingChanged(rc, e.SubjectID)
  	}); err != nil {
  		return fmt.Errorf("listing %s changed: %w", e.SubjectID, err)
  	}
  	return nil
  }
  ```
- [ ] **Step 4: Run** `go test ./internal/deal/worker/`. Expected: PASS.
- [ ] **Step 5: Run** `make test`. Expected: green.

### Task 6: API, handler, Mount and depguard

**Files:**
- Create: `api/paths/deal.yaml`, `api/schemas/deal.yaml`
- Modify: `api/openapi.yaml`
- Create: `internal/deal/handler/handler.go`, `internal/deal/handler/deal.go`, `internal/deal/deal.go`
- Modify: `internal/app/app.go`, `tmp/gen_depguard.py` (scratch), `.golangci.yml`

**Interfaces:**
- Consumes: `service.Service`, `worker.ListingWatch`, Task 1's `catalog.Mounted`.
- Produces: `deal.Mount(d module.Deps, protect func(http.Handler) http.Handler, accounts accountsvc.Service, auth authsvc.Service, catalog catalogsvc.Service) []restate.ServiceDefinition`; operation IDs `openDeal`, `getDeal`, `listMyDeals`, `offerDeal`, `acceptDeal`, `declineDeal`, `withdrawDeal`, `cancelDeal`.

- [ ] **Step 1: Schemas** `api/schemas/deal.yaml`, in the style of `catalog.yaml` (`additionalProperties: false`, `required` lists):
  - `DealOpen {listing_id: uuid}` required.
  - `Offer {amount: integer int64}` required, description: whole đồng in multiples of 1,000, inside the deal's `offer_range`; a business rule, so a breach is 422.
  - `Accept {price: integer int64}` required, description: the price the person saw; the other side's open price or, for the buyer, the listed price.
  - `Party` enum `[buyer, seller]`; `DealStatus` enum `[negotiating, agreed]`.
  - `DealListing {id, title, price, cover_thumb_url (uri, optional), status}` with `status` enum `[processing, active, hidden, rejected, sold, deleted]`.
  - `OpenPrice {by: Party, amount, at: date-time}` all required.
  - `OfferRange {min, max}` required, description: the amounts the viewer's next offer may take, both included; absent when the viewer may not offer.
  - `Move {kind, by, amount (optional), at}` with `kind` enum `[offer, counter, accept, decline, withdraw, cancel, price_changed, offers_closed, listing_closed]` and `by` enum `[buyer, seller, system]`; description of `amount`: the offered or agreed price, or the new listed price on `price_changed`.
  - `Deal` required `[id, buyer_id, seller_id, listing, role, status, moves]`, optional `open_price`, `agreed_price`, `agreed_at`, `offer_range`; `role` is `Party` (the viewer's side).
  - `DealList {items: [Deal], next_cursor: uuid}` like `ListingList`.
- [ ] **Step 2: Paths** `api/paths/deal.yaml` (tags `[deal]`, `security: bearerAuth`, path parameter `id` uuid, error bodies `../schemas/error.yaml#/Error`, `400` and `401` from `../responses/common.yaml`). Declared statuses, each described with its codes:

  | Key | Operation | Statuses |
  |---|---|---|
  | `deals` | `post` `openDeal`, body `DealOpen` | 200 (the existing deal), 201 (a new deal), 400, 401, 403 (`account_suspended`, `phone_required`), 404 (`listing_not_found`), 409 (`own_listing`, `listing_unavailable`) |
  | `deal` | `get` `getDeal` | 200, 400, 401, 404 (`deal_not_found`) |
  | `dealOffer` | `post` `offerDeal`, body `Offer` | 200, 400, 401, 403 (`account_suspended`), 404, 409 (`move_not_allowed`, `listing_unavailable`, `deal_changed`), 422 (`invalid_amount`, field `amount`: `step` or `out_of_range`) |
  | `dealAccept` | `post` `acceptDeal`, body `Accept` | 200, 400, 401, 403, 404, 409 (`move_not_allowed`, `listing_unavailable`, `price_changed`, `deal_changed`) |
  | `dealDecline`, `dealWithdraw`, `dealCancel` | `post` `declineDeal`, `withdrawDeal`, `cancelDeal`, no body | 200, 400, 401, 404, 409 (`move_not_allowed`, `deal_changed`) |
  | `myDeals` | `get` `listMyDeals`, query `role` required enum `[buying, selling]`, `Cursor`, `Limit` | 200 (`DealList`), 400, 401 |

  Add to `api/openapi.yaml` after the catalog paths:

  ```yaml
    /v1/deals:
      $ref: "paths/deal.yaml#/deals"
    /v1/deals/{id}:
      $ref: "paths/deal.yaml#/deal"
    /v1/deals/{id}/offer:
      $ref: "paths/deal.yaml#/dealOffer"
    /v1/deals/{id}/accept:
      $ref: "paths/deal.yaml#/dealAccept"
    /v1/deals/{id}/decline:
      $ref: "paths/deal.yaml#/dealDecline"
    /v1/deals/{id}/withdraw:
      $ref: "paths/deal.yaml#/dealWithdraw"
    /v1/deals/{id}/cancel:
      $ref: "paths/deal.yaml#/dealCancel"
    /v1/me/deals:
      $ref: "paths/deal.yaml#/myDeals"
  ```
- [ ] **Step 3: Run** `go test ./api/ ./internal/app/`. Expected: `TestSpecValid` passes; `TestRoutesMatchSpec` FAILS with "operation POST /v1/deals has no route" and the seven others.
- [ ] **Step 4: Handler.** `handler.go`:

  ```go
  // Package handler serves module deal's HTTP API.
  package handler

  type Handler struct {
  	svc service.Service
  	log *slog.Logger
  }

  func New(svc service.Service, log *slog.Logger) *Handler { return &Handler{svc: svc, log: log} }

  // Register adds the deal endpoints, all behind protect.
  func (h *Handler) Register(r *httpx.Router, protect func(http.Handler) http.Handler) {
  	r.Handle("POST /v1/deals", protect(http.HandlerFunc(h.Open)))
  	r.Handle("GET /v1/deals/{id}", protect(http.HandlerFunc(h.Get)))
  	r.Handle("POST /v1/deals/{id}/offer", protect(http.HandlerFunc(h.Offer)))
  	r.Handle("POST /v1/deals/{id}/accept", protect(http.HandlerFunc(h.Accept)))
  	r.Handle("POST /v1/deals/{id}/decline", protect(http.HandlerFunc(h.Decline)))
  	r.Handle("POST /v1/deals/{id}/withdraw", protect(http.HandlerFunc(h.Withdraw)))
  	r.Handle("POST /v1/deals/{id}/cancel", protect(http.HandlerFunc(h.Cancel)))
  	r.Handle("GET /v1/me/deals", protect(http.HandlerFunc(h.ListMine)))
  }
  ```

  `deal.go`:

  ```go
  type openRequest struct {
  	ListingID uuid.UUID `json:"listing_id"`
  }

  type dealRequest struct {
  	ID uuid.UUID `json:"-" path:"id"`
  }

  type offerRequest struct {
  	ID     uuid.UUID `json:"-"      path:"id"`
  	Amount int64     `json:"amount"`
  }

  type acceptRequest struct {
  	ID    uuid.UUID `json:"-"     path:"id"`
  	Price int64     `json:"price"`
  }

  type listMineRequest struct {
  	page.Request

  	Role string `json:"-" query:"role"`
  }

  // Open serves POST /v1/deals: 201 with a new deal, 200 with the caller's
  // existing one.
  func (h *Handler) Open(w http.ResponseWriter, r *http.Request) {
  	p, ok := httpx.Caller(w, r, h.log)
  	if !ok {
  		return
  	}
  	var in openRequest
  	if err := httpx.Bind(r, &in); err != nil {
  		httpx.WriteError(w, r, h.log, err)
  		return
  	}
  	v, created, err := h.svc.Open(r.Context(), p.AccountID, in.ListingID)
  	if err != nil {
  		httpx.WriteError(w, r, h.log, err)
  		return
  	}
  	status := http.StatusOK
  	if created {
  		status = http.StatusCreated
  	}
  	httpx.Respond(w, status, v)
  }

  // ListMine serves GET /v1/me/deals.
  func (h *Handler) ListMine(w http.ResponseWriter, r *http.Request) {
  	p, ok := httpx.Caller(w, r, h.log)
  	if !ok {
  		return
  	}
  	var in listMineRequest
  	if err := httpx.Bind(r, &in); err != nil {
  		httpx.WriteError(w, r, h.log, err)
  		return
  	}
  	as := domain.Buyer
  	if in.Role == "selling" {
  		as = domain.Seller
  	}
  	out, err := h.svc.ListMine(r.Context(), p.AccountID, as, in.Request)
  	if err != nil {
  		httpx.WriteError(w, r, h.log, err)
  		return
  	}
  	httpx.Respond(w, http.StatusOK, out)
  }

  // Get serves GET /v1/deals/{id}.
  func (h *Handler) Get(w http.ResponseWriter, r *http.Request) {
  	serve(h, w, r, func(ctx context.Context, caller uuid.UUID, in dealRequest) (service.DealView, error) {
  		return h.svc.Get(ctx, caller, in.ID)
  	})
  }

  // Offer serves POST /v1/deals/{id}/offer.
  func (h *Handler) Offer(w http.ResponseWriter, r *http.Request) {
  	serve(h, w, r, func(ctx context.Context, caller uuid.UUID, in offerRequest) (service.DealView, error) {
  		return h.svc.Offer(ctx, caller, in.ID, in.Amount)
  	})
  }

  // Accept, Decline, Withdraw and Cancel follow Offer with acceptRequest
  // (in.Price) and dealRequest.

  // serve binds the request of a call on one deal, applies it as the caller
  // and answers 200 with the deal.
  func serve[T any](h *Handler, w http.ResponseWriter, r *http.Request,
  	apply func(ctx context.Context, caller uuid.UUID, in T) (service.DealView, error),
  ) {
  	p, ok := httpx.Caller(w, r, h.log)
  	if !ok {
  		return
  	}
  	var in T
  	if err := httpx.Bind(r, &in); err != nil {
  		httpx.WriteError(w, r, h.log, err)
  		return
  	}
  	v, err := apply(r.Context(), p.AccountID, in)
  	if err != nil {
  		httpx.WriteError(w, r, h.log, err)
  		return
  	}
  	httpx.Respond(w, http.StatusOK, v)
  }
  ```

  `internal/deal/deal.go`:

  ```go
  // Package deal is a buyer and a seller agreeing a price on a listing.
  package deal

  // Mount registers the deal endpoints behind protect, subscribes the
  // listing watch to the listing events and returns deal's Restate services.
  func Mount(d module.Deps, protect func(http.Handler) http.Handler, accounts accountsvc.Service,
  	auth authsvc.Service, catalog catalogsvc.Service,
  ) []restate.ServiceDefinition {
  	svc := service.New(service.Deps{
  		Deals: repository.NewDeals(d.Pool), Accounts: accounts, Auth: auth, Catalog: catalog, Now: d.Now,
  	})
  	handler.New(svc, d.Log).Register(d.Router, protect)
  	watch := worker.ListingWatch{Prefix: d.ServicePrefix, Deals: svc}
  	for _, k := range []events.Kind{events.ListingUpdated, events.ListingHidden, events.ListingSold, events.ListingDeleted} {
  		d.Events.Subscribe(k, watch.ServiceName(), "Changed")
  	}
  	return []restate.ServiceDefinition{restate.Reflect(watch)}
  }
  ```

  In `app.go`, after catalog: `dealServices := deal.Mount(d, protect, accounts, authm.Service, catalogm.Service)`, and add `dealServices` to the `slices.Concat`.
- [ ] **Step 5: depguard.** In `tmp/gen_depguard.py` set `mods = ["account", "auth", "staff", "media", "catalog", "deal"]` and run `python3 tmp/gen_depguard.py`. Check that `.golangci.yml` gains `module deal` and that every layer rule lists `deal/...`.
- [ ] **Step 6: Run** `go test ./api/ ./internal/app/ ./internal/deal/...`. Expected: PASS, `TestRoutesMatchSpec` included.
- [ ] **Step 7: Run** `make test`. Expected: the e2e status-coverage check FAILS for the eight deal operations (no e2e yet); everything else green, 0 lint issues. Task 7 makes it green.

### Task 7: e2e

**Files:**
- Create: `e2e/deal_test.go`

**Interfaces:**
- Consumes: the HTTP API of Task 6; e2e helpers `newAccount`, `emailAccount`, `suspend`, `activeListing`, `draftWith`, `call`, `bearer`, `newKey`, `decode`, `errorOf`.

- [ ] **Step 1: Types and helpers:**

  ```go
  type dealBody struct {
  	ID          string `json:"id"`
  	Role        string `json:"role"`
  	Status      string `json:"status"`
  	AgreedPrice int64  `json:"agreed_price"`
  	OpenPrice   *struct {
  		By     string `json:"by"`
  		Amount int64  `json:"amount"`
  	} `json:"open_price"`
  	OfferRange *struct {
  		Min int64 `json:"min"`
  		Max int64 `json:"max"`
  	} `json:"offer_range"`
  	Moves []struct {
  		Kind   string `json:"kind"`
  		By     string `json:"by"`
  		Amount int64  `json:"amount"`
  	} `json:"moves"`
  }

  // openDeal opens token's deal on listing and checks the status.
  func openDeal(t *testing.T, token, listing string, status int) dealBody

  // dealCall posts to /v1/deals/{id}/{action} as token.
  func dealCall(t *testing.T, token, id, action string, body any) Response
  ```
- [ ] **Step 2: Tests.**
  - `TestDealToAgreement`: seller and buyer through `newAccount`; `activeListing(seller)` (1,500,000, offers on). Open → 201 with `offer_range {750000, 1499000}`; open again → 200, same ID. Buyer offer 1,000,000 → 200. Seller `GET /v1/deals/{id}` → role seller, open price by buyer. Seller offer 1,300,000 → 200. Buyer accept `{price: 1300000}` → agreed at 1,300,000. `GET /v1/me/deals?role=buying` (buyer) and `?role=selling` (seller) hold the deal; `?role=bogus` → 400. Seller cancel → 200, negotiating. Buyer offer 1,000,000, seller decline → 200; buyer offer 1,000,000, buyer withdraw → 200.
  - `TestDealFollowsTheListing`: buyer opens and offers 1,000,000. The seller `PUT /v1/listings/{id}` with `draftWith(l.Photos[0].UploadID)` whose `price` is set to 1,400,000, and `newKey()`. Poll the buyer's `GET /v1/deals/{id}` for up to 10 seconds until `open_price` is gone and the last move is `price_changed` with amount 1,400,000 by system.
  - `TestDealRefusals`, with the `expect(name, res, status, code)` helper of `TestPostListingRefusals`:
    - open: no token → 401 `unauthenticated`; `{"listing_id": "x"}` → 400; an unknown listing → 404 `listing_not_found`; a suspended account → 403 `account_suspended`; `emailAccount` → 403 `phone_required`; the seller on their own listing → 409 `own_listing`; a listing hidden through `POST /v1/listings/{id}/hide` → 409 `listing_unavailable`.
    - get: no token → 401; `/v1/deals/not-a-uuid` → 400; a stranger → 404 `deal_not_found`.
    - offer: amount 500,000 → 422 `invalid_amount`; the seller with nothing open → 409 `move_not_allowed`; a stranger → 404; no token → 401; `{"amount": "x"}` → 400; a second buyer, suspended after opening their deal, → 403 `account_suspended`.
    - accept: buyer `{price: 1400000}` → 409 `price_changed`; stranger → 404; no token → 401; bad id → 400; the suspended buyer → 403.
    - decline, withdraw, cancel, each: with nothing to take back → 409 `move_not_allowed`; stranger → 404; no token → 401; bad id → 400.
    - me/deals: no token → 401.
- [ ] **Step 3: Run** `make test`. Expected: green, the status-coverage check included.

### Task 8: ARCHITECTURE.md and the decisions

**Files:**
- Modify: `ARCHITECTURE.md`

- [ ] **Step 1:** Add a `### Deal` section after `### Catalog`, from the spec, as facts: one deal per buyer and listing; the two statuses and the single open price; the moves and who makes them; the amount rules with `offer_range` as the only source for the app; `accept` carries the price seen (`price_changed`); `offer` and `accept` need an active listing and refuse a suspended caller, the take-backs do not; `deal_changed` for a lost race instead of `try_again`, and why; `deal_moves` and `deal.moved` in the save's transaction; `ListingWatch`, server2's first worker, subscribed to `listing.updated`, `listing.hidden`, `listing.sold` and `listing.deleted`, reading current state through `catalogsvc.Service.Summaries`; a processing or rejected listing is not closed; offers have no expiry and an agreement reserves nothing (decided 2026-10-26); chat will be one conversation per buyer and seller, holding their deals (decided 2026-10-26). In `### Module layout`, add `deal` to the modules with the layout and name it as the first with a `worker`. In `### Events`, the `Data` map is named `Payload` in code; correct the text while there.
- [ ] **Step 2:** Run `python3 ~/.claude/skills/humanizing-writing/ai-tells.py --stats ARCHITECTURE.md` and fix every hit in the new text.
- [ ] **Step 3: Run** `make test`. Expected: green.
