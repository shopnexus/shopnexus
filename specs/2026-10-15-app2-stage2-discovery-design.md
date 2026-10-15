# Design: app2 stage 2, Khám phá

Date: 2026-10-15
Status: draft. The user's standing instruction is to keep building, so this
spec goes straight to a plan; the decisions marked as rulings are the ones to
review.

## Goal

Stage 2 builds the rest of the discovery flow on the stage 1 foundation:
Search before typing, Search results, Danh mục, Category, Người bán, Đã lưu
and Thông báo, and the pieces several screens share: the long-press card menu
with its similar sheet, the report sheet and the photo search sheet. The
screens are designed in `app2/.superdesign/` (rules in `design-system.md`,
sample data and interactions in `tools/build_*.py` and `tools/common.py`),
and they run on fake data with real interactions.

Stage 1's decisions hold: Android only, Kotlin, Compose with material3
1.5.0-beta01, Navigation 3, Hilt, ViewModel + `StateFlow`, fake repositories
over one `FakeWorld`, JVM tests with Robolectric and Roborazzi at a
zero-pixel threshold. The repository interfaces stay the API contract for the
Go server.

## Rulings on the mockups

The mockups are prototypes, and some of their behaviour exists only because a
prototype has one listing page and no server. The app follows the product
behaviour that `design-system.md` describes:

1. Every listing opens Listing detail. The mockups open a page only for the
   iPhone 13 Pro and show "Bản mẫu chỉ có trang iPhone 13 Pro" or, in
   Category, a summary sheet for the rest. The fake builds a detail for
   every listing in the pool from its summary, so the summary sheet is not
   built. Cost if wrong: about 34 generated details to keep in line with
   their cards.
2. Every listing has a seller. The mockups name a seller only for Tuấn
   Kiệt's six listings. The fake assigns the other listings to six sellers
   named after people the mockups already use (Ngọc Hân, Hoàng Nam, Gia
   Bảo, Mai Anh, Đức Trí, Thu Hà), with tiers and stats in a fixture. Each
   has a Người bán page; only Tuấn Kiệt has reviews.
3. One listing has one id, one title and one price everywhere. The pool in
   `common.py` and the stage 1 Home fixture describe the same items with
   different ids and, on Search results and Người bán, longer titles. The
   pool keeps stage 1's ids (`l-<photo id>`, and `p-iphone13`) and the
   longest title the mockups give an item.
4. Search is real over the pool. The mockups return results only for "xe
   đạp đi làm dưới 3 triệu" and show a preview notice for anything else.
   The fake reads every query with the same keyword tables and filters the
   pool, so "iPhone 13 Pro" or "sofa nhung" return their listings. The
   result count is the number of matching listings ("8 tin" for the seeded
   query, where the mockup says "128 tin").
5. The controls the Search results mockup leaves static (pickers, sort,
   map, "Theo dõi") work as `design-system.md` describes; the sheets they
   open follow the Category filter sheet's layout. The map opens a
   placeholder: no stage has a map yet.
6. Prototype notes are not built: the "Bản thiết kế · … dữ liệu mẫu."
   footers, "Bản mẫu …" snackbars and the summary sheet's footnote. The
   photo search sheet keeps a note, because it is true of the app: it does
   not recognise photos.
7. Category "Gần bạn nhất" sorts by distance, as its label says; the mockup
   keeps fixture order.
8. "So sánh" appears on any Đã lưu group whose listings on sale are two or
   more of one kind, as `design-system.md` says; the mockup limits it to
   bikes and phones. A kind-specific row (Pin, Loại xe) appears only when
   the listings carry that fact, and the model's pick only when the fixture
   has one.
9. In the compare sheet, "Loại xe" is never marked: a bike type has no best
   value. The mockup marks Giant Escape 3 from a hand-set score.
10. Back goes back. The mockups hard-wire Người bán's back to Listing detail
    and Thông báo's to Home.
11. Read marks, alerts, follows, hidden listings and blocks persist in the
    fake for the session; the mockups keep them per page.
12. "Báo cáo" in the card menu and on Người bán opens the report sheet with
    its four reasons; "Chặn" asks first. The mockups show a snackbar
    straight away.

## Scope

| Built in stage 2 | Opens a placeholder |
|---|---|
| Search before typing: browse state, query list, history with undo, need tiles | |
| Search results: query chips, picker chips, filter sheet, sort sheet, price estimate, "Theo dõi" | the map |
| Danh mục: category grid, popular tiles, subcategories | |
| Category: tabs where the fixture defines brands, filter sheet, sort by distance | |
| Người bán: header, follow, chat, tier sheet, Đang bán, Đánh giá, menu | |
| Đã lưu: saved searches and alerts, saved listings with changes, unsave with undo, compare sheet, price-cut switch | |
| Thông báo: groups, filters, read marks, mark all read with undo | rows about stage 3 and 5 screens, and "Cài đặt thông báo" |
| Card long-press menu on every card, similar sheet, report sheet, price alert | |
| Photo search sheet with the Photo Picker and the camera | recognising the photo |
| Chat's overflow menu: Trang người bán, Báo cáo, Chặn | |
| Generated Listing detail for every pool listing | Nhắn tin and Trả giá on a listing without a deal (stage 3) |

Tôi stays a stage 5 placeholder; its placeholder gains two rows, "Đã lưu" and
"Thông báo", so both screens are reachable from the tab as in the mockups.

## Modules

| Module | Holds | May depend on |
|---|---|---|
| `:feature:search` | Search before typing, Search results, the filter and sort sheets | `:core:*` |
| `:feature:catalog` | Danh mục, Category, the category filter sheet | `:core:*` |
| `:feature:seller` | Người bán, the tier sheet | `:core:*` |
| `:feature:saved` | Đã lưu, the compare sheet | `:core:*` |
| `:feature:notifications` | Thông báo | `:core:*` |
| `:core:ui` (new) | pieces several features share that need data: `CardActions`, the card menu host, the similar sheet, the report sheet, the photo search sheet | `:core:designsystem`, `:core:data`, `:core:navigation` |

`:core:designsystem` keeps components that take plain values and callbacks:
the card menu's lift and layout, filter and picker chips, the floating
toolbar, the tier shape and chip, radio rows. `:core:ui` connects them to
repositories, so a feature adds the card menu to its grid with one
`CardActions` and one event type. Listing detail's report sheet moves to
`:core:ui`.

## Domain model and API contract (`:core:model`)

New and changed types, all `@Serializable`, each screen read in one call.

- `ListingKind`: PHONE, COMPUTER, WATCH, AUDIO, CAMERA, BIKE, MOTORBIKE,
  FURNITURE, FASHION, APPLIANCE, OTHER. It drives "Tìm đồ tương tự", the Đã
  lưu groups and "So sánh".
- `ListingFacts`: the comparable facts of a listing that are not on its
  card: `kind`, `district`, `sellerId`, `sellerTier`, `battery: Int?`,
  `bikeType: String?`, `sold`, `estimate: PriceRange?`.
- `SearchEntry`: district line, recent searches (`RecentSearch`: query,
  title, detail, photo), need tiles (`NeedTile`: title, query, photo).
- `SearchQuery`: text, the chips the person turned off, picker values
  (`conditions: Set<Condition>`, `maxDistanceKm: Int?`, `maxPrice: Vnd?`,
  `negotiableOnly`), and `ResultSort` (RELEVANCE, NEAREST, PRICE_LOW,
  PRICE_HIGH).
- `SearchResults`: `QueryChip`s the model read (label, kind of filter),
  count, the price estimate (`PriceRange?`), listings, whether the query is
  followed.
- `CatalogRoot`: the eight `CategoryEntry`s, popular tiles (`PopularTile`:
  title, count, photo, category key), and per category its subcategories
  (`Subcategory`: name, icon, count).
- `CategoryPage`: entry, district, tabs (`BrandTab`: key, label), listings
  with their brand key.
- `SellerProfile`: `SellerSummary`, district, verification (`phone`,
  `idCard`), public facts (deals done, cancellations, COD refused of COD
  orders, records and how they ended), listings, `Review`s (name, stars,
  age, text, item, item photo), praise chips, following, the open deal with
  this seller if there is one, and whether the person blocked them.
- `SavedPage`: saved searches (`SavedSearch`: id, query, new count, area,
  alert on), saved listings (`SavedListing`: summary, facts, price when
  saved), the price-cut switch, and the model's compare picks per kind
  (`ComparePick`: listing, headline, reason).
- `Notification`: id, `NotificationKind` (DEAL, PRICE, ACCOUNT), icon,
  `Tone` (DEAL, TRUST, CALM), text, time, unread, `NotificationTarget`
  (Chat(dealId), Saved, Search(query), Later(stage, title)).
- `HomeFeed.unreadNotifications` stays, and the fake derives it from the
  notifications.

Repository interfaces in `:core:data`:

| Interface | Reads | Commands |
|---|---|---|
| `SearchRepository` | `entry()`, `results(query)` | `remember(text)`, `clearHistory()` returning what it cleared, `restoreHistory(items)`, `follow(text, on)` |
| `CatalogRepository` | `root()`, `category(key)` | |
| `SellerRepository` | `profile(id)` | `setFollowing(id, on)`, `setBlocked(id, on)`, `report(id, reason)` |
| `SavedRepository` | `saved()` | `setSearchAlert(id, on)`, `setPriceCutAlerts(on)` |
| `NotificationRepository` | `notifications()` | `markRead(id)`, `markAllRead()` returning the ids it changed, `markUnread(ids)` |
| `ListingRepository` (grows) | `similar(id)` (source and candidates) | `setPriceAlert(id, at)`, `setHidden(id, hidden)` |

Hidden listings and listings of blocked sellers drop out of every feed,
result list and rail; the listing's own page still opens from a saved row or
a deep link.

## Discovery rules (`:core:domain`)

Pure functions with unit tests. The fakes answer with them, and a backend
can test its implementation against the same tables.

| Function | Rule |
|---|---|
| `foldVi(text)` | lower case, Unicode NFD with combining marks removed, đ → d, outer spaces trimmed, inner runs collapsed; "Xe Đạp  Đi làm" → "xe dap di lam" |
| `suggestions(input, recent, phrases)` | empty input: the recent searches, newest first; otherwise up to five phrases whose folded text contains the folded input, in their fixture order |
| `similarListings(source, pool, filter)` | same kind, never the source, never a sold, hidden or blocked listing; Rẻ hơn keeps cheaper ones, Gần hơn closer ones, Như mới NEW and LIKE_NEW; sorted by the price difference, ties in pool order; at most six |
| `compareTable(listings)` | rows Giá, Tình trạng, Pin (when every column has one), Loại xe (when every column has one), Cách bạn, Người bán; the single best value in a row is marked (lowest price, best condition NEW > LIKE_NEW > USED, highest battery, shortest distance, highest tier); a tie marks none; Loại xe is never marked |
| `filterListings(listings, filter)` | conditions, maximum distance (inclusive), maximum price (below it), negotiable only, brand; all optional and combined |
| `sortListings(listings, sort)` | RELEVANCE keeps the given order; NEAREST by distance; PRICE_LOW and PRICE_HIGH by price; ties keep the given order |
| `notificationGroups(items, now, zone)` | Hôm nay, Hôm qua, Tuần này (the five days before yesterday), Cũ hơn; newest first; empty groups dropped |
| `notificationTime(at, now, zone)` | "14:10" for today and yesterday, the weekday ("Thứ Hai" … "Chủ nhật") within the week, else "12/10" |

The query reader is not a domain rule: it stands in for the model that reads
a query, so it lives in the fake. It finds a kind ("xe đạp" → Xe đạp), a
price ceiling ("dưới 3 triệu" → Dưới 3 tr) and a use ("đi làm", "đi phố" →
Đi phố) with keyword tables, and the fake filters the pool with what it
read.

## Fake data (`:core:data`)

- `pool.json` holds the listings of the mockups (the 35 of `POOL` and the
  ones only Home has) as `ListingSummary` with `ListingFacts`; `home.json`
  lists their ids. `sellers.json` holds the seven sellers with their
  public facts; `reviews.json` Tuấn Kiệt's four reviews and praise chips;
  `search.json` the history, need tiles, suggestion phrases and the
  keyword tables; `catalog.json` the categories, tiles, subcategories and
  phone brands; `saved.json` the two saved searches, the twelve saved
  listings with their saved-at prices and the two compare picks;
  `notifications.json` the eight notifications.
- `FakeWorld` gains the pool, the generated details, sellers, history,
  followed searches, saved-at prices, alerts, hidden listings, blocks,
  follows and notifications. The saved set covers both Home's saved hearts
  and Đã lưu's twelve, so a heart on any screen shows on every other.
- A generated `ListingDetail` has the card's photo, title, price, condition,
  district and distance, the price insight and estimate from the pool, no
  specs or declared marks, an empty description, the paths the price allows
  (COD up to 5.000.000 ₫), the seller from its facts, the similar listings
  from `similarListings`, the two question chips and offer suggestions from
  `offerRange`. The iPhone 13 Pro keeps its hand-written detail.
- Times are instants around `Fixtures.NOW` (Thursday 15/10/2026, 15:10).

## Navigation

New routes in `:core:navigation`:

| Route | Opened from |
|---|---|
| `SearchRoute` | the Home search bar, the search buttons on Danh mục and Category |
| `SearchResultsRoute(query: String, sort: ResultSort = RELEVANCE)` | a submitted query, a hero slide, a rail's arrow, a saved search, a notification, a sold saved listing |
| `CategoryRoute(key: String)` | Danh mục, the Home category row |
| `SellerRoute(id: String)` | the seller row on Listing detail, Chat's menu |
| `SavedRoute` | the Tôi placeholder, the price-cut notification |
| `NotificationsRoute` | the Home bell, the Tôi placeholder |

`CategoryRoute` implements a new `InTab` interface with `tab =
CategoriesRoute`; `Navigator.push` switches to that tab before pushing, so a
category opened from Home shows with Danh mục active and back returns to
Danh mục, as the mockup says. `CategoriesRoute` stops being a placeholder.
Deep links gain `shopnexus://seller/{id}`, which Người bán's share uses. A
`PlaceholderRoute` with stage 0 reads "Màn này làm sau." for the map.

Home's remaining placeholders go to their screens: the search bar to
`SearchRoute`, the camera to the photo search sheet, the bell to
`NotificationsRoute`, the category row to `CategoryRoute`, each hero slide to
`SearchResultsRoute` with a query in the fixture, "Gần bạn" to
`SearchResultsRoute("", NEAREST)` and "Gợi ý cho bạn" to
`SearchResultsRoute("")`. An empty query searches the whole pool; its field
reads "Tất cả tin quanh bạn". Listing detail's seller row goes to
`SellerRoute` and its "Tin tương tự" arrow to the similar sheet.

## Shared pieces

### Listing grids

Every grid of cards (Home "Gợi ý cho bạn", Search results, Category, "Đang
bán", the similar sheet) is a `LazyVerticalGrid` with two columns 12 dp
apart and 24 dp between rows, with full-span items for what surrounds it.
Each card is an item keyed by listing id with `animateItem()`, so when
"Không quan tâm" removes a card its neighbours slide into the gap. Home moves
from its `LazyColumn` to such a grid; rails stay `LazyRow`s.

### Card long-press menu

As `design-system.md` describes it. Pressing shrinks the photo to 95 % over
the 450 ms hold; moving more than 8 dp first cancels the press, so scrolling
stays free. At 450 ms the screen dims (black at 30 %) and a copy of the card
lifts in a full-screen popup at the card's bounds: it slides fully into view
if it was partly off screen, grows to 104 %, and sits on a `surface` plate
with shadow level 3. Below it, a connected row of three 64 dp icon buttons
(Lưu or Đã lưu, Báo giá, Chia sẻ) and a list of 48 dp items (Tìm đồ tương
tự, Không quan tâm, Báo cáo), in groups with 16 dp outer and 4 dp inner
corners, 2 dp apart. Still holding, sliding onto an item and letting go
chooses it; letting go elsewhere leaves the menu open for a tap; the scrim
and back close it; the release never opens the listing. TalkBack gets the
six items as custom actions on the card, and a right click or Shift+F10 on
a focused card opens the menu. Under reduced motion the card lifts without
the shrink and the grow.

| Item | Effect | Snackbar |
|---|---|---|
| Lưu | toggles the heart | "Đã lưu tin" / "Đã bỏ lưu" |
| Báo giá | turns an alert at the current price on or off | "Báo khi giá dưới 10,9 tr ₫" / "Đã tắt báo giá" |
| Chia sẻ | the Android share sheet with title, price and `shopnexus://listing/{id}` | |
| Tìm đồ tương tự | the similar sheet | |
| Không quan tâm | hides the listing everywhere | "Bạn sẽ thấy ít tin như này hơn", with "Hoàn tác", which puts the card back in its place |
| Báo cáo | the report sheet | "Đã gửi báo cáo. Cảm ơn bạn." |

### Similar sheet

Title "Tương tự". The source as a 48 dp thumbnail with title, price and
distance; filter chips Tất cả, Rẻ hơn, Gần hơn, Như mới (Tất cả on open); a
grid of up to six cards from `similarListings`, with hearts that save for
real; the empty line "Chưa có tin phù hợp quanh bạn". A card opens Listing
detail.

### Photo search sheet

Every camera button (Home, Search before typing, Danh mục, Category) opens
it: "Tìm bằng ảnh", an upload area (`surfaceContainer`, 28 dp corners, a 56
dp `secondaryContainer` icon tile with `image_search`, "Chọn một ảnh rõ món
đồ"), "Chụp ảnh" (tonal) and "Chọn ảnh" (primary). "Chọn ảnh" opens the
Photo Picker; "Chụp ảnh" the camera through `TakePicture` into the app's
cache. A picked photo replaces the upload area, the primary button reads
"Đổi ảnh", and the photo stays when the sheet closes and opens again. The
note with the info icon reads "Chưa nhận diện ảnh. Ảnh chỉ nằm trên máy
bạn."

## The screens

### Search before typing

No navigation bar. Back, then the 56 dp field ("Bạn đang tìm món gì?", a
clear button while text is present, the camera); "Quanh Bình Thạnh,
TP.HCM"; the photo-search panel ("Tìm bằng ảnh", "Chọn ảnh", the example
photo with `primary` viewfinder corners, 104 dp below 380 dp of width,
otherwise 128 dp); "Tiếp tục tìm" with the recent rail (172 dp items, the
third peeking) and "Xóa", which clears the history and offers "Hoàn tác";
"Khám phá theo nhu cầu" with four need tiles (1.55 : 1, 20 dp corners).

Focusing the field shows the query list: "Tìm gần đây" with the history, or
"Gợi ý tìm kiếm" with up to five suggestions while typing (history rows with
`history`, suggestions with `search`, each with a `north_west` arrow that
puts the text in the field), and "Nhấn Tìm để tiếp tục." when nothing
matches; "Chưa có tìm kiếm gần đây" when the history is empty. A recent
item, a suggestion or a need tile puts its query in the field without
searching; the keyboard's search action or a row's text searches. Searching
remembers the query and opens Search results. Back from the query list
returns to the browse state; back again leaves.

### Search results

No navigation bar. The filled query field (back, the query, clear back to
Search before typing). The chip row: "Bộ lọc" (outlined, `tune`; the filter
sheet), the query chips the model read (selected, the sparkle in place of
the check; a tap turns one off and the results widen), then "Tình trạng",
"Khoảng cách" (picker chips with a chevron, showing their value once set)
and "Trả giá được". The result line "8 tin · Phù hợp nhất", the price
estimate line ("Giá tham khảo 1,6 – 2,4 tr ₫") when the fixture has one for
the query's kind, and the grid. The floating toolbar: "Xem trên bản đồ"
(placeholder), "Sắp xếp" (the sort sheet: Phù hợp nhất, Gần bạn nhất, Giá
thấp đến cao, Giá cao đến thấp), and "Theo dõi" (primary, bell), which
follows the query, turns into "Đang theo dõi" (tonal, check) and adds it to
Đã lưu; the snackbar says "Sẽ báo khi có tin mới" with "Hoàn tác". No
results: "Chưa có tin phù hợp với tìm kiếm này." with "Bỏ bộ lọc" when a
filter is set.

The filter sheet "Lọc tin đăng" holds Tình trạng (three check rows),
Khoảng cách (Tất cả khu vực, Trong 3 km, Trong 5 km, Trong 10 km), Ngân sách
(Tất cả mức giá, Dưới 5 triệu, Dưới 10 triệu, Dưới 15 triệu), the "Trả giá
được" switch, and "Xem kết quả". A picker chip opens the sheet scrolled to
its section.

### Danh mục

The Danh mục tab root, with the navigation bar. "Danh mục", search and
camera; the eight categories in a four-column grid of 64 dp MaterialShapes
(the Home row's shapes). Choosing one fills its shape with
`primaryContainer`, turns it 45° on the spatial spring and colours its label
`primary`; choosing it again clears it. With none chosen: "Phổ biến quanh
bạn" and four photo tiles (1.25 : 1, 20 dp corners) with name and count; a
tile chooses its category. With one chosen: its name with the arrow circle
to Category, and its subcategories as a grouped list (icon, name, count,
chevron), each opening Category.

### Category

Inside the Danh mục tab, with the navigation bar and Danh mục active. A 64
dp app bar (back, the name, search, camera); "Quanh Bình Thạnh, TP.HCM";
tabs from the fixture ("Tất cả", "iPhone", "Samsung", "Khác" for Điện
thoại; a category without brands has no tab row); the filter icon button at
the end of the tab row (or of the result line), in `secondaryContainer`
while a budget or distance is set, opening "Lọc tin đăng" with Ngân sách and
Khoảng cách; "8 tin · Gần bạn nhất"; the grid sorted by distance. The first
photo starts within 240 dp of the top. No listings: "Chưa có tin phù hợp
với bộ lọc này." with "Bỏ bộ lọc", or "Chưa có tin nào trong mục này." when
no filter is set.

### Người bán

No navigation bar. Back, share (the share sheet with
`shopnexus://seller/{id}`), and the menu (Báo cáo, Chặn). Centred: the 96
dp avatar, the name in `headlineSmall` with the verified icon, the tier
chip, three icon facts (district, "Từ 2023", "SĐT · CCCD"), the three stats
(4,9 ★ / 32 đánh giá, 14 / Đã bán, 10 phút / Trả lời), "Theo dõi"
(primary; "Đang theo dõi" tonal after, with "Đã theo dõi Tuấn Kiệt" and
"Hoàn tác") and the tonal chat button ("Nhắn tin cho Tuấn Kiệt"), which
opens the open deal's chat or the stage 3 placeholder. The tier chip opens
the tier sheet: the tier shape and name, the seven public facts with their
icons, and "Tính từ 12 tháng gần nhất". Tabs "Đang bán · 6" (the grid) and
"Đánh giá · 32": "4,9" with "/5" one size down and five stars, sparkle +
"Hay được khen" with the praise chips, and the reviews (initial avatar,
name, stars, age, text, a 24 dp photo with the item bought). A seller
without reviews shows "Chưa có đánh giá". "Chặn" asks "Chặn Tuấn Kiệt?"
("Bạn sẽ không thấy tin của người này nữa.", "Chặn", "Hủy"); then the
snackbar "Đã chặn Tuấn Kiệt" with "Hoàn tác".

### Đã lưu

No navigation bar. Back and "Đã lưu"; group headers in `titleSmall` /
`primary`. "Tìm kiếm": each saved search with its query and either "4 tin
mới · Bình Thạnh · 5 km" in `primary` or "Chưa có tin mới · TP.HCM", and a
bell that turns its alert off ("Đã tắt thông báo cho tìm kiếm này") and on
("Sẽ báo khi có tin mới"); a row opens Search results. Then the saved
listings by group (Xe đạp, Điện thoại, Nội thất, Đồ điện tử, Thời trang,
Khác): 88 dp rows with the 64 dp photo, title, price in `titleMedium`,
condition and distance, a filled `primary` heart, and beside the price what
changed since saving: a down arrow and the cut ("300k") or the price insight
("Rẻ hơn 9%"), in `tertiary` as all price talk is. A sold listing shows
"Đã bán" and "Xem đồ tương tự" and opens Search results for its kind. The
heart unsaves: the row collapses, "Đã bỏ lưu" offers "Hoàn tác", which puts
it back in its place. Empty: the 96 dp Cookie9Sided around a heart, "Chưa
lưu tin nào" and "Khám phá" (to Home). Last: the switch "Báo khi tin đã lưu
giảm giá".

"So sánh" (tonal, `compare_arrows`) in a group header opens the compare
sheet: one column per listing on sale (photo, title), the rows of
`compareTable` with a label and icon above the values, the best value in
`primary` with a 6 dp dot; under the table, sparkle + the pick ("iPhone 13
Pro đáng tiền nhất"), its reason, and "Nhắn người bán" (the chat with that
seller, or the stage 3 placeholder). Unsaving a listing removes its column
and the marks are worked out again; the pick hides when its listing is gone.

### Thông báo

No navigation bar. Back, "Thông báo" with "4 chưa đọc" under it, "Đánh dấu
đã đọc tất cả" ("Đã đánh dấu đã đọc" with "Hoàn tác", which restores the
same unread set) and "Cài đặt thông báo" (stage 5 placeholder). Chips Tất cả,
Giao dịch, Giá và tin mới, Tài khoản; groups from `notificationGroups`; rows
with the 40 dp circle in the event's tone (`tertiaryFixed` for an offer or a
price cut, `primaryContainer` for a deal step, `secondaryContainer` for the
rest), the text in `bodyLarge`, the time, and a dot while unread. A row
marks itself read and opens its target; the Home bell's count follows.
Empty filter: "Chưa có thông báo nào ở mục này".

## State and errors

As in stage 1: one ViewModel per screen with `StateFlow<XxxUiState>` and
`onEvent(XxxEvent)`, one-off effects through a `Channel`. A failed read shows
the error state with "Thử lại". A failed command rolls back its optimistic
change (a heart, a hidden card, a follow, a read mark, an alert) and shows
"Chưa lưu được. Thử lại". Every "Hoàn tác" restores the exact previous state,
including the item's position. The typed query, the chosen filters, the open
sheet and the chosen category survive recreation through `SavedStateHandle`.

## Accessibility

Touch targets of at least 48 dp; a content description on every icon-only
control; the card menu's items as custom actions; tabs, chips, bells and
switches with their state; group headers in Đã lưu and day headers in
Thông báo as headings; reduced motion turns off the press shrink, the lift's
grow, the shape turn and the row collapse. Every screen and new component is
checked at font scale 1.3 with `assertNoClippedText`.

## Testing and acceptance

- JVM unit tests for every rule in the rules table, the query reader and the
  fakes.
- ViewModel tests with Turbine on virtual time.
- Roborazzi screenshots of every new component and every screen state, with
  light, dark, Material You and font scale 1.3 for each screen's main state.
- Robolectric Compose UI tests for each screen's controls and two walks:
  Home → long-press a card → Tìm đồ tương tự → a listing → Người bán → a
  listing; and Home → search → a need tile → search → Theo dõi → back to
  Home → bell → the new-results notification → results.
- `./gradlew check verifyRoborazziDebug` runs everything.

Stage 2 is done when:

1. Every screen and shared piece walks on the API 36 emulator with no dead
   control; controls for later stages open their placeholder.
2. Every screen state has a screenshot, reviewed side by side with its
   mockup, and every difference is one of the rulings above.
3. Every rule in the rules table has unit tests.
4. Every screen lays out at font scale 1.3 without clipping.
5. The mockup checker still passes for all 31 screens.

## Out of scope

Real search, ranking and AI (the query reading, price estimates and compare
picks are fixture data), the map, choosing an area and location permission,
push notifications, notification settings, a Tôi screen (stage 5), new deals
from Listing detail (stage 3).
