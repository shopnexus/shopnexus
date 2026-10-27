# Search and the Nearby Feed Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Text search through an LLM that turns the query into weighted boosts, filters and sorts the person picks, category browsing, and the "Gần bạn" feed, on ParadeDB.

**Architecture:** Catalog owns `listings` and its ParadeDB index, so catalog serves a structured search (filters, phrases, constant-score boosts, a sort) and the blurred listing point. Discovery owns understanding: it calls the model, caches the answer, compiles it into catalog's search, and adds `saved` flags. Screen adds the Home view.

**Tech Stack:** Go 1.27, pgx v5 (StrictNamedArgs), ParadeDB `pg_search` 0.26.3 on Postgres 18, an OpenAI-compatible chat completions endpoint with JSON schema output, Restate Go SDK (unchanged flows).

**Spec:** `~/shopnexus/specs/2026-10-27-server2-search-design.md`

## Global Constraints

- Image `paradedb/paradedb:0.26.3-pg18` in `docker-compose.yml` and `docker-compose.test.yml`.
- Configuration has no defaults: `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL` are required and non-empty.
- The exact GPS point never reaches the Restate journal, the database, a log or an error. The handler blurs it before calling the service.
- No response carries `listings.lat` or `listings.lng`. `distance_km` is a whole number, 0 meaning under 1 km.
- Search and the feed show `active` listings only.
- The model never writes a weight; weights are constants in `discovery/domain`.
- The raw query is always a phrase at weight 0.5 unless the model named it as a boost.
- Model timeout: 4 seconds, a constant. Cache: 7 days, keyed by normalized query and prompt version.
- Results stop at 500 (offset + limit ≤ 500).
- A use case, a Restate handler or an HTTP handler reads top to bottom; no helper called from only one place; no update callbacks.
- Every SQL statement uses `pgx.StrictNamedArgs`; no caller value reaches SQL text, only generated parameter names.
- Scratch files in `tmp/`. Prose in files goes through `python3 ~/.claude/skills/humanizing-writing/ai-tells.py`.
- `make test` is the only command that recreates Restate; run it alone.

## Review Focus

1. A query of only punctuation or one-letter words ("?", "a b"): the phrase matches nothing; expect 200 with no items, never 500. Test in Task 7.
2. The model answers malformed JSON, an unknown attr, a category that does not exist, or ten values: everything unresolvable is dropped and the raw phrase still searches. Test in Task 6 and Task 7.
3. `near_lat`/`near_lng` outside -90..90 / -180..180, or only one of the two: 400 `invalid_position`. Test in Task 7.
4. A tampered or too-deep `cursor` (not a number, negative, past 500): 400 `invalid_cursor`. Test in Task 7.
5. Two identical first-time queries at once: both answer, the cache keeps one row (`ON CONFLICT DO UPDATE`). Test in Task 7.

---

## File Structure

```
docker-compose.yml, docker-compose.test.yml   image → paradedb/paradedb:0.26.3-pg18
migrations/0019_search.sql                    pg_search, listings columns and index, search_understandings
internal/platform/httpx/bind.go               float64 and repeated []string query params
internal/platform/config/config.go            LLMConfig
internal/provider/llm/llm.go                  Client, OpenAI (chat completions + JSON schema)
internal/catalog/domain/geo.go                Point, Distance, Blur, MaxGPSKm
internal/catalog/domain/listing.go            Draft.Spot, Refs.CommunePoint, Listing point
internal/catalog/domain/search.go             Search, Filters, Phrase, Boost, SortOrder, Hit, CategoryCount
internal/catalog/repository/search_pg.go      Searches: Search, Counts (ParadeDB SQL)
internal/catalog/repository/region_pg.go      FindPlace
internal/catalog/service/search.go            Search → []SearchCard, Counts, CommunePoint, Place
internal/catalog/handler/draft.go             gps body, blur
internal/discovery/domain/understanding.go    Understanding, attrs, weights, Compile, chips, QueryKey, Rings
internal/discovery/repository/understanding_pg.go  cache Get/Put
internal/discovery/service/search.go          Search, Nearby
internal/discovery/handler/search.go          GET /v1/search, GET /v1/feed/nearby
internal/screen/service/home.go, handler/home.go   GET /v1/screens/home
api/…                                         spec for all of the above
e2e/search_test.go, e2e/llm_stub_test.go      e2e and the model stub
ARCHITECTURE.md                               Search section, PG18 note
```

---

### Task 1: ParadeDB on Postgres 18 and the search migration

**Files:**
- Modify: `docker-compose.yml:10`, `docker-compose.test.yml:12` and their comments
- Create: `migrations/0019_search.sql`
- Test: `internal/catalog/repository/search_index_pg_test.go`

**Interfaces:**
- Produces: columns `listings.lat`, `listings.lng` (double precision NOT NULL), `listings.category_root` (generated), `listings.specs_text` (generated); index `listings_search`; table `search_understandings`.

- [ ] **Step 1: Switch the images**

In both compose files replace `image: postgres:19rc1` with `image: paradedb/paradedb:0.26.3-pg18`. In `docker-compose.yml` replace the volume comment with:

```yaml
    # ParadeDB is Postgres 18 with pg_search preloaded. Postgres 18 keeps
    # data under /var/lib/postgresql/18/docker and declares the volume one
    # level up; a volume made by 19rc1 starts an empty 18 directory beside it.
```

In `docker-compose.test.yml` change "Postgres 19 keeps its data directory under /var/lib/postgresql/19/docker" to "Postgres 18 keeps its data directory under /var/lib/postgresql/18/docker".

- [ ] **Step 2: Write the failing test**

`internal/catalog/repository/search_index_pg_test.go`:

```go
package repository_test

import (
	"context"
	"testing"

	"github.com/shopnexus/server2/internal/platform/postgres/pgtest"
)

// The search migration leaves one ParadeDB index on listings and the
// understanding cache.
func TestSearchIndex(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	var am string
	if err := db.QueryRow(context.Background(), `SELECT am.amname FROM pg_class c
JOIN pg_am am ON am.oid = c.relam WHERE c.relname = 'listings_search'`).Scan(&am); err != nil || am != "paradedb" && am != "bm25" {
		t.Fatalf("index: %q %v", am, err)
	}
	var n int
	if err := db.QueryRow(context.Background(), `SELECT count(*) FROM search_understandings`).Scan(&n); err != nil {
		t.Fatal(err)
	}
}
```

(Check the pgtest import path with `grep -rn 'func New(' internal/platform/postgres`; use the helper the other repository tests use.)

- [ ] **Step 3: Recreate the test stack's Postgres and watch the test fail**

Run: `docker compose -f docker-compose.test.yml up -d --wait --force-recreate postgres && go test ./internal/catalog/repository/ -run TestSearchIndex`
Expected: FAIL, relation `listings_search` does not exist.

- [ ] **Step 4: Write the migration**

`migrations/0019_search.sql`:

```sql
-- Search: ParadeDB's BM25 index over listings, the listing's point for
-- distance, and the cache of the model's understanding of a query.
-- pg_search is preloaded by the paradedb image and brings vector.
CREATE EXTENSION IF NOT EXISTS pg_search;

-- The point distance is measured from: blurred from the seller's GPS, or the
-- commune's point. It never leaves the server.
ALTER TABLE listings ADD COLUMN lat double precision;
ALTER TABLE listings ADD COLUMN lng double precision;
UPDATE listings l SET lat = c.lat, lng = c.lng FROM communes c WHERE c.code = l.commune_code;
ALTER TABLE listings ALTER COLUMN lat SET NOT NULL, ALTER COLUMN lng SET NOT NULL;

ALTER TABLE listings ADD COLUMN category_root text
    GENERATED ALWAYS AS (split_part(category_code, '.', 1)) STORED;
-- The specs as text, so one field matches labels and values.
ALTER TABLE listings ADD COLUMN specs_text text GENERATED ALWAYS AS (specs::text) STORED;

CREATE INDEX listings_search ON listings USING paradedb (
    id, title, description, specs_text,
    (category_code::pdb.literal), (category_root::pdb.literal), price, (condition::pdb.literal),
    allow_offers, (status::pdb.literal), published_at, lat, lng
);

-- What the model understood of a normalized query. No account is stored.
CREATE TABLE search_understandings (
    query_key      text NOT NULL,
    prompt_version integer NOT NULL,
    answer         jsonb NOT NULL,
    created_at     timestamptz NOT NULL,
    PRIMARY KEY (query_key, prompt_version)
);
CREATE INDEX search_understandings_created ON search_understandings (created_at);
```

Run `sqlfluff lint migrations/0019_search.sql`; if it rejects the ParadeDB cast syntax, add the file to `.sqlfluffignore` with a comment saying why.

- [ ] **Step 5: Run the test and the whole repository package**

Run: `go test -race ./internal/catalog/... ./internal/platform/postgres/...`
Expected: PASS. Postgres 18 runs every existing migration (uuidv7() exists since 18).

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml docker-compose.test.yml migrations/0019_search.sql internal/catalog/repository/search_index_pg_test.go .sqlfluffignore
git commit -m "feat: ParadeDB on Postgres 18 and the search index"
```

---

### Task 2: Float and repeated query parameters in Bind

**Files:**
- Modify: `internal/platform/httpx/bind.go` (parserFor and the query reader near line 48)
- Test: `internal/platform/httpx/bind_test.go`

**Interfaces:**
- Produces: `httpx.Bind` fills `float64` fields from a query value and `[]string` fields from every value of a repeated key (and of a header, the same way).

- [ ] **Step 1: Write the failing test**

Append to `bind_test.go`:

```go
func TestBindFloatAndRepeated(t *testing.T) {
	t.Parallel()
	var in struct {
		Lat  float64  `json:"-" query:"near_lat"`
		Cond []string `json:"-" query:"condition"`
	}
	r := httptest.NewRequest("GET", "/x?near_lat=10.75&condition=new&condition=used", nil)
	if err := httpx.Bind(r, &in); err != nil || in.Lat != 10.75 || len(in.Cond) != 2 || in.Cond[1] != "used" {
		t.Fatalf("%+v %v", in, err)
	}
	r = httptest.NewRequest("GET", "/x?near_lat=north", nil)
	if err := httpx.Bind(r, &in); err == nil {
		t.Fatal("a word bound as a float")
	}
}
```

- [ ] **Step 2: Run it**

Run: `go test ./internal/platform/httpx/ -run TestBindFloatAndRepeated`
Expected: FAIL (panic: Bind cannot read float64).

- [ ] **Step 3: Implement**

In `parserFor` add a case:

```go
	case reflect.Float32, reflect.Float64:
		return func(v reflect.Value, raw string) error {
			f, err := strconv.ParseFloat(raw, ft.Bits())
			if err != nil {
				return fmt.Errorf("parse float: %w", err)
			}
			v.SetFloat(f)
			return nil
		}
```

Update the comment "Bind reads four of the 27 kinds" to "five". Where Bind reads a query or header value for a field (around line 48), when the field's kind is `reflect.Slice` of strings set it from every value instead of the first:

```go
		if fv.Kind() == reflect.Slice && fv.Type().Elem().Kind() == reflect.String {
			fv.Set(reflect.ValueOf(values)) // every value of a repeated key
			continue
		}
```

(`values` is `query[name]` or `r.Header.Values(name)`; read the existing loop and place this before the single-value parse.)

- [ ] **Step 4: Run the httpx package**

Run: `go test -race ./internal/platform/httpx/`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/platform/httpx/
git commit -m "feat: bind float and repeated query parameters"
```

---

### Task 3: The listing's point (catalog domain, store, post and edit)

**Files:**
- Create: `internal/catalog/domain/geo.go`, `internal/catalog/domain/geo_test.go`
- Modify: `internal/catalog/domain/listing.go` (Draft, Refs, Listing, apply, ListingState, RestoreListing, State)
- Modify: `internal/catalog/repository/listing_pg.go` (listingColumns, scanListing, args, insertListing, saveListing)
- Modify: `internal/catalog/service/listing_post_durable.go` (`lookUpRefs`)
- Modify: `internal/catalog/handler/draft.go`
- Modify: `api/schemas/catalog.yaml` (ListingDraft)
- Test: `internal/catalog/domain/listing_test.go`, `e2e/catalog_test.go`

**Interfaces:**
- Produces:
  - `type domain.Point struct{ Lat, Lng float64 }`
  - `func domain.Distance(a, b Point) float64` (km, haversine)
  - `func domain.Blur(p Point) Point`
  - `const domain.MaxGPSKm = 30`
  - `Draft.Spot *Point` (already blurred), `Refs.CommunePoint Point`
  - `func (l *Listing) Point() Point`; `ListingState.Lat`, `ListingState.Lng`

- [ ] **Step 1: Write the failing domain tests**

`internal/catalog/domain/geo_test.go`:

```go
package domain_test

import (
	"math"
	"testing"

	"github.com/shopnexus/server2/internal/catalog/domain"
)

func TestBlur(t *testing.T) {
	t.Parallel()
	p := domain.Point{Lat: 10.776889, Lng: 106.700806}
	seen := map[domain.Point]bool{}
	for range 200 {
		b := domain.Blur(p)
		if d := domain.Distance(p, b); d > 1.3 {
			t.Fatalf("moved %.2f km", d)
		}
		for _, v := range []float64{b.Lat, b.Lng} {
			if r := math.Abs(v*100 - math.Round(v*100)); r > 1e-9 {
				t.Fatalf("%v is off the 0.01 grid", b)
			}
		}
		seen[b] = true
	}
	if len(seen) < 2 {
		t.Fatal("every blur landed on the same cell")
	}
}

func TestDistance(t *testing.T) {
	t.Parallel()
	// Hồ Gươm to Nhà hát Lớn Hà Nội, about 1.0 km.
	if d := domain.Distance(domain.Point{Lat: 21.0287, Lng: 105.8524}, domain.Point{Lat: 21.0245, Lng: 105.8577}); d < 0.6 || d > 0.8 {
		t.Fatalf("%.3f km", d)
	}
}
```

Append to `listing_test.go` (use the file's existing `draft()` and `refs` helpers; read them first):

```go
func TestListingPoint(t *testing.T) {
	t.Parallel()
	commune := domain.Point{Lat: 21.03, Lng: 105.85}
	refs := domain.Refs{CategoryIsLeaf: true, CommuneExists: true, CommunePoint: commune}
	d := validDraft()
	l, err := domain.NewListing(uuid.NewV7(), uuid.NewV7(), d, refs, now)
	if err != nil || l.Point() != commune {
		t.Fatalf("no gps: %v %v", l.Point(), err)
	}
	spot := domain.Point{Lat: 21.04, Lng: 105.86}
	d.Spot = &spot
	if err = l.Edit(d, refs, now); err != nil || l.Point() != spot {
		t.Fatalf("gps: %v %v", l.Point(), err)
	}
	d.Spot = nil
	if err = l.Edit(d, refs, now); err != nil || l.Point() != spot {
		t.Fatalf("an edit without gps kept %v, %v", l.Point(), err)
	}
	other := domain.Point{Lat: 10.77, Lng: 106.70}
	d.CommuneCode = "26734"
	if err = l.Edit(d, domain.Refs{CategoryIsLeaf: true, CommuneExists: true, CommunePoint: other}, now); err != nil || l.Point() != other {
		t.Fatalf("a new commune: %v %v", l.Point(), err)
	}
	far := domain.Point{Lat: 21.5, Lng: 105.85}
	d.Spot = &far
	if _, err = domain.NewListing(uuid.NewV7(), uuid.NewV7(), d, domain.Refs{CategoryIsLeaf: true, CommuneExists: true, CommunePoint: commune}, now); !hasField(err, "gps") {
		t.Fatalf("a point 50 km away: %v", err)
	}
}
```

(`validDraft`, `now` and `hasField` stand for the helpers the file has; if `hasField` is missing, write it there: it reports whether `err` is an `*apperr.Error` with an entry for the field.)

- [ ] **Step 2: Run them**

Run: `go test ./internal/catalog/domain/`
Expected: FAIL to compile (Blur, Point, Spot undefined).

- [ ] **Step 3: Implement geo.go**

```go
package domain

import (
	"math"
	"math/rand/v2"
)

// Point is a position in degrees.
type Point struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}

// MaxGPSKm is how far a seller's GPS point may be from their commune's
// point. The communes table holds points, not boundaries, so this distance
// stands in for "inside the commune".
const MaxGPSKm = 30

const earthKm = 6371.0

// Distance is the great-circle distance between a and b in kilometres.
func Distance(a, b Point) float64 {
	la1, la2 := a.Lat*math.Pi/180, b.Lat*math.Pi/180
	dla, dlo := la2-la1, (b.Lng-a.Lng)*math.Pi/180
	h := math.Pow(math.Sin(dla/2), 2) + math.Cos(la1)*math.Cos(la2)*math.Pow(math.Sin(dlo/2), 2)
	return 2 * earthKm * math.Asin(math.Sqrt(h))
}

// blurKm is the largest random offset Blur applies before rounding.
const blurKm = 0.5

// Blur moves p by up to 500 m in a random direction, then rounds it to a
// 0.01° grid (about 1.1 km), so the stored point says which cell the seller
// is near and no more.
func Blur(p Point) Point {
	r := blurKm * math.Sqrt(rand.Float64()) // uniform over the disc
	angle := 2 * math.Pi * rand.Float64()
	lat := p.Lat + r*math.Cos(angle)/111.32
	lng := p.Lng + r*math.Sin(angle)/(111.32*math.Cos(p.Lat*math.Pi/180))
	return Point{Lat: math.Round(lat*100) / 100, Lng: math.Round(lng*100) / 100}
}
```

- [ ] **Step 4: Implement the listing point**

In `listing.go`:
- `Draft` gains `Spot *Point` with the comment `// Spot is the seller's GPS point, already blurred; nil keeps the stored one.`
- `Refs` gains `CommunePoint Point // the chosen commune's point`.
- `Listing` gains `point Point`.
- In `apply`, before `if len(e.Fields) > 0`:

```go
	if d.Spot != nil && Distance(*d.Spot, refs.CommunePoint) > MaxGPSKm {
		e = e.WithField("gps", "within 30 km of the commune")
	}
```

  and after the assignments at the end of `apply`:

```go
	switch {
	case d.Spot != nil:
		l.point = *d.Spot
	case l.point == (Point{}) || l.communeCode != d.CommuneCode:
		l.point = refs.CommunePoint
	}
```

  Move this `switch` above the line that sets `l.communeCode`, so the comparison reads the old commune.
- `func (l *Listing) Point() Point { return l.point }` with the comment `// Point is where distance is measured from. Server only: no view carries it.`
- `ListingState` gains `Lat float64 \`json:"lat"\`` and `Lng float64 \`json:"lng"\``; `RestoreListing` sets `point: Point{Lat: st.Lat, Lng: st.Lng}`; `State` sets `Lat: l.point.Lat, Lng: l.point.Lng`.

Run: `go test ./internal/catalog/domain/` → PASS.

- [ ] **Step 5: Store the point**

In `listing_pg.go`:
- `listingColumns` ends `…, deleted_at, lat, lng`.
- `scanListing` scans `&st.Lat, &st.Lng` last.
- `args` adds `"lat": st.Lat, "lng": st.Lng`.
- `insertListing` adds `, @lat, @lng` after `@deleted_at`.
- `saveListing` adds `lat = @lat, lng = @lng,` to the `SET` list.

- [ ] **Step 6: Read the commune's point with the refs**

In `lookUpRefs` (`listing_post_durable.go`) replace the `CommuneExists` call with a `Places` read:

```go
		places, stepErr := regions.Places(rc, []string{d.CommuneCode})
		if stepErr != nil {
			return domain.Refs{}, fmt.Errorf("read commune: %w", stepErr)
		}
		refs := domain.Refs{CategoryIsLeaf: leaf}
		if len(places) == 1 {
			refs.CommuneExists = true
			refs.CommunePoint = domain.Point{Lat: places[0].Lat, Lng: places[0].Lng}
		}
		return refs, nil
```

If `Regions.CommuneExists` has no caller left (`grep -rn CommuneExists internal`), delete it from the interface and `region_pg.go`.

- [ ] **Step 7: Blur in the handler**

In `draft.go`:

```go
	GPS          *gpsBody         `json:"gps"`
```

```go
// gpsBody is the seller's position. The handler blurs it at once, so the
// exact point goes no further than this request.
type gpsBody struct {
	Lat float64 `json:"lat"`
	Lng float64 `json:"lng"`
}
```

and in `draft()`:

```go
	var spot *domain.Point
	if b.GPS != nil {
		spot = new(domain.Blur(domain.Point{Lat: b.GPS.Lat, Lng: b.GPS.Lng}))
	}
```

passing `Spot: spot` in the returned `domain.Draft`.

- [ ] **Step 8: Spec the field**

In `api/schemas/catalog.yaml` under `ListingDraft.properties` add:

```yaml
    gps:
      type: object
      additionalProperties: false
      required: [lat, lng]
      description: |
        The seller's position, sent only with their permission. The server
        blurs it to about 1 km before storing and never returns it. A point
        farther than 30 km from the commune is 422 invalid_listing on field gps.
      properties:
        lat: {type: number, minimum: -90, maximum: 90}
        lng: {type: number, minimum: -180, maximum: 180}
```

- [ ] **Step 9: e2e**

In `e2e/catalog_test.go` add:

```go
// A GPS point far from the commune is refused, a near one is taken, and no
// response shows the stored point.
func TestListingGPS(t *testing.T) {
	t.Parallel()
	seller, _ := newAccount(t)
	body := listingBody(t, seller.AccessToken) // the existing body builder; commune 00004 is in Hà Nội
	body["gps"] = map[string]any{"lat": 10.77, "lng": 106.70}
	res := call(t, server, "POST", "/v1/listings", body, bearer(seller.AccessToken), newKey())
	if e := errorOf(t, res); res.Status != 422 || e.Code != "invalid_listing" || !slices.ContainsFunc(e.Fields, func(f fieldError) bool { return f.Name == "gps" }) {
		t.Fatalf("far: %d %s", res.Status, res.Body)
	}
	body["gps"] = map[string]any{"lat": 21.03, "lng": 105.85}
	res = call(t, server, "POST", "/v1/listings", body, bearer(seller.AccessToken), newKey())
	if res.Status != http.StatusCreated || strings.Contains(string(res.Body), "21.03") {
		t.Fatalf("near: %d %s", res.Status, res.Body)
	}
}
```

(Use the file's body builder and the field-error type the e2e helpers define; read `helpers_test.go` for their names.)

- [ ] **Step 10: Run**

Run: `go test -race ./internal/catalog/... && go test -race ./e2e/ -run 'TestListing'`
Expected: PASS (the e2e package prints the coverage note for a filtered run; that is expected).

- [ ] **Step 11: Commit**

```bash
git add internal/catalog api/schemas/catalog.yaml e2e/catalog_test.go
git commit -m "feat: a listing keeps a blurred point for distance"
```

---

### Task 4: Catalog's structured search

**Files:**
- Create: `internal/catalog/domain/search.go`
- Create: `internal/catalog/repository/search_pg.go`, `internal/catalog/repository/search_pg_test.go`
- Modify: `internal/catalog/repository/repository.go` (interface `Searches`), `region_pg.go` + `repository.go` (`FindPlace`)

**Interfaces:**
- Consumes: Task 1 columns and index; Task 3 `domain.Point`.
- Produces (catalog/domain):

```go
type SortOrder string // "relevance" | "newest" | "nearest" | "price_asc" | "price_desc"
type Filters struct {
	CategoryRoot, CategoryCode string
	PriceMin, PriceMax         int64 // 0 is no bound
	Conditions                 []Condition
	OffersOnly                 bool
	Origin                     *Point
	RadiusKm                   int // 0 is no radius
}
type Phrase struct { Text string; Weight float64 } // negative demotes
type BoostKind string // "category" | "category_root" | "price" | "condition" | "offers" | "near" | "fresh"
type Boost struct {
	Kind               BoostKind
	Weight             float64 // negative demotes
	Code               string    // category, category_root
	PriceMin, PriceMax int64     // price; 0 is open
	Condition          Condition // condition
	Near               Point     // near
	RadiusKm           float64   // near
	Since              time.Time // fresh
}
type Search struct {
	Filters Filters
	Phrases []Phrase // empty: browse, every active listing under the filters
	Boosts  []Boost
	Sort    SortOrder
	Offset, Limit int
}
type Hit struct { ID uuid.UUID; Point Point }
type CountField string // "category_code" | "category_root"
type CategoryCount struct { Code string `json:"category"`; Count int `json:"count"` }
const MaxResults = 500
```

- Produces (catalog/repository): `type Searches interface { Search(ctx, domain.Search) ([]domain.Hit, error); Counts(ctx, domain.Search, domain.CountField) ([]domain.CategoryCount, error) }`, `func NewSearches(db *pgxpool.Pool) Searches`; on `Regions`: `FindPlace(ctx, name string) ([]domain.Point, error)`.

- [ ] **Step 1: Write the domain types** (the block above, in `search.go`, with these comments: `Search` "is a page of listings: the person's filters, the phrases that must match one at least, the boosts that order what matched, and the sort."; `Boost` "adds Weight to a listing's score when it matches, as a constant, so it moves listings that matched the phrases and brings in none."; `MaxResults` "is how deep a search pages.").

- [ ] **Step 2: Write the failing repository test**

`search_pg_test.go` inserts listings straight through `Listings.Insert` with a helper, then searches. Read `listing_pg_test.go` for its listing builder and reuse it, giving each listing title, category, price, condition, status, published_at and point.

```go
func TestSearch(t *testing.T) {
	t.Parallel()
	db := pgtest.New(t)
	ctx := context.Background()
	s := repository.NewSearches(db)
	hn := domain.Point{Lat: 21.03, Lng: 105.85}
	touring := put(t, db, item{title: "Xe đạp touring Giant", cat: "vehicles.bicycle", price: 2_500_000, point: hn, age: 24 * time.Hour})
	mtb := put(t, db, item{title: "Xe đạp địa hình", cat: "vehicles.bicycle", price: 1_800_000, point: domain.Point{Lat: 21.20, Lng: 105.85}, age: 20 * 24 * time.Hour})
	lamp := put(t, db, item{title: "Đèn xe đạp", cat: "sports.accessories", price: 150_000, point: hn, age: time.Hour})
	put(t, db, item{title: "Xe đạp trẻ em", cat: "baby.toys", price: 900_000, point: hn, status: domain.StatusReserved})
	put(t, db, item{title: "iPhone 13", cat: "phones.iphone", price: 8_000_000, point: hn})

	ids := func(q domain.Search) []uuid.UUID {
		t.Helper()
		q.Limit = 20
		hits, err := s.Search(ctx, q)
		if err != nil {
			t.Fatal(err)
		}
		out := make([]uuid.UUID, len(hits))
		for i, h := range hits {
			out[i] = h.ID
		}
		return out
	}
	text := []domain.Phrase{{Text: "xe đạp", Weight: 1}}

	// Only matching, active listings; the reserved one never shows.
	if got := ids(domain.Search{Phrases: text, Sort: domain.SortRelevance}); len(got) != 3 {
		t.Fatalf("plain: %v", got)
	}
	// A demote pushes the accessory last; a category boost lifts bicycles.
	got := ids(domain.Search{Phrases: text, Sort: domain.SortRelevance, Boosts: []domain.Boost{
		{Kind: domain.BoostCategory, Code: "vehicles.bicycle", Weight: 1.5},
		{Kind: domain.BoostCategoryRoot, Code: "sports", Weight: -1.5},
	}})
	if got[2] != lamp {
		t.Fatalf("demote: %v", got)
	}
	// A near ring puts the Hà Nội touring bike above the one 19 km north.
	got = ids(domain.Search{Phrases: text, Sort: domain.SortRelevance, Filters: domain.Filters{CategoryCode: "vehicles.bicycle"},
		Boosts: []domain.Boost{{Kind: domain.BoostNear, Near: hn, RadiusKm: 5, Weight: 2}}})
	if len(got) != 2 || got[0] != touring {
		t.Fatalf("near: %v", got)
	}
	// A narrow filter still returns its one match.
	if got = ids(domain.Search{Phrases: text, Sort: domain.SortRelevance, Filters: domain.Filters{PriceMax: 2_000_000, CategoryRoot: "vehicles"}}); len(got) != 1 || got[0] != mtb {
		t.Fatalf("narrow: %v", got)
	}
	// Browse by price, and the radius filter.
	if got = ids(domain.Search{Sort: domain.SortPriceAsc, Filters: domain.Filters{Origin: &hn, RadiusKm: 10}}); len(got) != 3 || got[0] != lamp {
		t.Fatalf("radius by price: %v", got)
	}
	// Fresh rings order a browse with no phrase.
	if got = ids(domain.Search{Sort: domain.SortRelevance, Filters: domain.Filters{CategoryRoot: "vehicles"},
		Boosts: []domain.Boost{{Kind: domain.BoostFresh, Since: time.Now().Add(-3 * 24 * time.Hour), Weight: 1}}}); got[0] != touring {
		t.Fatalf("fresh: %v", got)
	}
	// Counts under a root.
	counts, err := s.Counts(ctx, domain.Search{Phrases: text, Filters: domain.Filters{CategoryRoot: "vehicles"}}, domain.CountCode)
	if err != nil || len(counts) != 1 || counts[0].Count != 2 {
		t.Fatalf("counts: %v %v", counts, err)
	}
	// A phrase of punctuation matches nothing and errs on nothing.
	if got = ids(domain.Search{Phrases: []domain.Phrase{{Text: "?!", Weight: 1}}, Sort: domain.SortRelevance}); len(got) != 0 {
		t.Fatalf("punctuation: %v", got)
	}
}
```

- [ ] **Step 3: Run it** — `go test ./internal/catalog/repository/ -run TestSearch` → FAIL to compile.

- [ ] **Step 4: Implement `search_pg.go`**

```go
package repository

import (
	"context"
	"fmt"
	"math"
	"strings"
	"unicode/utf8"
	"uuid"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/shopnexus/server2/internal/catalog/domain"
)

type pgSearches struct{ db *pgxpool.Pool }

func NewSearches(db *pgxpool.Pool) Searches { return pgSearches{db} }

// query assembles one ParadeDB query from fixed fragments and generated
// parameter names; no caller value reaches the SQL text.
type query struct {
	args pgx.StrictNamedArgs
	n    int
}

func (q *query) arg(v any, cast string) string {
	name := fmt.Sprintf("p%d", q.n)
	q.n++
	q.args[name] = v
	return "@" + name + "::" + cast
}

func array(items []string) string {
	return "ARRAY[" + strings.Join(items, ", ") + "]::paradedb.searchqueryinput[]"
}

// box is the lat/lng ranges around p that hold a circle of radius km.
func (q *query) box(p domain.Point, km float64) string {
	dLat := km / 111.32
	dLng := km / (111.32 * math.Cos(p.Lat*math.Pi/180))
	return `paradedb.boolean(must => ` + array([]string{
		`paradedb.range('lat', numrange(` + q.arg(p.Lat-dLat, "numeric") + `, ` + q.arg(p.Lat+dLat, "numeric") + `, '[]'))`,
		`paradedb.range('lng', numrange(` + q.arg(p.Lng-dLng, "numeric") + `, ` + q.arg(p.Lng+dLng, "numeric") + `, '[]'))`,
	}) + `)`
}

func (q *query) priceRange(lo, hi int64) string {
	var low, high any
	if lo > 0 {
		low = lo
	}
	if hi > 0 {
		high = hi
	}
	return `paradedb.range('price', int8range(` + q.arg(low, "bigint") + `, ` + q.arg(high, "bigint") + `, '[]'))`
}

// must is the filters, and with phrases the rule that one of them matches.
func (q *query) must(s domain.Search) []string {
	f := s.Filters
	out := []string{`paradedb.term('status', ` + q.arg(string(domain.StatusActive), "text") + `)`}
	if f.CategoryRoot != "" {
		out = append(out, `paradedb.term('category_root', `+q.arg(f.CategoryRoot, "text")+`)`)
	}
	if f.CategoryCode != "" {
		out = append(out, `paradedb.term('category_code', `+q.arg(f.CategoryCode, "text")+`)`)
	}
	if f.PriceMin > 0 || f.PriceMax > 0 {
		out = append(out, q.priceRange(f.PriceMin, f.PriceMax))
	}
	if len(f.Conditions) > 0 {
		var conds []string
		for _, c := range f.Conditions {
			conds = append(conds, `paradedb.term('condition', `+q.arg(string(c), "text")+`)`)
		}
		out = append(out, `paradedb.boolean(should => `+array(conds)+`)`)
	}
	if f.OffersOnly {
		out = append(out, `paradedb.term('allow_offers', true)`)
	}
	if f.Origin != nil && f.RadiusKm > 0 {
		out = append(out, q.box(*f.Origin, float64(f.RadiusKm)))
	}
	var phrases []string
	for _, p := range s.Phrases {
		if p.Weight > 0 {
			phrases = append(phrases, q.phrase(p)...)
		}
	}
	if len(s.Phrases) > 0 {
		if len(phrases) == 0 {
			phrases = []string{`paradedb.empty()`}
		}
		out = append(out, `paradedb.boolean(should => `+array(phrases)+`)`)
	}
	return out
}

// fuzzyRunes is the length from which a word may match with one edit.
const fuzzyRunes = 5

// phrase matches the title at twice its weight, description and specs at
// its weight, and the title's long words with one edit at half of it.
func (q *query) phrase(p domain.Phrase) []string {
	text := q.arg(p.Text, "text")
	out := []string{
		`paradedb.boost(` + q.arg(2*p.Weight, "real") + `, paradedb.match('title', ` + text + `))`,
		`paradedb.boost(` + q.arg(p.Weight, "real") + `, paradedb.match('description', ` + text + `))`,
		`paradedb.boost(` + q.arg(p.Weight, "real") + `, paradedb.match('specs_text', ` + text + `))`,
	}
	var long []string
	for _, w := range strings.Fields(p.Text) {
		if utf8.RuneCountInString(w) >= fuzzyRunes {
			long = append(long, w)
		}
	}
	if len(long) > 0 {
		out = append(out, `paradedb.boost(`+q.arg(p.Weight/2, "real")+`, paradedb.match('title', `+
			q.arg(strings.Join(long, " "), "text")+`, distance => 1))`)
	}
	return out
}

// should is the boosts as constant scores, and the demoted phrases.
func (q *query) should(s domain.Search) []string {
	var out []string
	for _, p := range s.Phrases {
		if p.Weight < 0 {
			out = append(out, q.phrase(p)...)
		}
	}
	for _, b := range s.Boosts {
		var clause string
		switch b.Kind {
		case domain.BoostCategory:
			clause = `paradedb.term('category_code', ` + q.arg(b.Code, "text") + `)`
		case domain.BoostCategoryRoot:
			clause = `paradedb.term('category_root', ` + q.arg(b.Code, "text") + `)`
		case domain.BoostPrice:
			clause = q.priceRange(b.PriceMin, b.PriceMax)
		case domain.BoostCondition:
			clause = `paradedb.term('condition', ` + q.arg(string(b.Condition), "text") + `)`
		case domain.BoostOffers:
			clause = `paradedb.term('allow_offers', true)`
		case domain.BoostNear:
			clause = q.box(b.Near, b.RadiusKm)
		case domain.BoostFresh:
			clause = `paradedb.range('published_at', tstzrange(` + q.arg(b.Since, "timestamptz") + `, NULL, '[]'))`
		}
		out = append(out, `paradedb.const_score(`+q.arg(b.Weight, "real")+`, `+clause+`)`)
	}
	return out
}

func (q *query) where(s domain.Search, boosts bool) string {
	sql := `id @@@ paradedb.boolean(must => ` + array(q.must(s))
	if should := q.should(s); boosts && len(should) > 0 {
		sql += `, should => ` + array(should)
	}
	return sql + `)`
}

// distanceSQL is the great-circle distance in km from the origin parameters.
const distanceSQL = `(12742 * asin(sqrt(power(sin(radians(lat - @olat) / 2), 2)
       + cos(radians(@olat)) * cos(radians(lat)) * power(sin(radians(lng - @olng) / 2), 2))))`

func (s pgSearches) Search(ctx context.Context, in domain.Search) ([]domain.Hit, error) {
	q := query{args: pgx.StrictNamedArgs{"limit": in.Limit, "offset": in.Offset}}
	sql := `SELECT id, lat, lng FROM listings WHERE ` + q.where(in, true)
	if o := in.Filters.Origin; o != nil {
		q.args["olat"], q.args["olng"] = o.Lat, o.Lng
		if in.Filters.RadiusKm > 0 {
			q.args["radius"] = in.Filters.RadiusKm
			sql += ` AND ` + distanceSQL + ` <= @radius`
		}
	}
	switch in.Sort {
	case domain.SortNewest:
		sql += ` ORDER BY published_at DESC, id DESC`
	case domain.SortPriceAsc:
		sql += ` ORDER BY price ASC, id`
	case domain.SortPriceDesc:
		sql += ` ORDER BY price DESC, id`
	case domain.SortNearest:
		sql += ` ORDER BY ` + distanceSQL + `, id`
	case domain.SortRelevance:
		sql += ` ORDER BY paradedb.score(id) DESC, id`
	}
	rows, err := s.db.Query(ctx, sql+` LIMIT @limit OFFSET @offset`, q.args)
	if err != nil {
		return nil, fmt.Errorf("search: %w", err)
	}
	defer rows.Close()
	var out []domain.Hit
	for rows.Next() {
		var h domain.Hit
		if err = rows.Scan(&h.ID, &h.Point.Lat, &h.Point.Lng); err != nil {
			return nil, fmt.Errorf("scan hit: %w", err)
		}
		out = append(out, h)
	}
	if err = rows.Err(); err != nil {
		return nil, fmt.Errorf("search rows: %w", err)
	}
	return out, nil
}

func (s pgSearches) Counts(ctx context.Context, in domain.Search, by domain.CountField) ([]domain.CategoryCount, error) {
	q := query{args: pgx.StrictNamedArgs{}}
	column := "category_code"
	if by == domain.CountRoot {
		column = "category_root"
	}
	rows, err := s.db.Query(ctx, `SELECT `+column+`, count(*) FROM listings WHERE `+q.where(in, false)+
		` GROUP BY 1 ORDER BY 2 DESC, 1`, q.args)
	if err != nil {
		return nil, fmt.Errorf("count: %w", err)
	}
	defer rows.Close()
	var out []domain.CategoryCount
	for rows.Next() {
		var c domain.CategoryCount
		if err = rows.Scan(&c.Code, &c.Count); err != nil {
			return nil, fmt.Errorf("scan count: %w", err)
		}
		out = append(out, c)
	}
	if err = rows.Err(); err != nil {
		return nil, fmt.Errorf("count rows: %w", err)
	}
	return out, nil
}
```

(Name the `CountField` constants `CountCode` and `CountRoot` in `search.go`. Radius with an origin but sort `nearest` and no radius is the service's job: it sets `RadiusKm` to 50.) The `switch in.Sort` must be exhaustive for the linter; the five cases above are all of `SortOrder`.

- [ ] **Step 5: `FindPlace`**

In `repository.go` under `Regions`:

```go
	// FindPlace returns the points of the provinces and communes whose
	// display name, with or without its type ("Thành phố", "Tỉnh", "Phường",
	// "Xã", "Đặc khu"), is name, ignoring case. A province's point is the mean
	// of its communes'.
	FindPlace(ctx context.Context, name string) ([]domain.Point, error)
```

In `region_pg.go`:

```go
func (s pgRegions) FindPlace(ctx context.Context, name string) ([]domain.Point, error) {
	rows, err := s.db.Query(ctx, `
SELECT avg(c.lat), avg(c.lng) FROM provinces p JOIN communes c ON c.province_code = p.code
WHERE lower(p.display_name) = lower(@name)
   OR lower(regexp_replace(p.display_name, '^(Thành phố|Tỉnh) ', '')) = lower(@name)
GROUP BY p.code
UNION ALL
SELECT lat, lng FROM communes
WHERE lower(display_name) = lower(@name)
   OR lower(regexp_replace(display_name, '^(Phường|Xã|Đặc khu) ', '')) = lower(@name)`,
		pgx.StrictNamedArgs{"name": strings.TrimSpace(name)})
	if err != nil {
		return nil, fmt.Errorf("find place: %w", err)
	}
	defer rows.Close()
	var out []domain.Point
	for rows.Next() {
		var p domain.Point
		if err = rows.Scan(&p.Lat, &p.Lng); err != nil {
			return nil, fmt.Errorf("scan place: %w", err)
		}
		out = append(out, p)
	}
	if err = rows.Err(); err != nil {
		return nil, fmt.Errorf("place rows: %w", err)
	}
	return out, nil
}
```

Add a test to `region_pg_test.go`: `FindPlace(ctx, "Hà Nội")` returns one point; `FindPlace(ctx, "Không có")` none.

- [ ] **Step 6: Run** — `go test -race ./internal/catalog/repository/` → PASS. If a ParadeDB call errs on an argument type, fix the cast in `arg` (every value carries an explicit `::type`, which is what overload resolution needs).

- [ ] **Step 7: Commit**

```bash
git add internal/catalog/domain/search.go internal/catalog/repository
git commit -m "feat: catalog searches listings through ParadeDB"
```

---

### Task 5: Catalog service search, places and cards

**Files:**
- Create: `internal/catalog/service/search.go`, `internal/catalog/service/search_test.go`
- Modify: `internal/catalog/service/service.go` (Service interface, Deps, Catalog struct), `internal/catalog/catalog.go` (Mount builds `repository.NewSearches`)

**Interfaces:**
- Consumes: Task 4 `Searches`, `FindPlace`; existing `Listings.GetMany`, `Regions.Places`, the batch `views`.
- Produces on `catalogsvc.Service`:

```go
// Search runs s and returns its listings as cards, in order.
Search(ctx context.Context, s domain.Search) ([]SearchCard, error)
// Counts counts the listings s matches by category or root.
Counts(ctx context.Context, s domain.Search, by domain.CountField) ([]domain.CategoryCount, error)
// CommunePoint is a commune's point; false for an unknown code.
CommunePoint(ctx context.Context, code string) (domain.Point, bool, error)
// Place resolves a province or commune name to one point; false when no
// place or more than one has the name.
Place(ctx context.Context, name string) (domain.Point, bool, error)
```

```go
// SearchCard is a listing as a search page shows it.
type SearchCard struct {
	ID            uuid.UUID        `json:"id"`
	Title         string           `json:"title"`
	Price         int64            `json:"price"`
	CoverThumbURL string           `json:"cover_thumb_url,omitempty"`
	Condition     domain.Condition `json:"condition"`
	AllowOffers   bool             `json:"allow_offers"`
	Commune       string           `json:"commune"`
	// DistanceKm is whole kilometres from the search's origin, 0 under 1 km;
	// absent without an origin.
	DistanceKm *int `json:"distance_km,omitempty"`
}
```

- [ ] **Step 1: Failing test** in `search_test.go` using the package's `newEnv` (read `helpers_test.go`): post two listings through `e.catalog.Post` in commune `00004`, publish them as the existing tests do, then `e.catalog.Search(ctx, domain.Search{Phrases: []domain.Phrase{{Text: <title word>, Weight: 1}}, Sort: domain.SortRelevance, Limit: 20, Filters: domain.Filters{Origin: &domain.Point{Lat: <commune lat>, Lng: <commune lng>}}})` returns both cards with `DistanceKm` set to 0 and `Commune` non-empty. `Place(ctx, "Hà Nội")` is true; `CommunePoint(ctx, "nope")` is false.

- [ ] **Step 2: Run** → FAIL to compile.

- [ ] **Step 3: Implement `search.go`**

```go
package service

func (c *Catalog) Search(ctx context.Context, s domain.Search) ([]SearchCard, error) {
	hits, err := c.searches.Search(ctx, s)
	if err != nil {
		return nil, fmt.Errorf("search: %w", err)
	}
	ids := make([]uuid.UUID, len(hits))
	for i, h := range hits {
		ids[i] = h.ID
	}
	ls, err := c.listings.GetMany(ctx, ids)
	if err != nil {
		return nil, fmt.Errorf("read listings: %w", err)
	}
	vs, err := c.views(ctx, ls)
	if err != nil {
		return nil, err
	}
	byID := make(map[uuid.UUID]ListingView, len(vs))
	for _, v := range vs {
		byID[v.ID] = v
	}
	out := make([]SearchCard, 0, len(hits))
	for _, h := range hits {
		v, ok := byID[h.ID]
		if !ok {
			continue // deleted between the index scan and the read
		}
		card := SearchCard{
			ID: v.ID, Title: v.Title, Price: v.Price, Condition: v.Condition, AllowOffers: v.AllowOffers,
			Commune: v.Location.Commune.DisplayName,
		}
		if len(v.Photos) > 0 {
			card.CoverThumbURL = v.Photos[0].ThumbURL
		}
		if o := s.Filters.Origin; o != nil {
			card.DistanceKm = new(int(domain.Distance(*o, h.Point)))
		}
		out = append(out, card)
	}
	return out, nil
}
```

(`int(x)` truncates, so 0.9 km is 0 and 1.9 km is 1. Check the photo view's thumbnail field name in `views.go`.)

`Counts` passes through to `c.searches.Counts` with an error wrap. `CommunePoint` reads `c.regions.Places(ctx, []string{code})`. `Place` reads `c.regions.FindPlace` and answers true only for exactly one point.

Add `searches repository.Searches` to `Deps`/`Catalog`, and `repository.NewSearches(d.Pool)` in `catalog.Mount`.

- [ ] **Step 4: Run** — `go test -race ./internal/catalog/...` → PASS.

- [ ] **Step 5: Commit**

```bash
git add internal/catalog
git commit -m "feat: catalog search cards, places and counts"
```

---

### Task 6: LLM provider, config, and the understanding domain

**Files:**
- Create: `internal/provider/llm/llm.go`, `internal/provider/llm/llm_test.go`
- Modify: `internal/platform/config/config.go`, `config_test.go`, `.env.example`
- Create: `internal/discovery/domain/understanding.go`, `internal/discovery/domain/understanding_test.go`
- Modify: `internal/discovery/domain/errors.go`

**Interfaces:**
- Produces (llm):

```go
type Request struct {
	System, User string
	SchemaName   string
	Schema       json.RawMessage
}
type Client interface {
	// Complete asks for an answer that fits r.Schema and decodes it into out.
	Complete(ctx context.Context, r Request, out any) error
}
type OpenAI struct {
	BaseURL, APIKey, Model string
	HTTP                   *http.Client
}
```

- Produces (config): `Config.LLM LLMConfig{BaseURL, APIKey, Model string}` from `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL` via `need`.
- Produces (discovery/domain):

```go
const PromptVersion = 1
const ModelTimeout = 4 * time.Second
const CacheTTL = 7 * 24 * time.Hour
type Attr string // phrase category price condition place near_me fresh offers
type Signal struct { Attr Attr `json:"attr"`; Values []string `json:"values"` }
type Understanding struct {
	Understood string   `json:"understood"`
	Boosts     []Signal `json:"boosts"`
	Demotes    []Signal `json:"demotes"`
}
// Vocabulary resolves what the model named.
type Vocabulary struct {
	Categories map[string]string // code → display name, roots and subcategories
	Place      func(name string) (catalogdomain.Point, bool)
}
type Chip struct { ID string `json:"id"`; Kind Attr `json:"kind"`; Label string `json:"label"` }
type Compiled struct {
	Phrases []catalogdomain.Phrase
	Boosts  []catalogdomain.Boost
	Chips   []Chip
	Asked, Ran []string // for the log line
}
func Compile(u Understanding, raw string, v Vocabulary, origin *catalogdomain.Point, now time.Time, off []string) Compiled
func NearbyBoosts(origin catalogdomain.Point, now time.Time) []catalogdomain.Boost
func QueryKey(q string) string
func Schema() json.RawMessage
func SystemPrompt(categories []catalogdomain.Category, today time.Time) string
var ErrPositionRequired, ErrInvalidPosition, ErrInvalidCursor *apperr.Error
```

- [ ] **Step 1: LLM client test** (`llm_test.go`): an `httptest.Server` checks `POST /chat/completions`, the `Authorization: Bearer k` header, `model`, and `response_format.type == "json_schema"`, then answers `{"choices":[{"message":{"content":"{\"a\":1}"}}]}`; `Complete` decodes `{a:1}`. A second case answers 500 and `Complete` errs. A third blocks past the context deadline and `Complete` errs.

- [ ] **Step 2: Implement `llm.go`**

```go
// Package llm asks a language model for structured answers through an
// OpenAI-compatible chat completions endpoint.
package llm

func (c OpenAI) Complete(ctx context.Context, r Request, out any) error {
	body, err := json.Marshal(map[string]any{
		"model": c.Model,
		"messages": []map[string]string{
			{"role": "system", "content": r.System},
			{"role": "user", "content": r.User},
		},
		"temperature": 0,
		"response_format": map[string]any{
			"type":        "json_schema",
			"json_schema": map[string]any{"name": r.SchemaName, "strict": true, "schema": r.Schema},
		},
	})
	if err != nil {
		return fmt.Errorf("encode request: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+"/chat/completions", bytes.NewReader(body))
	if err != nil {
		return fmt.Errorf("build request: %w", err)
	}
	req.Header.Set("Authorization", "Bearer "+c.APIKey)
	req.Header.Set("Content-Type", "application/json")
	res, err := c.HTTP.Do(req)
	if err != nil {
		return fmt.Errorf("call model: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return fmt.Errorf("model answered %d", res.StatusCode)
	}
	var reply struct {
		Choices []struct {
			Message struct {
				Content string `json:"content"`
			} `json:"message"`
		} `json:"choices"`
	}
	if err = json.NewDecoder(io.LimitReader(res.Body, 1<<20)).Decode(&reply); err != nil {
		return fmt.Errorf("decode reply: %w", err)
	}
	if len(reply.Choices) == 0 {
		return errors.New("model gave no choice")
	}
	if err = json.Unmarshal([]byte(reply.Choices[0].Message.Content), out); err != nil {
		return fmt.Errorf("decode answer: %w", err)
	}
	return nil
}
```

Run: `go test -race ./internal/provider/llm/` → PASS.

- [ ] **Step 3: Config**

Add `LLM LLMConfig` to `Config` with:

```go
// LLMConfig says where the model that reads search queries is. The key is
// never logged.
type LLMConfig struct {
	BaseURL string // LLM_BASE_URL: an OpenAI-compatible API, such as https://proxy/v1
	APIKey  string // LLM_API_KEY
	Model   string // LLM_MODEL
}
```

and in `Load`: `LLM: LLMConfig{BaseURL: need("LLM_BASE_URL"), APIKey: need("LLM_API_KEY"), Model: need("LLM_MODEL")},`. Add the three keys to `required()` in `config_test.go` and a case that `LLM_MODEL` empty fails. Add to `.env.example`:

```
# The model that reads search queries, OpenAI-compatible. make run does not
# fill these; set them before searching.
LLM_BASE_URL=
LLM_API_KEY=
LLM_MODEL=
```

Because `need` refuses empty values, `.env.example` must hold real values or `make run` fails with their names; put the proxy's base URL and model the user runs, and leave `LLM_API_KEY=` for them to fill, so the first `make run` names it.

- [ ] **Step 4: Understanding tests** (`understanding_test.go`), table-driven:
  - an empty `Understanding` gives one phrase, the raw query at 0.5, and no chips;
  - `boosts: [{category, ["vehicles.bicycle", "nope", "vehicles"]}]` gives `BoostCategory` 1.5 for the first, drops "nope", and `BoostCategoryRoot` at 1.5×0.33 for "vehicles", since position is the value's index in the model's array; chips `category-0`, `category-2`;
  - `price: ["-3000000"]` gives `BoostPrice{PriceMax: 3_000_000}` at 1.5 with label "Dưới 3 triệu"; `"1000000-2000000"` gives both bounds with label "1–2 triệu"; `"abc"` is dropped;
  - `near_me` with an origin gives three `BoostNear` rings (2 km 1.25, 5 km 0.75, 15 km 0.4) and chip "Gần bạn"; without an origin it is dropped;
  - `place: ["Hà Nội"]` resolves through `Vocabulary.Place` into rings around that point;
  - `fresh` gives `BoostFresh` at now−3 days weight 1.0 and now−7 days weight 0.5;
  - a demote `category` gives a negative weight and no chip;
  - `phrase: ["xe đạp touring", "xe đạp"]` gives phrases 1.0 and 0.5 plus the raw query at 0.5, unless the raw query equals one of them (case-insensitively), then no extra raw phrase;
  - `off: ["category-0"]` removes that boost and its chip;
  - an unknown attr, more than three values (the fourth is dropped), and a values list of empty strings are dropped;
  - `QueryKey("  Xe  ĐẠP ")` is `"xe đạp"`.

- [ ] **Step 5: Implement `understanding.go`**

Weights (one table, with a comment that they are starting values in BM25 points, to be measured against sample queries):

```go
var weight = map[Attr]float64{
	AttrPhrase: 1.0, AttrCategory: 1.5, AttrPrice: 1.5, AttrCondition: 0.75, AttrOffers: 0.75, AttrFresh: 1.0,
}
// RawWeight is what the person's own words are worth as a phrase.
const RawWeight = 0.5
// position is how much the 1st, 2nd and 3rd value of a signal count; it is
// also the cap on values per signal.
var position = []float64{1, 0.5, 0.33}
// rings are the distance boosts around a point, as (km, weight).
var rings = []struct{ km, weight float64 }{{2, 1.25}, {5, 0.75}, {15, 0.4}}
// freshness is the age boosts, as (age, share of the fresh weight).
var freshness = []struct{ age time.Duration; share float64 }{{3 * 24 * time.Hour, 1}, {7 * 24 * time.Hour, 0.5}}
```

`Compile` walks boosts (sign +1) then demotes (sign −1); for each signal and each value index `i < len(position)`, resolves by attr:
  - `phrase`: non-empty text → `Phrase{Text, sign*weight*position[i]}`; chip kind phrase.
  - `category`: `v.Categories[code]` exists; a code with a dot → `BoostCategory`, else `BoostCategoryRoot`; label the display name.
  - `price`: parse `lo-hi` (either side empty, both ≥ 0, lo ≤ hi when both set) → `BoostPrice`; label via a money helper: under one million in thousands ("Dưới 500 nghìn"), else millions with a comma decimal ("Dưới 1,5 triệu", "1–2 triệu", "Từ 5 triệu").
  - `condition`: one of new, like_new, used → `BoostCondition`; labels "Mới", "Như mới", "Đã dùng".
  - `place`: `v.Place(name)` → rings around it at `sign*position[i]` scale; label the name.
  - `near_me`: needs `origin` → rings around origin; label "Gần bạn".
  - `fresh`: freshness boosts, each `sign*weight[fresh]*share`; label "Mới đăng".
  - `offers`: `BoostOffers`; label "Cho trả giá".
  Flags (`near_me`, `fresh`, `offers`) take effect once whatever their values.
  Chip IDs are `<attr>-<index in the model's array>` for boosts only; a chip in `off` skips its boosts. `Asked` lists `+attr=value` / `-attr=value` as the model wrote them; `Ran` lists what became a boost or phrase. Finally append the raw phrase at `RawWeight` unless a positive phrase equals it under `QueryKey`.

`NearbyBoosts(origin, now)` returns the rings around origin plus the freshness boosts, the nearby feed's whole score.

`QueryKey`: `strings.ToLower(strings.Join(strings.Fields(q), " "))`.

`Schema()` returns this JSON (strict mode needs every property required and `additionalProperties: false`):

```json
{"type":"object","additionalProperties":false,"required":["understood","boosts","demotes"],
 "properties":{
  "understood":{"type":"string"},
  "boosts":{"type":"array","maxItems":8,"items":{"$ref":"#/$defs/signal"}},
  "demotes":{"type":"array","maxItems":4,"items":{"$ref":"#/$defs/signal"}}},
 "$defs":{"signal":{"type":"object","additionalProperties":false,"required":["attr","values"],
  "properties":{
   "attr":{"type":"string","enum":["phrase","category","price","condition","place","near_me","fresh","offers"]},
   "values":{"type":"array","maxItems":3,"items":{"type":"string"}}}}}}
```

`SystemPrompt(categories, today)` writes, in Vietnamese-aware English, the task: read a second-hand marketplace query in Vietnamese; return what to prefer (`boosts`) and avoid (`demotes`), values in priority order; `phrase` holds search words rewritten with correct Vietnamese diacritics and expanded abbreviations ("dt" → "điện thoại"); `category` holds codes from the list below only; `price` holds `lo-hi` in đồng with either side empty ("5tr" → 5000000); `condition` one of new, like_new, used; `place` a province or commune name; `near_me` when the person says near them; `fresh` for "mới đăng"; `offers` for "thương lượng/trả giá"; never write weights; `understood` is one short Vietnamese sentence of what will be searched. Then the category list as `code — display name` lines, and today's date.

Errors in `errors.go`:

```go
	ErrPositionRequired = apperr.New(apperr.KindBadRequest, "position_required", "this sort, radius or feed needs near_lat and near_lng, or near_commune")
	ErrInvalidPosition  = apperr.New(apperr.KindBadRequest, "invalid_position", "near_lat and near_lng go together, within -90..90 and -180..180, or near_commune names a commune")
	ErrInvalidCursor    = apperr.New(apperr.KindBadRequest, "invalid_cursor", "cursor is a next_cursor this endpoint gave")
```

- [ ] **Step 6: Run** — `go test -race ./internal/discovery/domain/ ./internal/platform/config/` → PASS.

- [ ] **Step 7: Commit**

```bash
git add internal/provider/llm internal/platform/config .env.example internal/discovery/domain
git commit -m "feat: the model client and the query understanding rules"
```

---

### Task 7: Discovery search, the nearby feed, endpoints and wiring

**Files:**
- Create: `internal/discovery/repository/understanding_pg.go`, `understanding_pg_test.go`
- Modify: `internal/discovery/repository/repository.go` (interface `Understandings`; `Saves.SavedAmong`)
- Create: `internal/discovery/service/search.go`, `search_test.go`
- Modify: `internal/discovery/service/service.go`
- Create: `internal/discovery/handler/search.go`; modify `handler.go` (Register takes identify)
- Modify: `internal/discovery/discovery.go` (Guards, llm client), `internal/app/app.go`
- Create: `api/paths/discovery.yaml` additions, `api/schemas/discovery.yaml` additions, `api/openapi.yaml` paths
- Create: `e2e/llm_stub_test.go`, `e2e/search_test.go`; modify `e2e/main_test.go`, `internal/app/app_test.go`

**Interfaces:**
- Consumes: Task 5 catalog Search/Counts/CommunePoint/Place/Categories; Task 6 domain and llm.
- Produces:

```go
// repository
type Understandings interface {
	// Get returns the answer stored for key and version at or after since.
	Get(ctx context.Context, key string, version int, since time.Time) (json.RawMessage, bool, error)
	// Put stores answer for key and version at at, replacing any, and
	// deletes the answers older than expired, in one transaction.
	Put(ctx context.Context, key string, version int, answer json.RawMessage, at, expired time.Time) error
}
// Saves gains: SavedAmong returns which of ids account saved.
SavedAmong(ctx context.Context, account uuid.UUID, ids []uuid.UUID) (map[uuid.UUID]bool, error)

// service
type Near struct { Lat, Lng float64; Commune string }
type SearchInput struct {
	Query                string
	Category             string
	PriceMin, PriceMax   int64
	Conditions           []catalogdomain.Condition
	RadiusKm             int
	OffersOnly           bool
	Sort                 catalogdomain.SortOrder // "" picks the default
	Off                  []string
	Near                 Near
	Cursor               string
	Limit                int
}
type SearchItem struct { catalogsvc.SearchCard; Saved bool `json:"saved"` }
type SearchView struct {
	Items      []SearchItem                    `json:"items"`
	NextCursor string                          `json:"next_cursor,omitempty"`
	Understood string                          `json:"understood,omitempty"`
	Chips      []domain.Chip                   `json:"chips,omitempty"`
	Counts     []catalogdomain.CategoryCount   `json:"counts,omitempty"`
}
Search(ctx context.Context, viewer *uuid.UUID, in SearchInput) (SearchView, error)
Nearby(ctx context.Context, viewer *uuid.UUID, near Near, cursor string, limit int) (SearchView, error)
```

- [ ] **Step 1: Cache repository test**: `Put` then `Get` with `since` before → found; `since` after → not found; a second `Put` of the same key replaces; a row put with `at` 8 days ago is gone after another `Put` whose `expired` is 7 days ago. Two concurrent `Put`s of one key both succeed.

- [ ] **Step 2: Implement `understanding_pg.go`**

```go
func (s pgUnderstandings) Put(ctx context.Context, key string, version int, answer json.RawMessage, at, expired time.Time) error {
	err := pgx.BeginFunc(ctx, s.db, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DELETE FROM search_understandings WHERE created_at < @expired`,
			pgx.StrictNamedArgs{"expired": expired}); err != nil {
			return fmt.Errorf("delete expired: %w", err)
		}
		if _, err := tx.Exec(ctx, `INSERT INTO search_understandings (query_key, prompt_version, answer, created_at)
VALUES (@key, @version, @answer, @at)
ON CONFLICT (query_key, prompt_version) DO UPDATE SET answer = excluded.answer, created_at = excluded.created_at`,
			pgx.StrictNamedArgs{"key": key, "version": version, "answer": answer, "at": at}); err != nil {
			return fmt.Errorf("insert answer: %w", err)
		}
		return nil
	})
	if err != nil {
		return fmt.Errorf("store answer: %w", err)
	}
	return nil
}
```

`Get` selects `answer` where key, version and `created_at >= @since`. `SavedAmong` selects `listing_id FROM saved_listings WHERE account_id = @account AND listing_id = ANY(@ids)`.

- [ ] **Step 3: Service test** (`search_test.go`) with a fake `llm.Client` that counts calls and answers a canned `Understanding` per query; build the service on a real catalog (the discovery test helpers already build one; read them):
  - a query the fake understands as `category vehicles.bicycle` ranks bicycles first and returns chip `category-0` and `understood`;
  - the same query again does not call the model (cache), and with `Off: ["category-0"]` it does not call either and returns no chip;
  - a fake that errs, or sleeps past 4 s (use a short timeout field on the service set from `domain.ModelTimeout` in production and lowered in the test), still returns the raw-phrase result with no chips;
  - `Sort: nearest` without a position is `ErrPositionRequired`; `Near{Lat: 95}` is `ErrInvalidPosition`; `Cursor: "x"` and a cursor of 600 are `ErrInvalidCursor`;
  - `Category: "vehicles"` (a root) fills `Counts`;
  - a signed-in viewer who saved one listing sees `Saved: true` on it;
  - `Nearby` without a position is `ErrPositionRequired`; with one it orders nearer first.

- [ ] **Step 4: Implement `search.go`** (one method each, top to bottom):

```go
func (d *Discovery) Search(ctx context.Context, viewer *uuid.UUID, in SearchInput) (SearchView, error) {
	origin, err := d.origin(ctx, in.Near)
	if err != nil {
		return SearchView{}, err
	}
	offset, limit, err := window(in.Cursor, in.Limit)
	if err != nil {
		return SearchView{}, err
	}
	sort := in.Sort
	if sort == "" {
		sort = catalogdomain.SortNewest
		if strings.TrimSpace(in.Query) != "" {
			sort = catalogdomain.SortRelevance
		}
	}
	radius := in.RadiusKm
	if (sort == catalogdomain.SortNearest || radius > 0) && origin == nil {
		return SearchView{}, domain.ErrPositionRequired
	}
	if sort == catalogdomain.SortNearest && radius == 0 {
		radius = nearestRadiusKm
	}
	filters := catalogdomain.Filters{
		PriceMin: in.PriceMin, PriceMax: in.PriceMax, Conditions: in.Conditions, OffersOnly: in.OffersOnly,
		Origin: origin, RadiusKm: radius,
	}
	if strings.Contains(in.Category, ".") {
		filters.CategoryCode = in.Category
	} else {
		filters.CategoryRoot = in.Category
	}
	search := catalogdomain.Search{Filters: filters, Sort: sort, Offset: offset, Limit: limit + 1}
	var view SearchView
	if q := strings.TrimSpace(in.Query); q != "" {
		u, understood := d.understand(ctx, q)
		vocab, vocabErr := d.vocabulary(ctx)
		if vocabErr != nil {
			return SearchView{}, vocabErr
		}
		c := domain.Compile(u, q, vocab, origin, d.now(), in.Off)
		d.log.InfoContext(ctx, "search terms", "query", q, "asked", c.Asked, "ran", c.Ran)
		search.Phrases, search.Boosts, view.Chips = c.Phrases, c.Boosts, c.Chips
		if understood {
			view.Understood = u.Understood
		}
	}
	cards, err := d.catalog.Search(ctx, search)
	if err != nil {
		return SearchView{}, fmt.Errorf("search listings: %w", err)
	}
	if len(cards) > limit {
		cards = cards[:limit]
		if next := offset + limit; next < catalogdomain.MaxResults {
			view.NextCursor = strconv.Itoa(next)
		}
	}
	if filters.CategoryRoot != "" {
		if view.Counts, err = d.catalog.Counts(ctx, search, catalogdomain.CountCode); err != nil {
			return SearchView{}, fmt.Errorf("count categories: %w", err)
		}
	}
	if view.Items, err = d.withSaved(ctx, viewer, cards); err != nil {
		return SearchView{}, err
	}
	return view, nil
}
```

The helpers `origin`, `window`, `understand`, `vocabulary` and `withSaved` are each called by both `Search` and `Nearby` (or by `Search` and the screen's Home through `Nearby`), which is the CLAUDE.md condition for a helper:
  - `origin(ctx, near)`: lat/lng both non-zero and in range → point; only one set or out of range → `ErrInvalidPosition`; `near.Commune` → `catalog.CommunePoint`, unknown → `ErrInvalidPosition`; nothing → nil.
  - `window(cursor, limit)`: empty cursor → 0; else `strconv.Atoi`, negative or ≥ `MaxResults` → `ErrInvalidCursor`; limit 0 → `page.DefaultLimit`; clip so offset+limit ≤ 500.
  - `understand(ctx, q) (domain.Understanding, bool)`: `QueryKey`, cache `Get` since `now−CacheTTL`; a hit decodes; a miss calls the model under `context.WithTimeout(ctx, d.modelTimeout)` with `domain.SystemPrompt(categories, now)` and `domain.Schema()`, stores the answer with `Put(..., now, now−CacheTTL)`; any error logs a warning and returns `(Understanding{}, false)`, never an error, since the raw phrase still searches.
  - `vocabulary(ctx)`: categories as a code→name map and `Place` as a closure over `d.catalog.Place` that logs and answers false on an error.
  - `withSaved(ctx, viewer, cards)`: nil viewer → all false; else one `SavedAmong`.

`Nearby(ctx, viewer, near, cursor, limit)`: origin required (`ErrPositionRequired`), window, then `catalog.Search` with `Filters{Origin, RadiusKm: nearbyRadiusKm}`, `Boosts: domain.NearbyBoosts(*origin, now)`, `Sort: SortRelevance`, limit+1 paging, `withSaved`. Constants: `nearestRadiusKm = 50`, `nearbyRadiusKm = 50`.

Service `Deps` gains `Understandings repository.Understandings`, `LLM llm.Client`, `ModelTimeout time.Duration`, `Log *slog.Logger`.

- [ ] **Step 5: Handlers** (`handler/search.go`):

```go
type searchRequest struct {
	Query       string   `json:"-" query:"q"`
	Category    string   `json:"-" query:"category"`
	PriceMin    int64    `json:"-" query:"price_min"`
	PriceMax    int64    `json:"-" query:"price_max"`
	Conditions  []string `json:"-" query:"condition"`
	RadiusKm    int      `json:"-" query:"radius_km"`
	OffersOnly  bool     `json:"-" query:"offers_only"`
	Sort        string   `json:"-" query:"sort"`
	Off         []string `json:"-" query:"off"`
	NearLat     float64  `json:"-" query:"near_lat"`
	NearLng     float64  `json:"-" query:"near_lng"`
	NearCommune string   `json:"-" query:"near_commune"`
	Cursor      string   `json:"-" query:"cursor"`
	Limit       int      `json:"-" query:"limit"`
}
```

`Search` binds, reads the optional caller with `authn.From(r.Context())` (as `catalog/handler/listing_get.go` does), maps conditions to `catalogdomain.Condition`, calls the service and responds 200. `Nearby` binds `near_lat`, `near_lng`, `near_commune`, `cursor`, `limit`. `Register(r, protect, identify)` adds `GET /v1/search` and `GET /v1/feed/nearby` behind `identify`; the saved routes stay behind `protect`. No handler logs the request.

- [ ] **Step 6: Wiring**: `discovery.Mount(d, discovery.Guards{Protect, Identify}, catalog, llm.Client)` returns `service.Service`; `app.go` builds `llm.OpenAI{BaseURL: cfg.LLM.BaseURL, APIKey: cfg.LLM.APIKey, Model: cfg.LLM.Model, HTTP: &http.Client{}}` and passes it. `internal/app/app_test.go` and `e2e/main_test.go` set `cfg.LLM` (the e2e one to the stub).

- [ ] **Step 7: OpenAPI**: `getSearch` and `getNearbyFeed` in `api/paths/discovery.yaml` with every parameter above (`condition` and `off` as `style: form, explode: true` arrays; `sort` enum; `near_lat` −90..90, `near_lng` −180..180), responses 200 `SearchView` and 400 (`BadRequest`, which covers `position_required`, `invalid_position`, `invalid_cursor` and malformed parameters). Schemas `SearchView`, `SearchItem`, `Chip`, `CategoryCount` in `api/schemas/discovery.yaml`; `SearchItem` has no `lat`/`lng`; `distance_km` is `type: integer, minimum: 0`. `security: [{}, {bearerAuth: []}]` as `getListing` has.

- [ ] **Step 8: e2e stub and tests**

`e2e/llm_stub_test.go` serves `/chat/completions`, counts calls per user message, and answers from a map: `"xe dap di lam duoi 3tr"` → `{"understood":"Xe đạp đi làm, dưới 3 triệu","boosts":[{"attr":"phrase","values":["xe đạp đi làm"]},{"attr":"category","values":["vehicles.bicycle"]},{"attr":"price","values":["-3000000"]}],"demotes":[]}`; anything else → `{"understood":"","boosts":[],"demotes":[]}`. `TestMain` starts it before `app.New` and sets `cfg.LLM.BaseURL` to its URL.

`e2e/search_test.go`:
  - `TestSearch`: post two active listings in one commune ("Xe đạp đi làm Asama" vehicles.bicycle 2.5tr, "Đèn xe đạp" sports.accessories 150k); `GET /v1/search?q=xe dap di lam duoi 3tr&near_commune=00004` → 200, the bicycle first, a chip `category-0`, `understood` set, every `distance_km` a whole number; the same query again does not raise the stub's count; with `off=category-0` the chip is gone and the count is unchanged; the response body never contains `"lat"` or `"lng"`, since a search item has no location; signed-in after saving the bicycle, its `saved` is true.
  - `TestSearchRefusals`: `sort=nearest` without a position → 400 `position_required`; `near_lat=95&near_lng=1` → 400; `near_lat=10` alone → 400 `invalid_position`; `cursor=x` → 400 `invalid_cursor`; `q=?` → 200 with no items.
  - `TestSearchCategory`: `category=vehicles` → `counts` holds `vehicles.bicycle`.
  - `TestNearbyFeed`: without a position → 400; with `near_commune=00004` → 200, items present.

- [ ] **Step 9: Run**

Run: `go test -race ./internal/discovery/... ./internal/app/ ./api/ && go test -race ./e2e/ -run 'TestSearch|TestNearby'`
Expected: PASS (e2e filtered runs print the coverage note).

- [ ] **Step 10: Commit**

```bash
git add internal/discovery internal/app api e2e internal/platform/config
git commit -m "feat: search and the nearby feed"
```

---

### Task 8: The Home view

**Files:**
- Create: `internal/screen/service/home.go`, `internal/screen/handler/home.go`
- Modify: `internal/screen/service/service.go` (interface), `internal/screen/handler/handler.go` (route), `api/paths/screen_listing.yaml` or a new `api/paths/screen_home.yaml` + `api/schemas/screen_home.yaml`, `api/openapi.yaml`
- Test: `e2e/screen_home_test.go`

**Interfaces:**
- Consumes: catalog `Categories`, `Counts(…, CountRoot)`; discovery `Nearby`.
- Produces: `Home(ctx, reader *uuid.UUID, near discoverysvc.Near) (HomeScreen, error)` with

```go
type HomeCategory struct {
	Code        string `json:"code"`
	DisplayName string `json:"display_name"`
	Count       int    `json:"count"` // active listings under the root
	Children    []catalogdomain.Category `json:"children"`
}
type HomeScreen struct {
	Categories []HomeCategory             `json:"categories"`
	Nearby     discoverysvc.SearchView    `json:"nearby"`
}
```

- [ ] **Step 1: e2e test** `TestHomeScreen`: with `near_commune=00004` → 200, `categories` holds the 9 roots in tree order, the root of a posted active listing counts at least 1, `nearby.items` non-empty; without a position → 400 `position_required`; an invalid commune → 400 `invalid_position`.
- [ ] **Step 2: Run** → FAIL (404, no route).
- [ ] **Step 3: Implement** `Home`: read the tree, count roots with `catalog.Counts(ctx, catalogdomain.Search{}, catalogdomain.CountRoot)`, fold subcategories under roots in tree order, then `saves.Nearby(ctx, reader, near, "", 0)`; return its error as is (so position errors reach the client). Handler `GET /v1/screens/home` behind identify, binding `near_lat`, `near_lng`, `near_commune`. The screen's `Deps.Saves` is the discovery service, which now has `Nearby`.
- [ ] **Step 4: Spec** the path and `HomeScreen` (referencing `SearchView` from discovery) with 200 and 400.
- [ ] **Step 5: Run** — `go test -race ./internal/screen/... ./internal/app/ && go test -race ./e2e/ -run TestHomeScreen` → PASS.
- [ ] **Step 6: Commit** `git commit -m "feat: the Home view"`.

---

### Task 9: Architecture record and the full run

**Files:**
- Modify: `ARCHITECTURE.md` (Infrastructure, Module layout's planned paragraph, Catalog, Discovery, Screen, Tables), `tmp/gen_depguard.py` only if a new module or layer appeared (none should).

- [ ] **Step 1: ARCHITECTURE.md** gains a `### Search` section recording, as facts with "decided 2026-10-27": ParadeDB 0.26.3 on Postgres 18 and why 18 (pg_search builds for 15 to 18; back to 19 when it supports it); catalog owns the index and the structured search, discovery the understanding and cache; the model's schema and the rule that it never writes weights; the raw phrase at 0.5; resolution and the `asked`/`ran` log line; boosts as constant scores in one query, the phrase `must`, rings for distance and freshness; the starting weights in BM25 points and that they await a sample-query set; the listing point (blur in the handler, 30 km check, kept on edit, replaced on a commune change, never returned); the searcher's position never stored or logged; the cache with prune-on-write; `distance_km` truncated to whole km; results stop at 500. In Catalog, replace "the seller's position is never stored" with a pointer to Search. In Infrastructure, change the Postgres version. Run the prose checker on the file.

- [ ] **Step 2: Full run**

Run: `GOFLAGS=-count=1 make test > tmp/make-test.log 2>&1; tail -5 tmp/make-test.log`
Expected: every package ok, the e2e coverage check silent, `0 issues.` from golangci-lint.

- [ ] **Step 3: Commit**

```bash
git add ARCHITECTURE.md
git commit -m "docs: search decisions"
```
