# Design: server2 search and the nearby feed

Date: 2026-10-27.
Status: decided in conversation, question by question. When the work
lands, the decisions below go into `~/shopnexus/server2/ARCHITECTURE.md`.

## Scope

A person finds listings: by text, through an LLM that turns the query into
weighted boosts, with filters and sorts they pick themselves; by category;
and on Home through "Gần bạn". Search history, followed searches, price
alerts, the "Dành cho bạn" feed and vector search come later. The old
server's search (`server` branch `main`, `catalog/domain/search.go`,
`service_search.go`, `adapter/postgres/search.go`) is the starting point:
its rules on what the model may say are kept, and its retrieval (twelve
ANN legs fused by RRF, predicates as rank-1 contributions) is replaced by
one BM25 query.

## Decisions

| Question | Decision |
|---|---|
| Scope | Text search, filters, sorts, category browsing, the nearby feed. |
| Engine | ParadeDB `pg_search` 0.26.3 on Postgres 18 (`paradedb/paradedb:0.26.3-pg18`). |
| Postgres version | Down from 19rc1 to 18, since pg_search builds for 15 to 18; back to 19 when ParadeDB supports it. |
| Semantic search | Later; the image ships pgvector for it. |
| Diacritics | No folding: the LLM writes the query back with diacritics. |
| Where the LLM runs | On server2, through an OpenAI-compatible endpoint. |
| What the LLM may boost | Phrases (title, description, specs), category, price, condition, a place, nearness to the searcher, freshness, offers allowed. |
| Listing position | A blurred point, server-only, from the seller's GPS when given; the commune's point otherwise. |
| Searcher position | `near_lat`/`near_lng` when the app has GPS, else `near_commune`; never stored or logged. |
| Filters and sorts | Category (root or sub), price range, conditions, radius, offers only; relevance, newest, nearest, price up, price down. Active listings only, so no reserved ones. |
| Nearby feed | Distance and age mixed. |
| What the person sees of the model | A sentence and chips they can turn off. |
| Cache | A Postgres table, 7 days, keyed by the normalized query and the prompt version. |

## API (module discovery)

- `GET /v1/search`, signed in or not. Parameters: `q`, `category`,
  `price_min`, `price_max`, `condition` (repeatable), `radius_km`,
  `offers_only`, `sort` (`relevance`, `newest`, `nearest`, `price_asc`,
  `price_desc`), `off` (repeatable chip id), `near_lat` and `near_lng`, or
  `near_commune`, `cursor`, `limit`.
  - With `q` the default sort is `relevance`; without it, `newest`, and
    the call is browsing. A `category` filter is the category page.
  - `nearest` and `radius_km` need a position: 400 `position_required`.
    `nearest` without `radius_km` uses 50 km.
  - Response: `{items, next_cursor, understood, chips, counts}`.
    - An item is `{id, title, price, cover_thumb_url, condition,
      allow_offers, commune, distance_km, saved}`. `distance_km` is a whole
      number of kilometres, 0 meaning under 1 km, present only when the
      request gave a position. `saved` is false when signed out.
    - `understood` and `chips` are present when the model answered. A chip
      is `{id, kind, label}`; `off=<id>` drops that signal on the next call,
      which reads the cached answer and does not call the model again.
    - `counts` is `[{category, count}]` for the subcategories of a root
      `category` filter, under the other filters.
  - `next_cursor` is opaque; results stop at 500.
- `GET /v1/feed/nearby?near_…&cursor=`, signed in or not: the nearby feed
  as the same items. A position is required (400 `position_required`).
- `GET /v1/screens/home?near_…` (module screen): the category tree with
  each root's count of active listings, and the first page of the nearby
  feed.
- `POST /v1/listings` and `PUT /v1/listings/{id}` take an optional
  `gps {lat, lng}`. A point farther than 30 km from the chosen commune's
  point is 422 `invalid_listing` on field `gps`. The communes table holds
  points, not boundaries, so "inside the commune" is checked as that
  distance; boundaries would need the 3,321 polygons and PostGIS.

## Listing position

- The handler blurs the point before the use case sees it: a random offset
  of at most 500 m, then rounding to a 0.01° grid (about 1.1 km). The exact
  point never reaches the Restate journal, the database or a log.
- `listings.lat` and `listings.lng` hold the blurred point, or the
  commune's point when the seller gave no GPS. An edit without `gps` keeps
  the stored point unless the commune changes, which replaces it with the
  new commune's point.
- No response carries `listings.lat` or `listings.lng`. Listings keep
  `location` with the commune's point, as now. Distances are rounded as
  above.
- No log line or error carries `near_lat`, `near_lng` or a GPS point. The
  request trace already names the route pattern and never the URL, so the
  query string stays out of it.

## Query understanding

- With `q` and no cached answer, the service calls the model with the
  query, the category tree (codes and names), the conditions and today's
  date, asking for JSON in a fixed schema (structured output):

  ```
  {understood, boosts: [{attr, values}], demotes: [{attr, values}]}
  attr: phrase | category | price | condition | place | near_me | fresh | offers
  ```

  `values` is a priority order. `price` takes `{gte, lte}`; `place` takes a
  province or commune name; `near_me`, `fresh` and `offers` take `true`.
  The model never writes a weight.
- Each value is resolved: a category must be a code of the tree, a place a
  name in `provinces` or `communes`, a condition one of the enum. A value
  that does not resolve is dropped. One log line holds what the model asked
  for and what ran.
- The raw query is always a `phrase` at weight 0.5, unless the model named
  it as a boost. A model error, or no answer within 4 seconds, leaves the
  raw phrase alone, with no `understood` and no chips.
- The cache is `search_understandings (query_key, prompt_version, answer
  jsonb, created_at)`, primary key `(query_key, prompt_version)`.
  `query_key` is the query lowercased with whitespace collapsed. Reads
  ignore rows older than 7 days, and the transaction that stores a new
  answer deletes them, so no scheduler is needed. The table records no
  account.

## Ranking

One ParadeDB query per page:

```
must:    status active, the person's filters
must:    at least one phrase matches          (only with q)
should:  phrase    title ×2, description and specs ×1, fuzzy distance 1 on words of 5+ letters
         category  0.6    price  0.6    condition  0.3    offers  0.3
         near_me or place  rings: ≤2 km 0.5, ≤5 km 0.3, ≤15 km 0.15
         fresh     published ≤3 days 0.4, ≤7 days 0.2
demote:  the same attributes with negative weights
```

- A signal's second and third values count 0.5 and 0.33 of its first.
  Every weight is a constant in `discovery/domain`, to be measured against
  a set of sample queries.
- Rings are range queries on `lat`, `lng` and `published_at`, as boxes
  around the point, so distance and freshness score inside the index.
- The phrase `must` keeps the old rule: boosts move listings that matched
  the text and never bring in one that did not.
- If ParadeDB takes no negative boost, a demote becomes a positive boost on
  the listings outside its condition, which orders the same.
- `newest`, `price_asc` and `price_desc` order by the indexed fields after
  the filters. `nearest` orders by distance inside the radius.
- The nearby feed is the same query with no phrase: `must` holds status
  active and 50 km; the score is the distance and freshness rings.

## Data and infrastructure

- `docker-compose.yml` and `docker-compose.test.yml` run
  `paradedb/paradedb:0.26.3-pg18`. A migration runs `CREATE EXTENSION
  pg_search`, which brings `vector`.
- `listings` gains `lat`, `lng` (filled for existing rows from their
  commune) and `category_root`, generated from `category_code`. One
  ParadeDB index covers `title`, `description`, `specs` and the fields
  `category_code`, `category_root`, `price`, `condition`, `allow_offers`,
  `status`, `published_at`, `lat`, `lng`. The index is transactional, so
  a listing is searchable once its write commits, with no sync worker.
- Configuration, all required: `LLM_BASE_URL`, `LLM_API_KEY`, `LLM_MODEL`.
  A new `internal/provider/llm` calls chat completions with a JSON schema.

## Tests

- Domain: resolution drops unknown values; position weights; the raw
  phrase is always there; the blur moves a point by at most about 1.3 km,
  lands on the grid, and differs between two calls.
- Repository on ParadeDB: each boost changes the order; a narrow filter
  still returns its matches; reserved listings never appear; rings rank
  nearer and newer first.
- LLM: an httptest server with canned answers; an error or a timeout
  falls back to the raw phrase.
- e2e: every declared status; `off` does not call the model again;
  `distance_km` is always a whole number; no response carries a listing's
  `lat` or `lng`.
