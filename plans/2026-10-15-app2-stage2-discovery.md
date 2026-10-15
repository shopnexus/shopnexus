# app2 stage 2 (Khám phá) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the seven stage 2 screens (Search before typing, Search results, Danh mục, Category, Người bán, Đã lưu, Thông báo) and the shared card menu, similar, report and photo search sheets on the stage 1 foundation, running on fake data.

**Architecture:** Five new feature modules and a new `:core:ui` module for data-wired shared pieces. The contract grows in `:core:model`, discovery rules are pure functions in `:core:domain`, the fakes in `:core:data` read new fixtures into the one `FakeWorld`. Screens follow stage 1: one ViewModel with `StateFlow` state and a `Channel` of effects per screen.

**Tech Stack:** unchanged from stage 1 (Kotlin 2.4.21, AGP 9.4.1, Compose BOM 2026.09.00 with material3 1.5.0-beta01, Navigation 3 1.2.0, Hilt 2.60.1, Coil 3.6.3, Robolectric 4.17, Roborazzi 1.76.0, Turbine, Truth).

**Spec:** `/home/beanbocchi/shopnexus/specs/2026-10-15-app2-stage2-discovery-design.md`. Visual and data sources: `app2/.superdesign/design-system.md`, `app2/.superdesign/tools/build_*.py`, `tools/common.py`, and the digest of the seven mockups at `/tmp/claude-1000/stage2/digest.md` (copied into the repository as `app2/.superdesign/stage2-digest.md` in Task 6, since `/tmp` does not last).

**Ruling on this plan's form:** the plan writes out complete code for the contract types, the rules and their tests, and the fixture formats. For the screen tasks it fixes the UI state, the events, the layout from the spec, and every test by name and assertion, and the composables are written against them during execution. The same person writes and executes this plan in one session, and stage 1's 13,000-line plan spent most of its length on composables that changed during the device walk anyway. Cost if wrong: screen code is reviewed only at the final review instead of in the plan.

## Global Constraints

- Everything in stage 1's Global Constraints still holds (minSdk 31, compileSdk 37, targetSdk 36, JVM 21, built-in Kotlin, package `vn.shopnexus`, features never depend on features, `:core:model` and `:core:domain` are JVM, colors only through the theme, the type scale, corners 4/8/12/16/20/28/32 dp, touch targets ≥ 48 dp, Vietnamese strings in `strings.xml`, money as `Vnd`).
- `tertiary` marks bargaining and the agreed price, `primary` actions and trust; price talk (price cuts, price insights, "Báo giá") takes `tertiary` or `tertiaryFixed`.
- Icons keep one meaning in the deal flow: `sell` bargaining, `handshake` an agreed or finished deal, `group` meeting in person.
- New Material Symbols go through `core/designsystem/symbols.txt` and `tools/gen_symbols.py`.
- A string name defined in two modules must have one value (`StringResourcesTest`).
- Screenshots run at a zero-pixel threshold and show the saved fixture photos; new fixture photos are saved with `core/testing/tools/fetch_photos.py`.
- `./gradlew check verifyRoborazziDebug` passes at the end of every task.
- Commit messages and code comments go through the humanizing-writing checker; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Vietnamese text typed with or without diacritics, in any case, with extra spaces ("XE DAP", "xe  đạp", "Đi phố"): the query list and the search match the same listings. Pinned in Task 3 (`FoldViTest`, `SuggestionsTest`) and Task 7 (`QueryReaderTest`).
2. "Hoàn tác" after a removal from a list (unsave in Đã lưu, "Không quan tâm" on a grid, clear history, mark all read): the item comes back at its old position and with its old state, also after a second removal before the first undo. Pinned in Task 7 (`undo` tests in each fake), Task 11 (`CardActionsTest`) and Tasks 13, 18, 19.
3. A filter or tab that leaves no listing, and a category with none: the empty state names the cause and "Bỏ bộ lọc" restores the full list. Pinned in Tasks 14 and 16.
4. A long press that turns into a scroll, and a long press released over nothing: the list scrolls and no listing opens; the menu stays open for a tap. Pinned in Task 10 (`CardMenuTest`).
5. State shared across screens (a heart, a follow, a read mark, a hidden card, a block): changing it on one screen shows on every other without a reload. Pinned in Task 7 (`FakeWorldConsistencyTest`) and Task 20 (`DiscoveryWalkTest`).

---

## File structure

```
core/model/src/main/kotlin/vn/shopnexus/core/model/
  Discovery.kt        ListingKind, ListingFacts, PoolListing, SearchEntry, RecentSearch, NeedTile, SearchQuery,
                      ResultSort, QueryChip, QueryChipKind, SearchResults, SimilarSet, SimilarFilter
  Catalog.kt          CatalogRoot, PopularTile, Subcategory, CategoryPage, BrandTab
  Sellers.kt          SellerProfile, SellerFacts, Review
  Saved.kt            SavedPage, SavedSearch, SavedListing, ComparePick
  Notifications.kt    Notification, NotificationKind, Tone, NotificationTarget
core/domain/src/main/kotlin/vn/shopnexus/core/domain/
  Text.kt             foldVi, suggestions
  Listings.kt         ListingFilter, filterListings, sortListings, similarListings
  Compare.kt          CompareRow, CompareTable, compareTable
  Notices.kt          NoticeGroup, notificationGroups, notificationTime
core/data/src/main/kotlin/vn/shopnexus/core/data/
  Repositories.kt     + SearchRepository, CatalogRepository, SellerRepository, SavedRepository, NotificationRepository
  fake/QueryReader.kt, fake/GeneratedDetails.kt, fake/Fake*Repository.kt, FakeWorld (grows), Fixtures (grows)
core/data/src/main/resources/fixtures/
  pool.json sellers.json reviews.json search.json catalog.json saved.json notifications.json (home.json refers to pool ids)
core/designsystem/.../component/
  Chips.kt (FilterPill, PickerChip, QueryChip), FloatingToolbar.kt, ChoiceRows.kt (RadioRow, CheckRow, SwitchRow),
  TierSheetContent.kt, Stars.kt, ListingGrid.kt (LazyGridScope.listingCards), CardMenu.kt (press, lift, menu layout)
core/ui/                  new module vn.shopnexus.core.ui
  CardActions.kt, CardMenuHost.kt, SimilarSheet.kt, ReportSheet.kt (moved), PhotoSearchSheet.kt, Share.kt
feature/search/           SearchScreen, SearchViewModel, ResultsScreen, ResultsViewModel, FilterSheet, SortSheet, SearchInstaller
feature/catalog/          CategoriesScreen, CategoriesViewModel, CategoryScreen, CategoryViewModel, CatalogInstaller
feature/seller/           SellerScreen, SellerViewModel, TierSheet, SellerInstaller
feature/saved/            SavedScreen, SavedViewModel, CompareSheet, SavedInstaller
feature/notifications/    NotificationsScreen, NotificationsViewModel, NotificationsInstaller
```

---

### Task 1: Stage 2 routes and placeholders

**Files:**
- Modify: `core/navigation/src/main/kotlin/vn/shopnexus/core/navigation/Routes.kt`, `DeepLinks.kt`
- Modify: `app/src/main/kotlin/vn/shopnexus/app2/AppNavigation.kt`
- Modify: `feature/placeholder/src/main/kotlin/vn/shopnexus/feature/placeholder/PlaceholderScreen.kt`, `PlaceholderInstaller.kt`, `res/values/strings.xml`
- Test: `app/src/test/kotlin/vn/shopnexus/app2/AppNavigatorTest.kt`, `core/navigation/src/test/kotlin/.../DeepLinksTest.kt`, `feature/placeholder/src/test/.../PlaceholderScreenTest.kt`

**Interfaces (Produces):**

```kotlin
/** A pushed route that lives in one tab: pushing it from another tab switches tabs first. */
interface InTab { val tab: NavKey }

@Serializable data object SearchRoute : NavKey
@Serializable data class SearchResultsRoute(val query: String, val sort: String = "RELEVANCE") : NavKey
@Serializable data class CategoryRoute(val key: String) : NavKey, InTab { override val tab: NavKey get() = CategoriesRoute }
@Serializable data class SellerRoute(val id: String) : NavKey
@Serializable data object SavedRoute : NavKey
@Serializable data object NotificationsRoute : NavKey
```

`SearchResultsRoute.sort` is the `ResultSort` name, so `:core:navigation` does not depend on the new model file. `DeepLinks.parse("shopnexus://seller/u-kiet")` returns `SellerRoute("u-kiet")`; `DeepLinks.seller(id)` and `DeepLinks.listing(id)` build the links that sharing uses.

- [ ] **Step 1: Failing tests.** `AppNavigatorTest.aRouteInAnotherTabSwitchesThereFirst` (push `CategoryRoute("phones")` from Home: `topLevelRoute == CategoriesRoute`, its stack is `[CategoriesRoute, CategoryRoute("phones")]`, Home's stack unchanged; `back()` returns to `CategoriesRoute`'s root and keeps the tab). `DeepLinksTest.aSellerLinkOpensTheSellerPage` and `linksRoundTrip` (`parse(listing(id)) == ListingRoute(id)`, same for seller). `PlaceholderScreenTest.stageZeroSaysLater` ("Màn này làm sau.") and `theMeTabListsSavedAndNotifications` (rows "Đã lưu" and "Thông báo" push `SavedRoute` and `NotificationsRoute`).
- [ ] **Step 2: Run, expect FAIL** (unresolved references). `./gradlew :app:testDebugUnitTest :core:navigation:test :feature:placeholder:testDebugUnitTest`.
- [ ] **Step 3: Implement.** `AppNavigator.push`: `if (route is InTab && route.tab != state.topLevelRoute) { state.topLevelRoute = route.tab }` before adding. Placeholder: stage 0 uses `placeholder_later` ("Màn này làm sau.") and title "Sau giai đoạn 5"; the Me placeholder adds a `GroupedList` with two rows. `PlaceholderInstaller` stops registering `CategoriesRoute` only in Task 15.
- [ ] **Step 4: Run, expect PASS**, then the full suite.
- [ ] **Step 5: Commit** `feat: add the stage 2 routes and open in-tab routes in their tab`.

### Task 2: The stage 2 contract (`:core:model`)

**Files:** Create `Discovery.kt`, `Catalog.kt`, `Sellers.kt`, `Saved.kt`, `Notifications.kt` in `core/model`; test `core/model/src/test/kotlin/.../DiscoveryJsonTest.kt`.

**Interfaces (Produces):**

```kotlin
@Serializable enum class ListingKind { PHONE, COMPUTER, WATCH, AUDIO, CAMERA, BIKE, MOTORBIKE, FURNITURE, FASHION, APPLIANCE, OTHER }

/** What a listing is beyond its card: what the similar sheet, Đã lưu and "So sánh" need. */
@Serializable
data class ListingFacts(
    val kind: ListingKind,
    val sellerId: UserId,
    val district: String? = null,
    val battery: Int? = null,
    val bikeType: String? = null,
    val brand: String? = null,
    val sold: Boolean = false,
    val allowOffers: Boolean = true,
    val estimate: PriceRange? = null,
)

@Serializable data class PoolListing(val summary: ListingSummary, val facts: ListingFacts)

@Serializable data class RecentSearch(val query: String, val title: String, val detail: String, val photoUrl: String)
@Serializable data class NeedTile(val title: String, val query: String, val photoUrl: String)
@Serializable data class SearchEntry(val district: String, val examplePhotoUrl: String, val recent: List<RecentSearch>, val needs: List<NeedTile>, val phrases: List<String>)

@Serializable enum class ResultSort { RELEVANCE, NEAREST, PRICE_LOW, PRICE_HIGH }
@Serializable enum class QueryChipKind { KIND, MAX_PRICE, USE }
@Serializable data class QueryChip(val kind: QueryChipKind, val label: String)

@Serializable
data class SearchQuery(
    val text: String,
    val offChips: Set<QueryChipKind> = emptySet(),
    val conditions: Set<Condition> = emptySet(),
    val maxDistanceKm: Int? = null,
    val maxPrice: Vnd? = null,
    val negotiableOnly: Boolean = false,
    val sort: ResultSort = ResultSort.RELEVANCE,
)

@Serializable
data class SearchResults(val chips: List<QueryChip>, val listings: List<ListingSummary>, val estimate: PriceRange?, val followed: Boolean)

@Serializable enum class SimilarFilter { ALL, CHEAPER, CLOSER, LIKE_NEW }
@Serializable data class SimilarSet(val source: ListingSummary, val candidates: List<PoolListing>, val sourceFacts: ListingFacts)

@Serializable data class PopularTile(val title: String, val count: Int, val photoUrl: String, val category: String)
@Serializable data class Subcategory(val name: String, val icon: String, val count: Int)
@Serializable data class CatalogRoot(val categories: List<CategoryEntry>, val popular: List<PopularTile>, val subcategories: Map<String, List<Subcategory>>)
@Serializable data class BrandTab(val key: String, val label: String)
@Serializable data class CategoryPage(val entry: CategoryEntry, val district: String, val tabs: List<BrandTab>, val listings: List<PoolListing>)

@Serializable
data class SellerFacts(val dealsDone: Int, val cancelled: Int, val codRefused: Int, val codOrders: Int, val records: Int, val recordsSelfRefunded: Int, val idChip: Boolean, val replyTime: String)
@Serializable data class Review(val name: String, val stars: Int, val age: String, val text: String, val item: String, val itemPhotoUrl: String)
@Serializable
data class SellerProfile(
    val seller: SellerSummary,
    val district: String,
    val phoneVerified: Boolean,
    val idVerified: Boolean,
    val facts: SellerFacts,
    val listings: List<ListingSummary>,
    val reviews: List<Review>,
    val praise: List<String>,
    val following: Boolean,
    val blocked: Boolean,
    val dealId: DealId?,
)

@Serializable data class SavedSearch(val id: String, val query: String, val newCount: Int, val area: String, val alert: Boolean)
@Serializable data class SavedListing(val listing: PoolListing, val savedPrice: Vnd, val sellerTier: Tier)
@Serializable data class ComparePick(val listing: ListingId, val headline: String, val reason: String)
@Serializable data class SavedPage(val searches: List<SavedSearch>, val listings: List<SavedListing>, val priceCutAlerts: Boolean, val picks: List<ComparePick>)

@Serializable enum class NotificationKind { DEAL, PRICE, ACCOUNT }
@Serializable enum class Tone { DEAL, TRUST, CALM }
@Serializable sealed interface NotificationTarget {
    @Serializable @SerialName("chat") data class Chat(val dealId: DealId) : NotificationTarget
    @Serializable @SerialName("saved") data object Saved : NotificationTarget
    @Serializable @SerialName("search") data class Search(val query: String) : NotificationTarget
    @Serializable @SerialName("later") data class Later(val stage: Int, val title: String) : NotificationTarget
}
@Serializable
data class Notification(val id: String, val kind: NotificationKind, val icon: String, val tone: Tone, val text: String, val at: Moment, val unread: Boolean, val target: NotificationTarget)
```

`HeroSlide` gains `val query: String = ""` for the slide's results.

- [ ] **Step 1: Failing test** `DiscoveryJsonTest`: every new type round-trips through `ShopNexusJson`; `NotificationTarget` encodes with its `type` discriminator (`{"type":"chat","dealId":"d-kiet"}`); `SearchQuery("xe")` encodes to `{"text":"xe"}` (defaults dropped).
- [ ] **Step 2: Run** `./gradlew :core:model:test`, expect FAIL (unresolved).
- [ ] **Step 3: Write the types** above.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat: add the stage 2 contract types`.

### Task 3: Text rules

**Files:** Create `core/domain/src/main/kotlin/vn/shopnexus/core/domain/Text.kt`; tests `FoldViTest.kt`, `SuggestionsTest.kt`.

```kotlin
/** Lower case, diacritics removed (NFD, combining marks U+0300–U+036F), đ → d, spaces trimmed and collapsed. */
fun foldVi(text: String): String

/** Empty input: the recent queries, newest first. Otherwise up to [limit] phrases whose folded text contains the folded input, in order. */
fun suggestions(input: String, recent: List<String>, phrases: List<String>, limit: Int = 5): List<String>
```

- [ ] **Step 1: Failing tests.** `FoldViTest`: `"Xe Đạp  Đi làm"` → `"xe dap di lam"`; `"  ĐỒNG HỒ "` → `"dong ho"`; `"iPhone 13 Pro"` → `"iphone 13 pro"`; `"Ghế bành bọc vải vàng mù tạt"` → `"ghe banh boc vai vang mu tat"`; the empty string stays empty. `SuggestionsTest`: `""` returns the recent list unchanged; `"xe dap"` returns the three bike phrases in fixture order; `"XE ĐẠP"` returns the same; `"iphone"` returns `iPhone 13 Pro`, `iPhone dưới 8 triệu`; a match beyond five is cut at five; `"zzz"` returns empty; duplicates between phrases appear once.
- [ ] **Step 2: Run** `./gradlew :core:domain:test --tests '*FoldVi*' --tests '*Suggestions*'`, expect FAIL.
- [ ] **Step 3: Implement** with `java.text.Normalizer.normalize(text, NFD)`, a regex for `\p{Mn}`, `replace('đ','d')`, `split(Regex("\\s+"))`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat: fold Vietnamese text and suggest searches`.

### Task 4: Listing rules and the compare table

**Files:** Create `Listings.kt`, `Compare.kt` in `core/domain`; tests `ListingsTest.kt`, `CompareTest.kt`.

```kotlin
data class ListingFilter(
    val conditions: Set<Condition> = emptySet(),
    val maxDistanceKm: Int? = null,
    val maxPrice: Vnd? = null,
    val negotiableOnly: Boolean = false,
    val brand: String? = null,
) { val isEmpty: Boolean get() = this == ListingFilter() }

fun filterListings(listings: List<PoolListing>, filter: ListingFilter): List<PoolListing>
fun sortListings(listings: List<PoolListing>, sort: ResultSort): List<PoolListing>
fun similarListings(source: PoolListing, pool: List<PoolListing>, filter: SimilarFilter, limit: Int = 6): List<PoolListing>

enum class CompareFact { PRICE, CONDITION, BATTERY, BIKE_TYPE, DISTANCE, SELLER }
data class CompareCell(val text: String, val tier: Tier? = null)
data class CompareRow(val fact: CompareFact, val cells: List<CompareCell>, val best: Int?)
data class CompareTable(val columns: List<ListingId>, val rows: List<CompareRow>)
fun compareTable(listings: List<SavedListing>): CompareTable
```

Cell texts: price as `Vnd.short()` ("2,1 tr"), condition as its Vietnamese label, battery "88%", bike type as given, distance "1,2 km", seller as the tier (`text` empty, `tier` set).

- [ ] **Step 1: Failing tests.** `ListingsTest`: max price is strict (`< 5.000.000`), distance inclusive (`<= 3`), brand exact, conditions as a set, negotiable only drops `allowOffers = false`; empty filter returns the input; the digest's Category counts (iPhone 5, Samsung 2, Khác 1; under 5 tr → 2, under 10 tr → 5, under 15 tr → 8; within 3 km → 5, within 5 km → 7) hold on the eight phone fixtures built inline; sorts keep ties in input order; `similarListings` for the single speed bike: same kind only, never the source, never sold, `CHEAPER` strict, `CLOSER` strict, `LIKE_NEW` admits NEW, ordered by price difference with ties in pool order, at most six. `CompareTest`: the digest's phone table (iPhone 12 best on price and distance; iPhone 13 Pro on condition, battery and seller); the bike table (single speed on price, condition and distance; Giant on seller; type unmarked); two equal prices mark none; a battery row appears only when every column has a battery; removing a column recomputes.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat: filter, sort, find similar listings and compare them`.

### Task 5: Notification rules

**Files:** Create `Notices.kt` in `core/domain`; test `NoticesTest.kt`.

```kotlin
enum class NoticeDay { TODAY, YESTERDAY, THIS_WEEK, OLDER }
data class NoticeGroup(val day: NoticeDay, val items: List<Notification>)
fun notificationGroups(items: List<Notification>, now: Instant, zone: ZoneId): List<NoticeGroup>
fun notificationTime(at: Instant, now: Instant, zone: ZoneId): String
```

- [ ] **Step 1: Failing tests.** With now Thursday 15/10/2026 15:10 in Hồ Chí Minh City: 14:10 today → TODAY and "14:10"; 21:04 yesterday → YESTERDAY and "21:04"; Monday 12/10 → THIS_WEEK and "Thứ Hai"; Sunday 11/10 → THIS_WEEK and "Chủ nhật"; 9/10 → THIS_WEEK ("Thứ Sáu"); 8/10 → OLDER and "08/10"; groups keep newest first and drop empty days; midnight in Hồ Chí Minh City (not UTC) splits the days.
- [ ] **Step 2–4:** run, implement, run.
- [ ] **Step 5: Commit** `feat: group notifications by day`.

### Task 6: Fixtures

**Files:** Create `core/data/src/main/resources/fixtures/{pool,sellers,reviews,search,catalog,saved,notifications}.json`; modify `home.json` (ids of pool listings; `query` on each hero slide); modify `Fixtures.kt`; copy the digest to `app2/.superdesign/stage2-digest.md`; save new photos with `fetch_photos.py`. Test: `FixturesTest.kt` (grows).

Data, from the digest: the 35 pool listings plus Home's own listings, each with the longest title the mockups give it, stage 1's ids where Home has the item (`l-<first photo id segment>`), `p-iphone13` for the iPhone 13 Pro, and `l-<photo id>` for the rest; facts per listing (kind by the `GROUPS` order, district where a screen gives one, battery for iPhone 13 Pro 88, iPhone 12 84, Galaxy S21 Ultra 81, bike type "Single speed" and "Hybrid, có líp" for the two compared bikes, the phone brands, `sold` for the classic bike, estimates from Category); the seven sellers (Tuấn Kiệt `u-kiet` with the six listings of Người bán, tier TOP, the stats and the seven tier-sheet facts; Ngọc Hân bikes, Hoàng Nam other phones, Gia Bảo furniture, Mai Anh electronics, Đức Trí fashion, Thu Hà the rest, with tiers matching the compare table: single speed's seller TRUSTED, Giant's REPUTABLE, iPhone 12's TRUSTED, S21's NEW); the reviews and praise chips; search history, need tiles, the ten phrases and the keyword tables; the catalog; the two saved searches and twelve saved listings with saved-at prices (single speed 2.400.000, iPhone 13 Pro 11.300.000, the others equal to their price) and the two picks; the eight notifications at their instants.

- [ ] **Step 1: Failing tests.** `FixturesTest`: every new file parses; every id in `home.json`, `saved.json`, `sellers.json` and notification targets exists in the pool or the deals; every pool listing's seller exists; no two pool listings share an id or a photo; Home's saved hearts and the twelve saved listings are one set; the eight notification instants give the digest's groups; every photo URL in the fixtures has a saved copy (the fetch script ran).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write the JSON** and loaders (`Fixtures.pool()`, `sellers()`, `reviews()`, `search()`, `catalog()`, `saved()`, `notifications()`); run `python3 core/testing/tools/fetch_photos.py`.
- [ ] **Step 4: Run, expect PASS**, then the full suite (Home screenshots may change only where an id or title changed; record and check them).
- [ ] **Step 5: Commit** `feat: add the stage 2 fixtures`.

### Task 7: The fake world and the fake repositories

**Files:** Modify `Repositories.kt`, `FakeWorld.kt`, `FakeHomeRepository.kt`, `FakeListingRepository.kt`, `di/DataModule.kt`; create `fake/QueryReader.kt`, `fake/GeneratedDetails.kt`, `fake/FakeSearchRepository.kt`, `FakeCatalogRepository.kt`, `FakeSellerRepository.kt`, `FakeSavedRepository.kt`, `FakeNotificationRepository.kt`. Tests: one per fake, `QueryReaderTest`, `GeneratedDetailsTest`, `FakeWorldConsistencyTest`.

```kotlin
interface SearchRepository {
    fun entry(): Flow<SearchEntry>
    fun results(query: SearchQuery): Flow<SearchResults>
    suspend fun remember(text: String): Result<Unit>
    suspend fun clearHistory(): Result<List<RecentSearch>>
    suspend fun restoreHistory(items: List<RecentSearch>): Result<Unit>
    suspend fun follow(text: String, on: Boolean): Result<Unit>
}
interface CatalogRepository { fun root(): Flow<CatalogRoot>; fun category(key: String): Flow<CategoryPage?> }
interface SellerRepository {
    fun profile(id: UserId): Flow<SellerProfile?>
    suspend fun setFollowing(id: UserId, on: Boolean): Result<Unit>
    suspend fun setBlocked(id: UserId, on: Boolean): Result<Unit>
    suspend fun report(id: UserId, reason: ReportReason): Result<Unit>
}
interface SavedRepository {
    fun saved(): Flow<SavedPage>
    suspend fun setSearchAlert(id: String, on: Boolean): Result<Unit>
    suspend fun setPriceCutAlerts(on: Boolean): Result<Unit>
}
interface NotificationRepository {
    fun notifications(): Flow<List<Notification>>
    suspend fun markRead(id: String): Result<Unit>
    suspend fun markAllRead(): Result<Set<String>>
    suspend fun markUnread(ids: Set<String>): Result<Unit>
}
// ListingRepository grows:
fun similar(id: ListingId): Flow<SimilarSet?>
suspend fun setPriceAlert(id: ListingId, at: Vnd?): Result<Unit>
suspend fun setHidden(id: ListingId, hidden: Boolean): Result<Unit>
fun priceAlerts(): Flow<Map<ListingId, Vnd>>
```

`QueryReader.read(text): Reading(chips, kinds, maxPrice, words)` with the keyword tables from `search.json`: a kind word ("xe đạp", "fixie", "fixed gear" → BIKE and chip "Xe đạp"), "dưới N triệu" / "dưới N tr" → `maxPrice` and chip "Dưới N tr", "đi làm" / "đi phố" → chip "Đi phố" (no filter). Words left after the chips match folded titles, and a chip the person turned off stops filtering.

- [ ] **Step 1: Failing tests.** `QueryReaderTest`: the seeded query gives chips Xe đạp, Dưới 3 tr, Đi phố and returns the eight bikes under 3.000.000 in pool order; "iPhone 13 Pro" returns the iPhone 13 Pro; "sofa nhung" the sofa; "XE DAP" the same as "xe đạp"; turning off Dưới 3 tr adds the bikes above it; an empty query returns the whole pool minus hidden, blocked and sold. `GeneratedDetailsTest`: every pool listing has a detail; a listing over 5.000.000 ₫ has no COD path; the generated similar list follows `similarListings`; the iPhone 13 Pro keeps its fixture detail. Fake tests: history clear returns the three items and restore puts them back in order; follow adds a saved search and unfollow removes it; markAllRead returns the four unread ids and markUnread restores exactly them; markRead lowers Home's `unreadNotifications`; a hidden listing leaves Home, results, categories, seller listings and similar sets, and comes back in its place when unhidden; a blocked seller's listings leave every feed; setSaved on any listing shows in Đã lưu; failures roll back (with `FailurePolicy.failing`). `FakeWorldConsistencyTest`: a save, a hide and a block made through one repository show in every other repository's next emission.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** `WorldState` gains `pool: Map<ListingId, PoolListing>` (insertion order kept), `sellers`, `reviews`, `history`, `followed`, `savedPrice`, `priceAlerts`, `hidden`, `blocked`, `following`, `searchAlerts`, `priceCutAlerts`, `notifications`. Home's listings resolve through the pool.
- [ ] **Step 4: Run, expect PASS**, then the full suite.
- [ ] **Step 5: Commit** `feat: fake search, catalog, sellers, saved and notifications`.

### Task 8: Module skeletons

**Files:** `settings.gradle.kts`; `core/ui/build.gradle.kts` (plugins `shopnexus.android.library.compose`, `shopnexus.hilt`; depends on designsystem, data, navigation); `feature/{search,catalog,seller,saved,notifications}/build.gradle.kts` with `shopnexus.android.feature`; `AndroidFeatureConventionPlugin` adds `:core:ui`; each feature's `XxxInstaller` registering its routes with an empty screen, and its Hilt `@IntoSet` module; `app/build.gradle.kts` depends on them; `DataModule` binds the new fakes.

- [ ] **Step 1: Failing test** `app/src/test/.../InstallersTest.kt`: the Hilt set holds eight installers, and the entry provider resolves every route in `Routes.kt` (no `IllegalStateException` from a missing entry).
- [ ] **Steps 2–4:** run (FAIL), add the modules, run (PASS) and the full suite.
- [ ] **Step 5: Commit** `build: add :core:ui and the five stage 2 feature modules`.

### Task 9: Design-system components

**Files:** Create in `core/designsystem/.../component/`: `Chips.kt`, `FloatingToolbar.kt`, `ChoiceRows.kt`, `TierSheetContent.kt`, `Stars.kt`, `ListingGrid.kt`; add symbols (`tune`, `history`, `north_west`, `map`, `swap_vert`, `notifications_active`, `notifications_off`, `done_all`, `settings`, `compare_arrows`, `arrow_downward`, `trending_down`, `near_me`, `pedal_bike`, `visibility`, `flag` (exists), `share` (exists), `calendar_month`, `verified_user`, `cancel`, `report`, `schedule_send`, `door_front`, `person_add`, `image_search` (exists), `info`, the subcategory and category icons, `steps`, `local_mall`, `toys`, …). Test: `DiscoveryComponentsTest.kt` with screenshots in four variants.

```kotlin
@Composable fun FilterPill(label: String, selected: Boolean, onClick: () -> Unit, leading: Symbol? = null, modifier: Modifier = Modifier)
@Composable fun PickerChip(label: String, value: String?, onClick: () -> Unit, modifier: Modifier = Modifier)
@Composable fun QueryChip(label: String, selected: Boolean, onClick: () -> Unit, modifier: Modifier = Modifier) // sparkle in place of the check
@Composable fun ResultsToolbar(onMap: () -> Unit, onSort: () -> Unit, followed: Boolean, onFollow: () -> Unit, modifier: Modifier = Modifier)
@Composable fun RadioRow(label: String, selected: Boolean, onClick: () -> Unit)
@Composable fun CheckRow(label: String, checked: Boolean, onClick: () -> Unit)
@Composable fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit, leading: Symbol? = null)
@Composable fun TierShape(tier: Tier, size: Dp, iconSize: Dp?)
@Composable fun TierSheetContent(tier: Tier, facts: List<Pair<Symbol, String>>, footer: String)
@Composable fun Stars(count: Int, size: Dp = 16.dp, outOf: Int = 5)
fun LazyGridScope.listingCards(listings: List<ListingSummary>, onOpen: (ListingSummary) -> Unit, onToggleSave: (ListingSummary) -> Unit, menu: CardMenuBinding? = null)
```

`TierChip` moves to use `TierShape` (the tier's MaterialShape and icon, as the mockups draw it) instead of the premium icon for every tier.

- [ ] **Step 1: Failing tests:** selected states in semantics (`FilterPill` selected, `PickerChip` shows "Tình trạng: Như mới" once set, `QueryChip` has no check icon), the toolbar's three controls with labels "Xem trên bản đồ", "Sắp xếp", "Theo dõi" / "Đang theo dõi", `Stars(4)` reads "4 sao", 48 dp targets, `assertNoClippedText` at 1.3, and the four-variant screenshot `discovery-components-*`.
- [ ] **Steps 2–4:** FAIL, implement, PASS; record screenshots and compare them with the mockups' chips, toolbar and tier sheet.
- [ ] **Step 5: Commit** `feat: add chips, choice rows, the results toolbar, tier shapes and stars`.

### Task 10: The card menu

**Files:** Create `core/designsystem/.../component/CardMenu.kt`; modify `ListingCard.kt` (`menu: CardMenuBinding?` parameter); test `CardMenuTest.kt`.

```kotlin
enum class CardMenuItem { SAVE, PRICE_ALERT, SHARE, SIMILAR, NOT_INTERESTED, REPORT }
/** What a card needs to open the menu: whether it is saved and alerted, and what to do with a chosen item. */
data class CardMenuBinding(val saved: Boolean, val alerted: Boolean, val onChoose: (CardMenuItem) -> Unit)
```

The press is a `pointerInput` that waits 450 ms with `awaitLongPressOrCancellation`-style logic: a move past 8 dp before then cancels and lets the scroll take the gesture; the photo scales 1 → 0.95 over the hold (skipped under reduced motion). At 450 ms the card's bounds (from `onGloballyPositioned`) open a full-screen `Popup` with a 30 % black scrim, the card drawn again at its bounds (moved into view, scaled to 1.04), and the menu laid out below or above it to fit. While the finger stays down, the pointer is tracked in root coordinates; menu items record their bounds, and the release over an item chooses it. The release elsewhere keeps the menu open. Back and a tap on the scrim close it. `semantics { customActions = … }` exposes the six items by their labels, and `onKeyEvent` handles Shift+F10 and the context-menu key; a secondary mouse button opens it.

- [ ] **Step 1: Failing tests.** `CardMenuTest`: a 500 ms hold shows the menu with the six labels (and "Đã lưu" when saved); a hold then a 20 dp move before 450 ms shows no menu and scrolls the list; a release over "Không quan tâm" chooses NOT_INTERESTED and closes; a release over empty scrim keeps the menu; tapping the scrim closes it; the hold never calls `onOpen`; TalkBack custom actions list the six items and run them; Shift+F10 opens it; a screenshot `card-menu-light` and `card-menu-dark` of the lifted state.
- [ ] **Steps 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** `feat: add the long-press card menu`.

### Task 11: Shared data-wired pieces (`:core:ui`)

**Files:** Create `core/ui/src/main/kotlin/vn/shopnexus/core/ui/CardActions.kt`, `CardMenuHost.kt`, `SimilarSheet.kt`, `ReportSheet.kt` (moved from `feature/discover/detail/DetailSheets.kt`), `PhotoSearchSheet.kt`, `Share.kt`; `res/values/strings.xml`; the `FileProvider` for the camera in `core/ui/src/main/AndroidManifest.xml`. Tests: `CardActionsTest.kt` (JVM, with the fakes), `SharedSheetsTest.kt` (Robolectric with screenshots).

```kotlin
sealed interface CardEvent {
    data class Choose(val listing: ListingSummary, val item: CardMenuItem) : CardEvent
    data class Similar(val filter: SimilarFilter) : CardEvent
    data class Report(val reason: ReportReason) : CardEvent
    data object CloseSheet : CardEvent
}
data class CardMenuState(val similar: SimilarSheetState? = null, val reportFor: ListingId? = null, val alerts: Map<ListingId, Vnd> = emptyMap())
data class SimilarSheetState(val source: ListingSummary, val filter: SimilarFilter, val listings: List<ListingSummary>)

class CardActions(
    private val listings: ListingRepository,
    private val scope: CoroutineScope,
    private val outbox: SendChannel<UiMessage>,
    private val share: SendChannel<ShareRequest>,
) {
    val state: StateFlow<CardMenuState>
    fun onEvent(event: CardEvent)
}
data class ShareRequest(val text: String)
@Composable fun ShareEffect(requests: Flow<ShareRequest>)
@Composable fun CardMenuHost(state: CardMenuState, onEvent: (CardEvent) -> Unit, onOpen: (ListingSummary) -> Unit)
@Composable fun PhotoSearchSheet(onDismiss: () -> Unit)
@Composable fun ReportSheet(onSend: (ReportReason) -> Unit, onDismiss: () -> Unit)
```

- [ ] **Step 1: Failing tests.** `CardActionsTest`: SAVE toggles and says "Đã lưu tin" / "Đã bỏ lưu"; PRICE_ALERT says "Báo khi giá dưới 10,9 tr ₫" then "Đã tắt báo giá"; SHARE sends "iPhone 13 Pro 128GB, Xanh Sierra, pin 88% · 10.900.000 ₫ · shopnexus://listing/p-iphone13"; NOT_INTERESTED hides and the undo action unhides; SIMILAR opens the sheet with `ALL` and switching to `CHEAPER` narrows it; REPORT opens the report sheet and sending says "Đã gửi báo cáo. Cảm ơn bạn."; a failing command rolls back and says "Chưa lưu được. Thử lại". `SharedSheetsTest`: the photo sheet shows "Chọn một ảnh rõ món đồ", "Chụp ảnh", "Chọn ảnh"; after a picked photo (fed through the launcher's test registry) the button reads "Đổi ảnh" and the preview survives closing and reopening; the similar sheet's chips and empty line; screenshots of both sheets and of the report sheet.
- [ ] **Steps 2–4:** FAIL, implement, PASS.
- [ ] **Step 5: Commit** `feat: wire the card menu, similar, report and photo search sheets`.

### Task 12: Stage 2 entry points in the stage 1 screens

**Files:** Modify `feature/discover/home/*` (grid, menu, routes, photo sheet), `feature/discover/detail/*` (seller row → `SellerRoute`, similar arrow → similar sheet, report sheet from `:core:ui`, menu on similar cards, generated details), `feature/deal/chat/ChatScreen.kt` (overflow menu: Trang người bán, Báo cáo, Chặn). Tests: grow `HomeScreenTest`, `HomeViewModelTest`, `ListingDetailScreenTest`, `ChatScreenTest`; re-record their screenshots.

- [ ] **Step 1: Failing tests.** Home: the search bar pushes `SearchRoute`; the bell `NotificationsRoute`; the category row `CategoryRoute("phones")`; the second hero slide `SearchResultsRoute("xe đạp")`; "Gần bạn"'s arrow `SearchResultsRoute("", "NEAREST")`; the camera opens the photo sheet; a long press on a grid card and "Không quan tâm" removes it and the undo brings it back at the same index. Detail: the seller row pushes `SellerRoute("u-kiet")`; the similar arrow opens the similar sheet; a generated detail (`l-1510557880182`, iPhone X) shows its title, price and "Gặp mặt" and COD both open. Chat: the menu's "Trang người bán" pushes `SellerRoute("u-kiet")`.
- [ ] **Steps 2–4:** FAIL, implement, PASS; record screenshots and compare.
- [ ] **Step 5: Commit** `feat: open stage 2 screens from Home, Listing detail and Chat`.

### Task 13: Search before typing

**Files:** `feature/search/src/main/kotlin/vn/shopnexus/feature/search/entry/{SearchViewModel,SearchScreen,QueryList}.kt`; tests `SearchViewModelTest`, `SearchScreenTest`.

```kotlin
data class SearchUiState(val content: SearchContent, val text: String, val editing: Boolean, val rows: List<QueryRow>, val photoSheet: Boolean)
sealed interface SearchContent { data object Loading : SearchContent; data object Failed : SearchContent; data class Ready(val entry: SearchEntry) : SearchContent }
data class QueryRow(val text: String, val recent: Boolean)
sealed interface SearchEvent { Type(text), Focus, Submit, Pick(text), Clear, Back, ClearHistory, OpenPhoto, ClosePhoto, Retry }
```

- [ ] **Step 1: Failing tests.** VM: typing "xe" gives the three bike phrases; "" gives the history rows; Pick puts text without navigating; Submit remembers the query and navigates to `SearchResultsRoute(text)`; Submit on blank does nothing; ClearHistory empties the rail and the undo restores three items in order; Back while editing leaves editing; the typed text survives a new ViewModel on the same `SavedStateHandle`. Screen: the browse state (panel, rail, four tiles), the query list states ("Tìm gần đây", "Gợi ý tìm kiếm", "Nhấn Tìm để tiếp tục.", "Chưa có tìm kiếm gần đây"), the panel photo at 104 dp on a 360 dp wide screen and 128 dp on 412 dp; screenshots `search-browse-*` (four variants), `search-typing-light`, `search-empty-history-light`; `assertNoClippedText` at 1.3.
- [ ] **Steps 2–4**, **Step 5: Commit** `feat: build Search before typing`.

### Task 14: Search results

**Files:** `feature/search/.../results/{ResultsViewModel,ResultsScreen,FilterSheet,SortSheet}.kt`; tests `ResultsViewModelTest`, `ResultsScreenTest`.

```kotlin
data class ResultsUiState(val query: SearchQuery, val content: ResultsContent, val sheet: ResultsSheet?, val cards: CardMenuState)
sealed interface ResultsContent { Loading; Failed; data class Ready(val results: SearchResults) }
enum class ResultsSheet { FILTER, SORT }
sealed interface ResultsEvent { ToggleChip(kind), OpenFilter(section), ApplyFilter(...), OpenSort, Sort(sort), Follow, Clear, Map, Card(CardEvent), Open(listing), ToggleSave(listing), Retry, CloseSheet }
```

- [ ] **Step 1: Failing tests.** VM: the seeded query yields 8 listings, three chips and the estimate 1,6 – 2,4 tr; turning off "Dưới 3 tr" adds bikes above 3 triệu; the filter (Như mới, within 3 km) narrows to the matching cards and the picker chips show their values; sort PRICE_LOW orders by price; Follow follows and the undo unfollows, and Đã lưu's flow shows the saved search; no results with a filter shows the "Bỏ bộ lọc" state and Bỏ bộ lọc restores; Map pushes `PlaceholderRoute(0, "Bản đồ")`; the query and filters survive recreation. Screen: chip row, result line "8 tin · Phù hợp nhất", the estimate line, the toolbar, the empty state; screenshots `results-*` four variants, `results-filter-light`, `results-sort-light`, `results-empty-light`.
- [ ] **Steps 2–4**, **Step 5: Commit** `feat: build Search results with filters, sort and follow`.

### Task 15: Danh mục

**Files:** `feature/catalog/.../root/{CategoriesViewModel,CategoriesScreen}.kt`; remove `CategoriesRoute` from `PlaceholderInstaller`; tests `CategoriesViewModelTest`, `CategoriesScreenTest`.

- [ ] **Step 1: Failing tests.** Choosing Điện thoại shows its six subcategories and the heading with the arrow; choosing it again restores "Phổ biến quanh bạn"; a popular tile chooses its category; a subcategory row and the arrow push `CategoryRoute(key)`; search pushes `SearchRoute`; camera opens the photo sheet; the chosen category survives recreation; the shape turns 45° (rotation in semantics test tag or screenshot) and not under reduced motion; screenshots `categories-*` four variants and `categories-phones-light`.
- [ ] **Steps 2–4**, **Step 5: Commit** `feat: build Danh mục`.

### Task 16: Category

**Files:** `feature/catalog/.../category/{CategoryViewModel,CategoryScreen,CategoryFilterSheet}.kt`; tests.

- [ ] **Step 1: Failing tests.** "Điện thoại" shows "8 tin · Gần bạn nhất" with cards by distance (iPhone 12 0,8 km first); the iPhone tab shows 5; "Dưới 5 triệu" leaves 2 and the filter button takes `secondaryContainer`; a filter that leaves none shows "Chưa có tin phù hợp với bộ lọc này." and "Bỏ bộ lọc" restores all, brand included; a category without brands has no tab row and its pool listings; an empty category shows "Chưa có tin nào trong mục này."; the first photo's top is within 240 dp; back pops to Danh mục; screenshots `category-*` four variants, `category-filter-light`, `category-empty-light`.
- [ ] **Steps 2–4**, **Step 5: Commit** `feat: build Category`.

### Task 17: Người bán

**Files:** `feature/seller/.../{SellerViewModel,SellerScreen,TierSheet,Reviews}.kt`; tests.

- [ ] **Step 1: Failing tests.** Header facts and stats as in the spec; Theo dõi → "Đang theo dõi" with "Đã theo dõi Tuấn Kiệt" and the undo; unfollow says nothing; the chat button pushes `ChatRoute("d-kiet")`, and for a seller without a deal the stage 3 placeholder; share sends `shopnexus://seller/u-kiet`; the tier chip opens the sheet with the seven facts and the footer; the reviews tab shows "4,9", "/5", "Hay được khen", three chips and four reviews; a seller without reviews says "Chưa có đánh giá"; Chặn asks, then blocks with the undo, and the seller's listings leave Home; Báo cáo opens the report sheet; screenshots `seller-*` four variants, `seller-reviews-light`, `seller-tier-light`.
- [ ] **Steps 2–4**, **Step 5: Commit** `feat: build Người bán`.

### Task 18: Đã lưu

**Files:** `feature/saved/.../{SavedViewModel,SavedScreen,CompareSheet}.kt`; tests.

- [ ] **Step 1: Failing tests.** Searches with their sublines and bells (and their snackbars); groups in order with the right rows; the single speed row shows "↓ 300k", the iPhone 13 Pro "↓ 400k", Giant "Rẻ hơn 9%"; the classic bike shows "Đã bán" and "Xem đồ tương tự" and pushes `SearchResultsRoute("xe đạp")`; unsave collapses the row with "Đã bỏ lưu" and the undo puts it back at its index, also after a second unsave; "So sánh" on Xe đạp, Điện thoại and Nội thất but not Đồ điện tử; the compare sheet marks the digest's winners, Loại xe unmarked; unsaving iPhone 13 Pro drops its column and hides the pick; the empty state after unsaving all twelve with "Khám phá" pushing Home; the price-cut switch persists; screenshots `saved-*` four variants, `saved-compare-light`, `saved-empty-light`.
- [ ] **Steps 2–4**, **Step 5: Commit** `feat: build Đã lưu with the compare sheet`.

### Task 19: Thông báo

**Files:** `feature/notifications/.../{NotificationsViewModel,NotificationsScreen}.kt`; tests.

- [ ] **Step 1: Failing tests.** "4 chưa đọc"; groups Hôm nay (4), Hôm qua (2), Tuần này (2); chips filter (Giao dịch 4, Giá và tin mới 2, Tài khoản 2) and hide empty groups; a row marks itself read, lowers the count and the Home bell, and opens its target (offer → `ChatRoute("d-kiet")`, drop → `SavedRoute`, new → `SearchResultsRoute("xe đạp đi làm dưới 3 triệu")`, door → `PlaceholderRoute(3, "Đơn COD")`, star → `PlaceholderRoute(5, "Điểm uy tín")`); mark all read and the undo restores the same four; settings opens the stage 5 placeholder; day headers are headings; screenshots `notifications-*` four variants and `notifications-read-light`.
- [ ] **Steps 2–4**, **Step 5: Commit** `feat: build Thông báo`.

### Task 20: End-to-end walks and the review page

**Files:** `app/src/test/kotlin/vn/shopnexus/app2/DiscoveryWalkTest.kt`; `tools/review_page.py` (stage 2 screenshots next to their mockups); README modules table.

- [ ] **Step 1: Walk tests.** `DiscoveryWalkTest.longPressToSimilarToSeller` and `searchFollowAndNotification`, as the spec describes, through the real app on the fakes.
- [ ] **Step 2: Device walk** on `app2-api36`: every stage 2 screen, the card menu by touch and with TalkBack actions, the photo picker and the camera, dark theme, font scale 1.3; every control answers. Fix what the walk finds with a failing test first.
- [ ] **Step 3: Review page** with every new screenshot beside its mockup; read every pair.
- [ ] **Step 4: Full suite and the mockup checker** (`node .superdesign/tools/check_mockups.mjs`).
- [ ] **Step 5: Commit** `test: walk the stage 2 screens end to end`.
