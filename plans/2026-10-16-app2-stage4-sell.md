# app2 stage 4 (Bán) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Đăng tin, Quay video, Kiểm tra tin, Tin của bạn, Gói người bán and the seller's half of a deal on the stage 1 to 3 foundation with fake data, so a listing can be drafted, posted and sold end to end.

**Architecture:** Two new feature modules (`:feature:sell`, `:feature:listings`); the seller's deal pieces grow `:feature:deal` and `:feature:orders`. The contract grows in `:core:model`; selling rules are pure functions in `:core:domain`; the fakes gain Khánh Linh's listings and drafts, the plans, the AI reads and a simulated buyer. Screens follow stages 1 to 3: one ViewModel with `StateFlow` state and a `Channel` of effects per screen.

**Tech Stack:** stage 3's (Kotlin 2.4.21, AGP 9.4.1, Compose BOM with material3 1.5.0-beta01, Navigation 3, Hilt, Coil 3, CameraX 1.6.2, ML Kit, ZXing, Robolectric, Roborazzi, Turbine, Truth). No new dependency: frames come from CameraX `ImageAnalysis` and `MediaMetadataRetriever`.

**Spec:** `/home/beanbocchi/shopnexus/specs/2026-10-16-app2-stage4-sell-design.md`. Data, strings and interactions with source lines: `app2/.superdesign/stage4-digest.md` (committed in Task 5). Mockups: `app2/.superdesign/tools/build_{sell,sell_video,sell_review,listings,plans}.py`, `common.py`.

**Ruling on this plan's form:** as in stages 2 and 3, the plan writes out the contract types, the rule signatures with their test cases, and the fixture formats; screen tasks fix the UI state, events, layout and every test by name and assertion, and the composables are written against them during execution. Cost if wrong: screen code is reviewed only at the final review.

## Global Constraints

- Everything in stages 1 to 3's Global Constraints holds (minSdk 31, compileSdk 37, targetSdk 36, JVM 21, package `vn.shopnexus`, features never depend on features, `:core:model` and `:core:domain` are JVM, colors only through the theme, the type scale, corners 4/8/12/16/20/28/32 dp, touch targets ≥ 48 dp, Vietnamese strings in `strings.xml` with one value per name across modules, money as `Vnd`, new symbols through `core/designsystem/symbols.txt` and `tools/gen_symbols.py`, fixture photos saved with `core/testing/tools/fetch_photos.py`).
- `tertiary` marks bargaining, the agreed price and price judgments; the sparkle marks AI values (filled fields, the mark the model saw, the estimate, the price judgment, the frame pick, recognition chips) and nothing else; one primary-filled action per view.
- Every block that touches money shows its `MoneyKey` sentence in the stage 1 words (`DECLARED`, `COD_SELLER`, `RETURN_LEG`, `OVER_LIMIT`, and the new `SERVICE_FEE`).
- Paying for a boost or a plan, posting, and the seller's money steps never show as done before the command succeeds.
- Strings prefixed per module (`sell_`, `listings_`, plus `orders_`, `deal_`, `deal_ui_` where they grow) so `StringResourcesTest` passes.
- `./gradlew check verifyRoborazziDebug` passes at the end of every task (`app2/tmp/gate.sh <log>`, wrapped in `timeout 590`).
- Scratch files, logs and review worktrees go under `app2/tmp/` (git-ignored), never `/tmp`.
- Commit messages and code comments go through the humanizing-writing checker; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Leaving a form mid-way: close, back, process death and the gate's "Xác minh ngay" with photos picked, fields edited, a sheet open or a read in flight. Expected: the dialog of ruling 14 when something changed, the form intact after recreation, a read in flight finishing or retrying once, and a saved draft that reopens with every value and sparkle. Pinned in Task 11 (`SellViewModelTest.theFormSurvivesRecreation`, `closingWithChangesAsks`, `aReadInFlightSurvivesRecreation`) and Task 14 (`ReviewViewModelTest.pickedFramesSurviveRecreation`).
2. The price crossing 5.000.000 ₫ and back, on both forms, by typing, by a suggestion and by the price sheet. Expected: COD unchecks and disables above the limit, stays unchecked when the price comes back, the over-limit sentence follows, and a draft saved above the limit never carries COD. Pinned in Task 3 (`codAllowed`, `pathsFor`), Task 11 (`thePriceOverTheLimitDropsCod`) and Task 14 (`aSpokenPriceOverTheLimitMeetsOnly`).
3. A simulated buyer racing the seller: Thảo Vy's offer landing while the counter sheet is open, a counter sent as she accepts, the code sheet closed before she scans, a sale marked while her deal is open, "Hoàn tác" after the rating arrived. Expected: one agreement, the scan lands only on an issued code, an undone sale drops a pending rating. Pinned in Task 7 (`SimulatorTest.aScanWaitsForAnIssuedCode`, `anUndoneSaleDropsItsRating`) and Task 17 (`ChatViewModelTest.aCounterRacingAnAcceptAgreesOnce`).
4. Tin của bạn's counts and panes after every move: posting, a hand-over, a sale marked and undone, a delete, a hide, a boost, a price cut. Expected: the tab counts, the week tiles and the cards agree at every step, and a reserved listing never offers mark-sold, boost or delete. Pinned in Task 6 (`FakeMyListingsRepositoryTest`) and Task 15 (`MyListingsScreenTest`).
5. Camera failures: no permission, permission denied twice, no flash unit, a single lens, the camera failing to bind, a gallery video that cannot be read, a take ended by the 30 s cap. Expected: the permission view, no torch button, no lens switch, the failure line, "Không đọc được video này.", and Kiểm tra tin after 30 s. Pinned in Task 9 (`FrameGrabberTest`, `VideoFramesTest`) and Task 13 (`VideoScreenTest`).

---

## File structure

```
core/model/.../model/
  Draft.kt            DraftId, DraftOrigin, VideoTake, CategoryRef, AiMark (grows), PriceSource, DraftField, ListingDraft (new shape)
  Selling.kt          PriceSuggestion, PhotoReading, Finding, VideoReading, TakeCue, SellContext, CategoryGroup
  MyListings.kt       ListingStats, Sale, OwnListing, LiveCard, OrderNote, Asker, DraftCard, SoldCard, MyListings, BoostOffer, BoostSheet
  Plans.kt            PlanKey, PlanFeature, SellerPlan, PlanPage
  Commands.kt         two-sided SendOffer, AcceptCounter, ProposeMeeting, ConfirmMeeting (docs only; the wire is unchanged)
  MoneyKey.kt         + SERVICE_FEE
  Notifications.kt    NotificationTarget.MyListings
core/domain/.../domain/
  Posting.kt          PostProblem, postProblems, codAllowed, pathsFor, priceFromInput, estimateLabel, photoSourceLine
  Selling.kt          ageLabel, askerLine, openOrder, orderNote, soldBy, weekStats, boostOffers, planButton, counterRange, cutLabel
  DealConsole.kt      seller states
  Orders.kt           seller in-person statuses
core/data/.../data/
  Repositories.kt     SellRepository, MyListingsRepository, PlanRepository; DealRepository.handoverCode
  fake/FakeSellRepository.kt, FakeMyListingsRepository.kt, FakePlanRepository.kt, AiFakes.kt (photo read, video read, take script),
  fake/FakeDealEngine.kt (two sides), FakeWorld.kt (own listings, drafts, plan, verified, codes), Seeds.kt, Fixtures.kt,
  fake/Simulator.kt (buyers), fake/OrderJumps.kt (d-bao), DebugControls.kt
  tools/stage4_fixtures.py
core/data/src/main/resources/fixtures/  my-listings.json (new); account.json, people.json (edited)
core/designsystem/.../component/  Fields.kt (FilledField), ToggleRows.kt (SwitchRow, CheckboxRow), EmptyPane.kt, StepPill.kt,
                                  ListingCard.kt (meta)
core/ui/.../ui/camera/  CameraBinding.kt (moved from Scanner.kt), FrameGrabber.kt, VideoCamera.kt, VideoFrames.kt, CameraMode.kt (was ScanMode)
feature/sell/         SellInstaller, form/ (SellScreen, SellViewModel, SellForm state), video/ (VideoScreen, VideoViewModel),
                      review/ (ReviewScreen, ReviewViewModel), parts/ (PhotoRow, AiLine, Marks, PriceBlock, DeliveryBlock,
                      CategorySheet, SpecFields, EditSheets, PreviewSheet, GateSheet, DoneScreen, CloseDialogs)
feature/listings/     ListingsInstaller, mine/ (MyListingsScreen, MyListingsViewModel, BoostSheet, SoldSheet, DeleteDialog),
                      plans/ (PlansScreen, PlansViewModel)
feature/deal/         Console grows the seller states; CounterSheet
feature/orders/       sellmeet/ (SellMeetScreen, SellMeetViewModel), CodeSheet; OrderRouter, OrdersViewModel lines
```

---

### Task 1: Stage 4 routes and modules

**Files:**
- Modify: `core/navigation/.../Routes.kt`, `app/.../AppNavigation.kt` (installers), `settings.gradle.kts`, `app/build.gradle.kts`
- Create: `feature/sell/build.gradle.kts`, `feature/listings/build.gradle.kts`, their manifests, `SellInstaller.kt`, `ListingsInstaller.kt` (each route renders `PlaceholderScreen(title, 4)` until its task)
- Modify: `feature/placeholder/.../PlaceholderInstaller.kt` (Tôi links "Tin của bạn", "Gói người bán"), strings
- Test: `PlaceholderScreenTest`, `InstallersTest`

**Interfaces (Produces):**

```kotlin
@Serializable data class SellRoute(val draftId: String? = null, val editId: String? = null, val repostId: String? = null) : NavKey
@Serializable data object SellVideoRoute : NavKey
@Serializable data class SellReviewRoute(
    val frames: List<String> = emptyList(), val seconds: Int = 0, val fromLibrary: Boolean = false, val draftId: String? = null,
) : NavKey
/** [pane] is a `ListingPane` name: LIVE, DRAFT, SOLD. [posted] is a listing just posted, for the snackbar. */
@Serializable data class MyListingsRoute(val pane: String = "LIVE", val posted: String? = null) : NavKey
@Serializable data object PlansRoute : NavKey
```

- [ ] **Step 1: Failing tests.** `PlaceholderScreenTest.theMeTabListsSelling` (rows "Tin của bạn" and "Gói người bán" push `MyListingsRoute()` and `PlansRoute`; the four stage 3 rows stay). `InstallersTest`: twelve installers; the provider resolves every route in `Routes.kt`.
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :app:testDebugUnitTest :feature:placeholder:testDebugUnitTest --offline -q`.
- [ ] **Step 3: Implement.** Both modules use `shopnexus.android.feature`; `:app` depends on them.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add the stage 4 routes and modules`.

### Task 2: The stage 4 contract (`:core:model`)

**Files:** Modify `Draft.kt`, `MoneyKey.kt`, `Notifications.kt`, `Commands.kt` (docs); create `Selling.kt`, `MyListings.kt`, `Plans.kt`. Test: `core/model/src/test/.../SellingJsonTest.kt`.

**Interfaces (Produces):**

```kotlin
@JvmInline @Serializable value class DraftId(val value: String)
@Serializable enum class DraftOrigin { PHOTOS, VIDEO }
@Serializable enum class PriceSource { SPOKEN, TYPED }
/** The fields that can carry the sparkle. */
@Serializable enum class DraftField { TITLE, CATEGORY, CONDITION, SPECS, COLOR, DESCRIPTION, OFFERS }

/** A category the form offers: a catalog key and one of its subcategories, "Khác" inside it, or the last group "Khác" (key null). */
@Serializable data class CategoryRef(val key: String?, val sub: String?)

/** A take from Quay video or a gallery video: the sampled frames, the ones kept as photos, and its length. */
@Serializable data class VideoTake(val frames: List<Photo>, val picked: List<Int>, val seconds: Int, val fromLibrary: Boolean)

/** A mark the model saw, with its crop; the seller declares or dismisses it. */
@Serializable data class AiMark(val text: String, val closeUp: Photo, val decision: MarkDecision)

@Serializable
data class ListingDraft(
    val id: DraftId,
    val origin: DraftOrigin,
    val photos: List<Photo> = emptyList(),
    val video: VideoTake? = null,
    val title: String = "",
    val category: CategoryRef? = null,
    val condition: Condition? = null,
    val aiMarks: List<AiMark> = emptyList(),
    val marks: List<DeclaredMark> = emptyList(),
    val storage: String? = null,
    val color: String = "",
    val battery: Int? = null,
    val description: String = "",
    val price: Vnd? = null,
    val priceSource: PriceSource = PriceSource.TYPED,
    val allowOffers: Boolean = true,
    val paths: Set<HandoverPath> = setOf(HandoverPath.MEET, HandoverPath.COD),
    val aiFields: Set<DraftField> = emptySet(),
    /** The listing "Sửa tin" changes; null for a new listing. */
    val editing: ListingId? = null,
    val updatedAt: Moment? = null,
)

@Serializable enum class SuggestionKind { FAST, MARKET }
@Serializable data class PriceSuggestion(val kind: SuggestionKind, val price: Vnd, val days: String)

/** What the model read from photos: the values it filled, the mark it saw, and its price judgment. */
@Serializable
data class PhotoReading(
    val title: String, val category: CategoryRef, val condition: Condition, val storage: String?, val color: String,
    val description: String, val mark: AiMark?, val estimate: PriceRange, val suggestions: List<PriceSuggestion>,
)

@Serializable data class Finding(val icon: String, val text: String)

/** The video read as it goes: frames read so far, the kept ones once chosen, the findings so far, and the draft at the end. */
@Serializable
data class VideoReading(
    val read: Int, val kept: List<Int>? = null, val findings: List<Finding> = emptyList(),
    val estimate: PriceRange? = null, val draft: ListingDraft? = null,
)

@Serializable enum class CueKind { PROMPT, CAPTION, CHIP }
@Serializable data class TakeCue(val atMillis: Long, val kind: CueKind, val text: String)

@Serializable data class CategoryGroup(val key: String?, val label: String, val subs: List<String>)

/** What the form needs about the seller: identity, the area, the listing cap, the categories. */
@Serializable
data class SellContext(
    val verified: Boolean, val area: String, val district: String, val onSale: Int, val cap: Int,
    val categories: List<CategoryGroup>,
)

@Serializable data class ListingStats(val views: Int, val saves: Int)
@Serializable data class Sale(val buyer: UserId?, val at: Moment, val stars: Int? = null, val dealId: DealId? = null)

@Serializable
data class OwnListing(
    val listing: Listing,
    val hidden: Boolean = false,
    val total: ListingStats,
    val week: ListingStats,
    val boostedUntil: Moment? = null,
    val boostDays: Int? = null,
    val insight: PriceInsight? = null,
    val suggestedPrice: Vnd? = null,
    val sale: Sale? = null,
)

@Serializable enum class ListingPane { LIVE, DRAFT, SOLD }
@Serializable data class Asker(val person: SellerSummary, val line: String)
@Serializable data class OrderNote(val dealId: DealId, val icon: String, val text: String)

@Serializable
data class LiveCard(
    val summary: ListingSummary, val views: Int, val askers: Int, val saves: Int,
    /** "12 ngày", "Vừa đăng"; null while boosted. */
    val age: String?, val boostDays: Int?, val hidden: Boolean,
    val cut: PriceCut?, val order: OrderNote?, val people: List<Asker>,
)
/** The model's judgment on my price: "Cao hơn 12%", and the price "Giảm còn" sets. */
@Serializable data class PriceCut(val percent: Int, val price: Vnd)
@Serializable data class WeekStats(val views: Int, val askers: Int, val saves: Int)
@Serializable data class DraftCard(val id: DraftId, val origin: DraftOrigin, val photoUrl: String?, val title: String, val photos: Int, val price: Vnd?, val needsVerification: Boolean)
@Serializable data class SoldCard(val summary: ListingSummary, val buyer: SellerSummary?, val day: String, val stars: Int?, val pending: Boolean)

@Serializable
data class MyListings(
    val week: WeekStats, val live: List<LiveCard>, val drafts: List<DraftCard>, val sold: List<SoldCard>,
)

@Serializable data class BoostOffer(val days: Int, val fee: Vnd)
@Serializable
data class BoostSheet(val offers: List<BoostOffer>, val payWith: String, val plan: PlanKey, val boostsLeft: Int, val area: String)

@Serializable enum class PlanKey { BASIC, PLUS, SHOP }
@Serializable data class PlanFeature(val icon: String, val text: String)
@Serializable data class SellerPlan(val key: PlanKey, val name: String, val monthly: Vnd, val features: List<PlanFeature>, val boosts: Int)
@Serializable data class PlanPage(val plans: List<SellerPlan>, val current: PlanKey, val payWith: String)
```

`MoneyKey` gains `SERVICE_FEE` ("Phí dịch vụ trả cho ShopNexus, không hoàn, không liên quan tiền hàng."); `NotificationTarget` gains `@SerialName("myListings") data object MyListings`.

- [ ] **Step 1: Failing test.** `SellingJsonTest`: a `ListingDraft` with every field round-trips through `ShopNexusJson`; a draft written without the optional fields reads back with the defaults (`paths` both, `allowOffers` true); `OwnListing`, `MyListings`, `PlanPage` and `VideoReading` round-trip.
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :core:model:test --offline -q`.
- [ ] **Step 3: Implement.** Stage 1's `ListingDraft` users (`canPost`, its test) move to the new shape.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add the stage 4 contract`.

### Task 3: Selling rules (`:core:domain`)

**Files:** Modify `Posting.kt`; create `Selling.kt`. Tests: `PostingTest`, `SellingTest`.

**Interfaces (Produces):**

```kotlin
val COD_LIMIT = Vnd(5_000_000)
val MIN_PRICE = Vnd(10_000)
const val TITLE_MAX = 70
const val DESCRIPTION_MAX = 1500
const val PHOTOS_MAX = 10

enum class PostProblem { TITLE_EMPTY, PRICE_EMPTY, PRICE_LOW, MARK_PENDING, NO_PATH, CAP, UNVERIFIED }
fun postProblems(draft: ListingDraft, context: SellContext): List<PostProblem>
fun codAllowed(price: Vnd?): Boolean
/** The paths the draft can post with: COD leaves above the limit. */
fun pathsFor(draft: ListingDraft): Set<HandoverPath>
fun priceFromInput(text: String): Vnd?
fun estimateLabel(range: PriceRange): String
fun photoSourceLine(photos: List<Photo>): String
fun specsLine(draft: ListingDraft): String          // "64 GB · Pin 81% · Trắng"
fun showsPhoneSpecs(category: CategoryRef?): Boolean
fun categoryLabel(ref: CategoryRef, groups: List<CategoryGroup>): String   // "Điện thoại › iPhone", "Nội thất › Khác", "Khác"

fun ageLabel(postedAt: Instant, now: Instant): String
fun askerLine(deal: Deal, now: Instant, zone: ZoneId): String
fun openOrder(views: List<DealView>, listing: ListingId): DealView?
fun orderNote(view: DealView, now: Instant, zone: ZoneId): OrderNote
fun soldBy(own: OwnListing, views: List<DealView>): Sale?
fun weekStats(own: List<OwnListing>, views: List<DealView>, now: Instant): WeekStats
fun boostOffers(): List<BoostOffer>                 // 1 ngày 15.000 ₫, 3 ngày 35.000 ₫
fun boostsLeft(plan: SellerPlan, used: Int): Int
fun planButton(selected: SellerPlan, current: PlanKey): PlanButton   // label + enabled
fun counterRange(offer: Vnd, listed: Vnd): ClosedRange<Long>
fun counterPresets(offer: Vnd, listed: Vnd): List<Vnd>
```

- [ ] **Step 1: Failing tests.**
  - `PostingTest.problemsComeInTheFormsOrder`: an empty draft → `[TITLE_EMPTY, PRICE_EMPTY, NO_PATH]` when paths are empty; title "iPhone", price 9.000 ₫, a pending mark → `[PRICE_LOW, MARK_PENDING]`; a clean draft with `onSale == cap` → `[CAP]`; clean and unverified → `[UNVERIFIED]`; clean, unverified and `editing != null` → `[]`.
  - `codAllowedStopsAboveFiveMillion`: 5.000.000 ₫ true, 5.000.001 ₫ false, null true. `pathsForDropsCodAboveTheLimit`.
  - `priceInputKeepsDigits`: "4.500.000 ₫" → 4.500.000; "abc" → null; "" → null; "0012" → 12.
  - `theEstimateReadsInShortMillions`: 4.400.000 to 5.100.000 → `"Giá tham khảo 4,4 \u2013 5,1 tr ₫"`; 1.600.000 to 2.400.000 → `"Giá tham khảo 1,6 \u2013 2,4 tr ₫"` (the escapes the test writes).
  - `theSourceLineCountsAppPhotos`: three APP → "Cả 3 ảnh chụp trong app"; one APP → "Ảnh chụp trong app"; two APP and one LIBRARY → "2/3 ảnh chụp trong app".
  - `phoneSpecsShowForPhonesAndTablets`: iPhone, Android, Máy tính bảng true; "Điện thoại › Phụ kiện", Nội thất and "Khác" false.
  - `SellingTest.agesReadInHoursAndDays`: 10 min "Vừa đăng"; 3 h "3 giờ"; 12 days "12 ngày".
  - `askersSayWhatTheyDid`: an open buyer offer 1.800.000 → "Trả giá 1,8 tr"; a placed parcel yesterday → "Đặt COD hôm qua"; a meeting on Thursday → "Hẹn gặp thứ Năm"; a first message today → "Hỏi hôm nay".
  - `orderNotesFollowTheStatus`: d-huy TO_SHIP → "Đơn COD · gửi trước 18:00 thứ Sáu" (schedule_send); SHIPPING → "Đơn COD · đang giao"; a seller ARRANGING with the buyer's proposal → "Đơn gặp mặt · chờ bạn đồng ý hẹn"; WAITING → "Đơn gặp mặt · 18:00 thứ Năm"; RECORD_OPEN → "Ghi nhận sự cố · trả lời trong 3 ngày".
  - `aHandedOverDealSellsTheListing`: a RATE deal on the listing → `Sale(buyer, handedOverAt, null, dealId)`; a DONE deal rated 5 → stars 5; no deal → the stored `Sale`; a refused parcel does not sell it.
  - `theWeekSumsListingsOnSale`: guitar week 31/2 and stool 24/1 with deals d-quang (today) and d-huy (yesterday) → 55, 2, 3; a sold listing does not count.
  - `planBoostsCountDown`, `thePlanButtonNamesTheChange`: current BASIC selected BASIC → "Đang dùng Cơ bản" disabled; PLUS → "Dùng Plus · 49.000 ₫/tháng"; current PLUS selected BASIC → "Về gói Cơ bản".
  - `aCounterSitsBetweenOfferAndListed`: offer 1.800.000, listed 1.900.000 → range 1.800.001..1.899.999; presets for 4.000.000 and 4.500.000 → 4.150.000, 4.350.000 (a third and two thirds, rounded to 50.000 ₫, dropped when outside the range).
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :core:domain:test --offline -q`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add the selling rules`.

### Task 4: Seller deal rules

**Files:** Modify `core/domain/.../DealConsole.kt`, `Orders.kt`; `core/data/.../fake/FakeDealEngine.kt`. Tests: `DealConsoleTest`, `OrdersTest`, `FakeDealEngineTest`.

**Interfaces (Produces):**

```kotlin
// ConsoleState grows:
data class Offered(val offer: Vnd, val listed: Vnd) : ConsoleState          // the buyer's offer open, me selling
data class Countered(val counter: Vnd) : ConsoleState                        // my counter open, me selling
data class SellerArranging(val meeting: Meeting?, val mine: Boolean) : ConsoleState
// SellerMeeting(meeting) gains the "Hiện mã giao dịch" action in the UI (Task 17).
```

`orderStatus` for a seller in person returns ARRANGING, WAITING, MET, REVIEWED, CANCELLED and the RECORD_* states, as for the buyer. The engine: `SendOffer` from the seller requires an open buyer offer and an amount in `counterRange`, closes the buyer's offer as COUNTERED and opens a seller offer; `AcceptCounter` from the seller accepts the open buyer offer (`agreed`); `ProposeMeeting` from the seller requires ARRANGE or HANDOVER on a MEET deal and sets `proposedBy = SELLER`; `ConfirmMeeting` confirms the other side's proposal from either side; `RecordHandover`, `Rate`, `ReceiveParcel` stay the buyer's; `CancelMeeting`, `RefundRecord`, `DeclineRecord` work for the seller in person.

- [ ] **Step 1: Failing tests.** `DealConsoleTest.aSellerSeesTheBuyersOffer` (d-quang with a buyer offer 1.800.000 → `Offered(1.800.000, 1.900.000)`); `aSellersCounterWaits`; `aSellerConfirmsTheBuyersProposal` (`SellerArranging(meeting, mine = false)`); `aSellerWaitsOnTheirOwnProposal`. `OrdersTest.aSellerInPersonHasTheBuyersStates` (ARRANGING, WAITING, MET, REVIEWED for d-bao moved through them). `FakeDealEngineTest.aSellerCountersInsideTheRange` (1.850.000 ok, 1.800.000 and 1.900.000 refused), `aSellerAcceptsTheOpenOffer` (stage ARRANGE, agreed price, AGREED milestone, a PriceMove by the seller), `aSellerCannotAcceptWithoutAnOffer`, `eitherSideConfirmsTheOthersProposal`, `nobodyConfirmsTheirOwnProposal`, `aSellerCannotProposeOnCod`, `aSellerCancelsInPersonWithThePenalty`.
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :core:domain:test :core:data:testDebugUnitTest --offline -q`.
- [ ] **Step 3: Implement.** Thread items for the seller: `PriceMove(SELLER, amount, false)` for a counter, `PriceMove(SELLER, price, true)` + AGREED for an accept, "Mình đổi sang {giờ} · {nơi} được không bạn?" by the seller for a proposal, the stage 3 event for a confirmation.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: give the seller their half of a deal`.

### Task 5: Stage 4 fixtures

**Files:** Create `core/data/tools/stage4_fixtures.py`, `core/data/src/main/resources/fixtures/my-listings.json`; modify `account.json`, `people.json`, `Seeds.kt` (`AccountSeed` gains `verified`, `plan`, `boostsUsed`, `area`, `district`, `plans`; `MyListingsSeed(listings: List<OwnListing>, drafts: List<ListingDraft>)`), `Fixtures.kt` (`myListings()`); commit `app2/.superdesign/stage4-digest.md`; save the new photos with `fetch_photos.py` (the iPhone 11 crops at 480, 240 and 900 px, the eight frame crops, the books). Test: `FixturesTest`.

`my-listings.json`:

```json
{
  "listings": [
    { "listing": { "id": "my-guitar", "sellerId": "u-linh", "title": "Đàn guitar Yamaha F310", "price": 1900000,
        "categoryPath": ["Khác"], "condition": "USED", "declaredMarks": [], "photos": [{ "url": "…1525201548942-d8732f6617a0…", "source": "APP" }],
        "specs": [{ "label": "Màu", "value": "Gỗ tự nhiên" }], "description": "Đàn mua 2022, dây mới thay tháng trước. Kèm bao đàn và capo.",
        "district": "Bình Thạnh", "distanceKm": 0.0, "paths": ["MEET", "COD"], "allowOffers": true, "postedAt": "2026-10-04T…", "meetNote": "" },
      "total": { "views": 86, "saves": 5 }, "week": { "views": 31, "saves": 2 },
      "insight": { "direction": "PRICIER", "percent": 12 }, "suggestedPrice": 1700000 },
    { "listing": { "id": "my-stool", "title": "Ghế đôn gỗ cao", "price": 350000, "categoryPath": ["furniture", "Khác"], … },
      "total": { "views": 24, "saves": 1 }, "week": { "views": 24, "saves": 1 } },
    { "listing": { "id": "my-shelf", "title": "Kệ gỗ nhỏ 3 tầng", "price": 650000, "categoryPath": ["furniture", "Tủ, kệ"], … },
      "total": { "views": 61, "saves": 4 }, "week": { "views": 0, "saves": 0 } },
    { "listing": { "id": "my-books", "title": "Combo 9 sách khởi nghiệp", "price": 450000, "categoryPath": ["Khác"], … },
      "total": { "views": 40, "saves": 3 }, "week": { "views": 0, "saves": 0 },
      "sale": { "buyer": "u-trang", "at": "2026-09-28T…", "stars": 5 } }
  ],
  "drafts": [ { "id": "dr-iphone11", "origin": "PHOTOS", "photos": [three APP crops], "title": "iPhone 11 64GB Trắng, máy zin",
      "category": { "key": "phones", "sub": "iPhone" }, "condition": "USED", "aiMarks": [{ "text": "Xước nhẹ ở mặt lưng", "closeUp": …, "decision": "PENDING" }],
      "storage": "64 GB", "color": "Trắng", "description": "Máy dùng 3 năm, …", "aiFields": ["TITLE", "CATEGORY", "CONDITION", "COLOR", "DESCRIPTION"],
      "updatedAt": "2026-10-15T14:40:00Z" } ]
}
```

`categoryPath` holds the catalog key and the subcategory (`["phones", "iPhone"]`), or `["Khác"]`. `account.json` gains `"verified": false, "plan": "BASIC", "boostsUsed": 0, "area": "Bình Thạnh, TP.HCM", "district": "Bình Thạnh"` and the three plans with the mockup's features. `people.json` gains `u-trang` Thu Trang and `u-vy` Thảo Vy (Phú Nhuận, no photo, Mới, joined 2026).

- [ ] **Step 1: Failing test.** `FixturesTest.myListingsMatchTheMockups`: four listings with the ids the deals use, the guitar at 1.900.000 ₫ with 86 views and "Cao hơn 12%", the books sold to Thu Trang with 5 stars, the draft with three APP photos, no price and one pending mark; `theAccountStartsUnverifiedOnBasic`; `peopleIncludeThuTrangAndThaoVy`; every photo URL resolves to a file under `core/testing` (the stage 2 photo check).
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :core:data:testDebugUnitTest --offline -q`.
- [ ] **Step 3: Implement** with the script writing the JSON; fetch the photos.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add the stage 4 fixtures`.

### Task 6: Fake repositories

**Files:** Modify `Repositories.kt`, `FakeWorld.kt` (`own: Map<ListingId, OwnListing>`, `drafts: Map<DraftId, ListingDraft>`, `plan: PlanKey`, `boostsUsed: Int`, `verified: Boolean`, `codes: Map<DealId, String>`, `nextId: Int`), `FakeDealRepository.kt` (`handoverCode`), `di/DataModule.kt`; create `FakeSellRepository.kt`, `FakeMyListingsRepository.kt`, `FakePlanRepository.kt`, `AiFakes.kt`. Tests: `FakeSellRepositoryTest`, `FakeMyListingsRepositoryTest`, `FakePlanRepositoryTest`, `FakeDealRepositoryTest`.

```kotlin
interface SellRepository {
    fun context(): Flow<SellContext>
    fun draft(id: DraftId): Flow<ListingDraft?>
    /** The listing as a draft for "Sửa tin" ([repost] false) or "Đăng lại" ([repost] true: a new draft, no `editing`). */
    fun fromListing(id: ListingId, repost: Boolean): Flow<ListingDraft?>
    suspend fun takeScript(): Result<List<TakeCue>>
    suspend fun readPhotos(photos: List<Photo>): Result<PhotoReading>
    fun readVideo(take: VideoTake): Flow<VideoReading>
    suspend fun saveDraft(draft: ListingDraft): Result<DraftId>
    suspend fun post(draft: ListingDraft): Result<ListingId>
    suspend fun saveListing(id: ListingId, draft: ListingDraft): Result<Unit>
}
interface MyListingsRepository {
    fun listings(): Flow<MyListings>
    fun boostSheet(id: ListingId): Flow<BoostSheet>
    suspend fun setPrice(id: ListingId, price: Vnd): Result<Vnd>
    suspend fun setHidden(id: ListingId, hidden: Boolean): Result<Unit>
    suspend fun boost(id: ListingId, days: Int): Result<Unit>
    suspend fun markSold(id: ListingId, buyer: UserId?): Result<Unit>
    suspend fun unmarkSold(id: ListingId): Result<Unit>
    suspend fun delete(id: ListingId): Result<Unit>
    suspend fun deleteDraft(id: DraftId): Result<Unit>
}
interface PlanRepository {
    fun plans(): Flow<PlanPage>
    suspend fun choose(key: PlanKey): Result<Unit>
}
// DealRepository: suspend fun handoverCode(id: DealId): Result<String>
```

`post` turns the draft into an `OwnListing` (`my-<n>`, `postedAt` now, the picked frames or photos, `pathsFor`, zero stats), deletes the draft, and tells the simulator (`CounterpartListener.onPosted(listingId)`); it fails with `IllegalStateException` naming the first `postProblems` entry. `readPhotos` waits 1.8 s on the clock's dispatcher; `readVideo` emits the timeline of the spec; all go through `FailurePolicy`.

- [ ] **Step 1: Failing tests.**
  - `FakeSellRepositoryTest`: `theContextStartsUnverifiedWithTwoOnSale`; `aReadFillsThePhotoValuesAfterTheDelay` (virtual time: nothing at 1.7 s, the reading at 1.8 s with title "iPhone 11 64GB Trắng, máy zin", the mark pending, suggestions 4.500.000 and 4.800.000); `theVideoReadFollowsTheTimeline` (read = 1 at 0 s … 8 by 2.1 s, kept `[0, 2, 3, 4]` at 2.4 s, four findings by 2.15 s, the draft at 3.3 s with title "iPhone 11 64GB Trắng, pin 81%", battery 81, price 4.500.000 SPOKEN, the mark DECLARED with frame 4); `savingADraftListsItNewestFirst`; `postingMakesALiveListingAndDropsTheDraft`; `postingRefusesAnUnverifiedPerson`; `postingRefusesAtTheCap`; `savingAListingKeepsItsIdAndStats`; `aRepostIsANewDraftFromTheSoldListing`; a failing policy fails each call.
  - `FakeMyListingsRepositoryTest`: `theWorldStartsWithTheMockupsPanes` (live guitar then stool, one draft, sold shelf "Thứ Hai" 5 stars then books "28/9" 5 stars; week 55, 2, 3); `theStoolIsReserved` (order note "Đơn COD · gửi trước 18:00 thứ Sáu"); `aPriceCutReturnsTheOldPriceAndHidesTheSuggestion`; `hidingKeepsTheCardInLive`; `aBoostLeadsLiveAndUsesAPlanBoostFirst`; `markingSoldMovesTheCard` and `unmarkingPutsItBack`; `aReservedListingRefusesSaleBoostAndDelete`; `deletingADraftRemovesIt`; `aHandedOverDealSellsTheListing` (a d-huy jump to RECEIVED moves the stool to sold with Đức Huy, pending).
  - `FakePlanRepositoryTest.choosingMovesTheCurrentPlan`.
  - `FakeDealRepositoryTest.aCodeIsIssuedForAWaitingSellerMeeting` and refused for a buyer or a COD deal.
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :core:data:testDebugUnitTest --offline -q`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add the selling fakes`.

### Task 7: Simulator and debug

**Files:** Modify `Simulator.kt`, `CounterpartListener.kt` (`onPosted`, `onCodeIssued`, `onSoldTo`), `OrderJumps.kt` (d-bao), `DebugControls.kt` (identity switch, "Camera giả lập"), the debug panel in `:app`, `FakeNotificationRepository` (new rows). Tests: `SimulatorTest`, `OrderJumpsTest`, `DebugPanelTest`.

Timings (virtual time, scaled by `speed`): after `onPosted`, views 5 at 4 s and 12 at 8 s; at 8 s Thảo Vy's deal starts with "Món này còn không bạn?" (unread 1, notification "Thảo Vy hỏi về {shortTitle}" DEAL, chat icon, target Chat); at 12 s, with offers on, her offer (90 % rounded down to 100.000 ₫) and "Bớt chút được không bạn?". After the seller's `SendOffer` (a counter), she accepts at 2.4 s. After agreement (either accept), at 2.4 s: COD open and price ≤ limit → "Ok bạn, mình đặt COD nhé." and the parcel placed with Giao nhanh (the stage 3 carrier then follows `ShipParcel`); otherwise "Mình hẹn {giờ} · {nơi} được không bạn?" with a buyer proposal tomorrow 18:00 at the first meet point. A seller's `ProposeMeeting` is confirmed at 2.4 s. `onCodeIssued` → `RecordHandover` by the buyer at 3 s if the code is still the issued one. A hand-over or a received parcel on my listing → `Rate(5)` by the buyer at 4 s; `onSoldTo(buyer)` → the sale's stars at 4 s unless unmarked first.

- [ ] **Step 1: Failing tests.** `SimulatorTest.aPostedListingDrawsAQuestionAndAnOffer`, `noOfferWhenOffersAreOff`, `aCounterIsAccepted`, `anAgreedListingWithCodIsPlaced`, `anAgreedMeetOnlyListingGetsAProposal`, `aSellersProposalIsConfirmed`, `aScanWaitsForAnIssuedCode`, `aHandOverIsRatedFiveStars` (d-huy after `ShipParcel` reaches RATE at 3.2 s and DONE with 5 stars at 7.2 s), `anUndoneSaleDropsItsRating`. `OrderJumpsTest.dBaoJumpsThroughTheSellerStates`. `DebugPanelTest.theIdentitySwitchVerifies` and the camera switch label.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Stage 3 tests that expect the stool order to stay RECEIVED after receipt advance their clocks by less than 4 s or assert REVIEWED; ledger each change under ruling 12.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: let a simulated buyer answer the seller`.

### Task 8: Design-system components

**Files:** Create `Fields.kt` (`FilledField(value, onValue, label, modifier, counterMax, error, sparkle, keyboard, singleLine, minLines, suffix)`), `ToggleRows.kt` (`SwitchRow(icon, text, checked, onChecked, sparkle)`, `CheckboxRow(icon, title, sub, checked, enabled, onChecked)`), `EmptyPane.kt` (`EmptyPane(icon, line, action?)`), `StepPill.kt` (`StepPill(step, names, dark)`); modify `ListingCard.kt` (`meta: String? = null` replaces the condition · distance line). Strings in `:core:designsystem`. Tests: `FieldsTest`, `ToggleRowsTest`, `EmptyPaneTest`, `StepPillTest`, `ListingCardTest` (grows), screenshots for each.

- [ ] **Step 1: Failing tests.** `FieldsTest.theCounterStopsInputAtTheLimit` (typing 75 characters keeps 70, reads "70/70"); `anErrorShowsUnderTheTileInError` (the error text, the error ring colour by pixel); `theSparkleNamesItself` ("AI đã điền"). `ToggleRowsTest.aDisabledCheckboxRowDims` (alpha 0.6 by pixel, not toggleable); `aSwitchRowIsOneToggle` (role Switch, state). `EmptyPaneTest.itNamesWhatIsMissingAndOffersOneAction`. `StepPillTest.theCurrentDotIsWide` (24 dp vs 8 dp; content description "Bước 2 trên 3: Kiểm tra"). `ListingCardTest.aPreviewShowsTheDistrict` ("Đã dùng · Bình Thạnh"). Each at font scale 1.3 with `assertNoClippedText`; screenshots light and dark.
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :core:designsystem:testDebugUnitTest --offline -q`.
- [ ] **Step 3: Implement.** Tiles: `surfaceContainerHigh`, 16 dp corners, padding 16/8/16/10 dp, 2 dp inset ring `primary` on focus and `error` with an error.
- [ ] **Step 4: Run, expect PASS** and record the screenshots, then the gate.
- [ ] **Step 5: Commit** `feat: add the form components`.

### Task 9: Camera pieces (`:core:ui`)

**Files:** Move `CameraBinding` out of `Scanner.kt` into `camera/CameraBinding.kt`; rename `ScanMode` to `camera/CameraMode.kt` (the scanner keeps working); create `camera/FrameGrabber.kt`, `camera/VideoCamera.kt`, `camera/VideoFrames.kt`. Tests: `FrameGrabberTest`, `VideoFramesTest`, `VideoCameraTest`, `ScannerTest` (unchanged, still green).

```kotlin
/** Keeps one frame every [everyMillis] while [recording], saved as JPEG under the cache's `sell/take-<id>/`. */
class FrameGrabber(private val folder: File, private val everyMillis: Long = 1_500, private val clock: () -> Long) : ImageAnalysis.Analyzer
/** [frames] spread evenly: 8 kept of n ≥ 8, all of fewer. */
fun spread(frames: List<File>, keep: Int = 8): List<File>
/** Eight frames at even times of a picked video, or null when it cannot be read. */
suspend fun videoFrames(context: Context, uri: Uri, folder: File, count: Int = 8): Pair<List<File>, Int>?
@Composable fun VideoCamera(mode: CameraMode, recording: Boolean, torch: Boolean, front: Boolean, onState: (CameraState) -> Unit, onFrames: ..., modifier: Modifier)
data class CameraState(val hasFlash: Boolean, val lenses: Int, val failed: Boolean)
```

- [ ] **Step 1: Failing tests.** `FrameGrabberTest.itKeepsOneFrameEveryInterval` (fake clock: frames at 0, 1.0, 1.6, 3.0, 3.2 s → three saved), `nothingIsSavedWhileNotRecording`. `spread` keeps indexes 0, 2, 4, … of 16 and all of 5. `VideoFramesTest.anUnreadableVideoGivesNull` (a text file). `VideoCameraTest.simulatedModeShowsTheCropsAndYieldsEightFrames` (the five crops cross-fade every 2.6 s; stopping returns the eight fixture frames); `theTorchHidesWithoutAFlashUnit` (state `hasFlash = false`).
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :core:ui:testDebugUnitTest --offline -q`.
- [ ] **Step 3: Implement.** CameraX binds Preview + the analyzer with `CameraBinding`; the torch through `CameraControl.enableTorch`; the lens switch rebinds with the other selector; `hasFlash` from `CameraInfo.hasFlashUnit()`.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add the camera pieces for video listings`.

### Task 10: Sell parts (`:feature:sell`)

**Files:** Create `parts/PhotoRow.kt`, `AiLine.kt`, `Marks.kt`, `PriceBlock.kt`, `DeliveryBlock.kt`, `CategorySheet.kt`, `SpecFields.kt`, `EditSheets.kt` (text, choice, price), `PreviewSheet.kt`, `GateSheet.kt`, `DoneScreen.kt`, `CloseDialogs.kt`; strings. Tests: one `…Test` per part plus screenshots.

- [ ] **Step 1: Failing tests.** `PhotoRowTest`: badges "Chụp trong app"/"Từ thư viện", "Ảnh bìa" on the first, "Xóa ảnh Ảnh 2" removes the second, the add tile hides at 10 and opens a menu "Chụp ảnh"/"Chọn ảnh", "3/10". `MarksTest`: the suggestion with "Bỏ qua" and "Khai vết này"; a declared row with "Ảnh cận chụp trong app · 16/10" and "Bỏ vết này"; a seller row with "Mô tả vết"; the declared-marks sentence last; the error "Khai hoặc bỏ qua vết AI thấy.". `PriceBlockTest`: the estimate in `tertiary`; tapping "Bán nhanh" fills 4.500.000 ₫ and checks its panel; typing "4800000" checks "Giá thị trường"; the switch row. `DeliveryBlockTest`: COD on shows two sentences; at 6.000.000 ₫ COD is unchecked, disabled, reads "Chỉ cho món đến 5 triệu" and the over-limit sentence shows; the area row with "Chỉ hiện quận" and "Đổi". `CategorySheetTest`: groups by category, each ending in "Khác", the last group "Khác"; picking saves after 180 ms. `SpecFieldsTest`: phone categories show Dung lượng (32 … 512 GB), Màu, Pin (%) with "Cài đặt › Pin"; Nội thất shows Màu only. `EditSheetsTest`: an empty text is not saved and the sheet stays; the price sheet keeps digits; choice rows save on a different pick. `PreviewSheetTest`: "Chưa có giá", "Chưa có tiêu đề", the meta "Đã dùng · Bình Thạnh", the image named by its title. `GateSheetTest`: title "Xác minh để đăng tin" is the sheet's name, "2 phút", "Tin được lưu nháp", the three steps, both buttons. `DoneScreenTest`: "Đã đăng tin" as a polite live region, the line, the two buttons per origin. `CloseDialogsTest`: "Lưu nháp tin này?" and "Bỏ thay đổi?" with their bodies and buttons. Font scale 1.3 for each; `isLineEllipsized` false for every label and button.
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :feature:sell:testDebugUnitTest --offline -q`.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS** and record the screenshots, then the gate.
- [ ] **Step 5: Commit** `feat: add the parts of the sell forms`.

### Task 11: Đăng tin state (`SellViewModel`)

**Files:** Create `form/SellViewModel.kt`, `form/SellForm.kt` (pure form state and its reducer). Tests: `SellFormTest`, `SellViewModelTest`.

```kotlin
enum class FormPhase { EMPTY, READING, READ_FAILED, FILLED, POSTING, DONE }
data class SellUiState(
    val mode: SellMode,                       // NEW, DRAFT, EDIT, REPOST
    val phase: FormPhase,
    val draft: ListingDraft,
    val reading: PhotoReading?,               // the estimate and suggestions
    val context: SellContext?,
    val problems: List<PostProblem>,          // shown after the first "Đăng tin"
    val dirty: Boolean,                       // changes since the last save
    val sheet: SellSheet?,                    // CATEGORY, PREVIEW, GATE
    val dialog: SellDialog?,                  // SAVE_DRAFT, DISCARD_EDIT
    val saving: Boolean,
)
sealed interface SellEvent {
    data class AddPhotos(val photos: List<Photo>) : SellEvent      // the first add starts the read
    data class RemovePhoto(val index: Int) : SellEvent
    data object RetryRead : SellEvent
    data class Title(val text: String) : SellEvent
    data class Category(val ref: CategoryRef) : SellEvent
    data class Condition(val value: vn.shopnexus.core.model.Condition) : SellEvent
    data object DeclareMark : SellEvent
    data object DismissMark : SellEvent
    data class AddMark(val closeUp: Photo) : SellEvent
    data class MarkText(val index: Int, val text: String) : SellEvent
    data class RemoveMark(val index: Int, val ai: Boolean) : SellEvent
    data class Storage(val value: String) : SellEvent
    data class Color(val text: String) : SellEvent
    data class Battery(val text: String) : SellEvent
    data class Description(val text: String) : SellEvent
    data class Price(val text: String) : SellEvent
    data class Suggest(val kind: SuggestionKind) : SellEvent
    data class Offers(val on: Boolean) : SellEvent
    data class Path(val path: HandoverPath, val on: Boolean) : SellEvent
    data class Open(val sheet: SellSheet?) : SellEvent
    data object SaveDraft : SellEvent
    data object Post : SellEvent
    data object Later : SellEvent                 // the gate's "Để sau"
    data object Verify : SellEvent                // the gate's "Xác minh ngay"
    data object Close : SellEvent
    data class ConfirmClose(val save: Boolean) : SellEvent
    data object Another : SellEvent               // "Đăng món khác"
}
sealed interface SellEffect { Saved(withView: Boolean), Posted(id), Problem(first), Close, OpenVerification, Verified, Failed(message) }
```

- [ ] **Step 1: Failing tests.** `SellFormTest` (pure): `editingAFieldDropsItsSparkle`; `conditionDropsTheSparkleOnlyOnAChange`; `aNewReadRestoresEverySparkle`; `thePriceOverTheLimitDropsCod` and `codStaysOffWhenThePriceComesBack`; `removingTheLastPhotoEmptiesTheForm`; `dismissingADeclaredAiMarkMarksItDismissed`; `anEmptySellerMarkIsDroppedOnPosting`. `SellViewModelTest` on virtual time: `theFirstPhotosStartTheRead` (READING, then FILLED at 1.8 s with the fixture values), `laterPhotosAreNotRead`, `aFailedReadOffersRetry`, `postingShowsTheFirstProblem` (effect `Problem(TITLE_EMPTY)` and the list), `anUnverifiedPostOpensTheGate`, `laterSavesTheDraft` (`Saved(false)`), `verifySavesAndOpensVerification`, `becomingVerifiedShowsTheSnackbar` (flip the world's switch while subscribed), `aVerifiedPostShowsDone` (POSTING then DONE; the world has a new live listing), `aFailedPostKeepsTheForm`, `closingWithChangesAsks`, `closingUntouchedCloses`, `theFormSurvivesRecreation` (a `SavedStateHandle` with the encoded draft), `aReadInFlightSurvivesRecreation` (restart the read), `aDraftOpensWithItsValues` (`SellRoute(draftId = "dr-iphone11")`: three photos, the pending mark, FILLED, no read), `editingOpensTheListingWithoutTheGate`, `aRepostIsANewListing`, `anotherStartsEmpty`, `theCapIsASnackbar`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** The draft lives in `SavedStateHandle` as JSON (`ShopNexusJson`); `dirty` compares with the last saved draft.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add Đăng tin's state`.

### Task 12: Đăng tin screen

**Files:** Create `form/SellScreen.kt`, the route entry in `SellInstaller`; strings. Tests: `SellScreenTest`, screenshots.

Layout per the spec (app bar, banner, three states, docked bar). "Chụp ảnh" uses `rememberTakePhoto("sell")`; "Chọn ảnh" the Photo Picker (`PickMultipleVisualMedia(10)`); "Thêm vết, chụp cận" the camera only. A problem scrolls its block to a third of the viewport and requests focus after 300 ms.

- [ ] **Step 1: Failing tests.** `SellScreenTest` (state-based through `sellUiState()` and with the ViewModel): EMPTY shows the upload area and both buttons, the docked buttons disabled; READING shows "Đang đọc ảnh…" as a status; FILLED shows "AI đã điền từ 3 ảnh", "29/70", "146/1500", the meaning "Có vết thấy rõ hoặc lỗi nhỏ", Dung lượng and Màu side by side (same top), the estimate line for 4,4 and 5,1; the banner while unverified and not when verified; the edit mode's app bar "Sửa tin", the docked "Lưu", no "Lưu nháp" and no banner; "Chụp ảnh" with a stubbed `ActivityResultRegistryOwner` adds an APP photo and starts the read; "Đăng tin" on an empty title scrolls "Tiêu đề" into view and focuses it; the gate opens and "Để sau" shows "Đã lưu nháp"; "Lưu nháp" shows "Đã lưu nháp" with "Xem"; back with changes opens the dialog; the done screen's "Xem tin của bạn" navigates to `MyListingsRoute(posted = id)` by `replace`. Screenshots: EMPTY, READING, FILLED (top and scrolled to Giá bán and Giao dịch), errors, gate, preview, done, edit; light, dark, Material You and font scale 1.3 for FILLED.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Đăng tin`.

### Task 13: Quay video

**Files:** Create `video/VideoViewModel.kt`, `video/VideoScreen.kt`; strings. Tests: `VideoViewModelTest`, `VideoScreenTest`, screenshots.

```kotlin
data class VideoUiState(
    val recording: Boolean, val elapsedMillis: Long, val prompt: String?, val caption: String?, val chips: List<String>,
    val paused: Boolean, val dialog: Boolean, val torch: Boolean, val front: Boolean, val camera: CameraState?,
)
sealed interface VideoEvent { Record, Stop, Close, Stay, Leave, Torch, Flip, Camera(state), Frames(files, seconds), Picked(uri) }
sealed interface VideoEffect { TooShort, Review(frames, seconds, fromLibrary), Close, Unreadable }
```

The ViewModel ticks the elapsed time every 100 ms while recording and not paused (a `WhileSubscribed` job, Review Focus lesson: no endless ticker in `viewModelScope` collected eagerly), shows the cues at or before the elapsed time, and stops at 30 s.

- [ ] **Step 1: Failing tests.** `VideoViewModelTest`: `cuesFollowTheTake` (at 2.7 s: prompt "Quay mặt trước", caption "Đây là iPhone 11 bản 64 GB màu trắng.", chips "iPhone 11", "64 GB"); `aShortTakeIsDropped` (stop at 2.9 s → `TooShort`, chips cleared, not recording); `aLongTakeOpensReview` (stop at 12 s → `Review(8 frames, 12, false)`); `thirtySecondsStopsTheTake`; `closingPausesAndAsks` (elapsed frozen while the dialog shows), `stayResumesWithTheTimeKept`; `leaveCloses`; `aPickedVideoOpensReviewFromTheLibrary`; `anUnreadableVideoSaysSo`. `VideoScreenTest`: ready shows "Quay món đồ bạn muốn bán" and the three tips; the record button reads "Bắt đầu quay", then "Dừng quay" while recording and "Bắt đầu quay" after a dropped take; the timer pill "0:07"; the chips region "AI nhận ra" is a polite live region; "Đèn flash" hides without a flash unit; "Đổi camera" hides with one lens; the dialog "Bỏ video này?" with "Video chưa được lưu.", "Ở lại", "Bỏ"; the step pill "Bước 1 trên 3: Quay"; back during a take opens the dialog. Screenshots: ready, recording at 7 s (simulated), dialog, permission view.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.** Black background and white status bar icons through `enableEdgeToEdge`'s dark style while the screen shows.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Quay video`.

### Task 14: Kiểm tra tin

**Files:** Create `review/ReviewViewModel.kt`, `review/ReviewScreen.kt`, `review/FramePicker.kt`; strings. Tests: `ReviewViewModelTest`, `ReviewScreenTest`, screenshots.

```kotlin
data class ReviewUiState(
    val reading: VideoReading?, val phase: FormPhase,     // READING until the draft arrives, then FILLED, POSTING, DONE
    val draft: ListingDraft, val estimate: PriceRange?, val context: SellContext?,
    val sheet: ReviewSheet?,                              // TITLE, PRICE, CATEGORY, CONDITION, SPECS, DESCRIPTION, DELIVERY, FRAMES, PREVIEW, GATE
    val framePick: List<Int>?, val pickChanged: Boolean, val playing: Boolean, val problems: List<PostProblem>, val dirty: Boolean, val dialog: SellDialog?,
)
```

Events mirror `SellEvent` where the forms share a field, plus `PlayVideo`, `ToggleFrame(i)`, `DoneFrames`, `SaveText(field, text)`, `SaveChoice`, `SaveSpecs(storage, color, battery)`, `SavePaths`.

- [ ] **Step 1: Failing tests.** `ReviewViewModelTest` on virtual time: `theReadingFillsTheDraft` (READING, findings in order, FILLED at 3.3 s with title "iPhone 11 64GB Trắng, pin 81%", price SPOKEN 4.500.000, photos = frames 0, 2, 3, 4); `savingAnUnchangedTextDropsItsSparkle`; `aChoiceDropsTheSparkleOnlyOnAChange`; `thePriceSheetMarksThePriceTyped`; `aSpokenPriceOverTheLimitMeetsOnly` (save 6.000.000 → paths MEET, Cách giao "Gặp mặt"); `pickingFramesReplacesTheFramePhotos` (pick 1 and 5 → photos are frames 1 and 5 then added photos); `pickedFramesSurviveRecreation`; `theChecksMatchDangTin` (clear the title → `Problem(TITLE_EMPTY)`); `aResumedVideoDraftOpensFilled`; `aLibraryVideoSaysSo` (source line "Ảnh lấy từ video trong thư viện", photos LIBRARY). `ReviewScreenTest`: the reading's frame strip "Khung hình" and four findings; the video tile "Phát video 0:12"; "Bạn nói trong video" then "Bạn đã sửa giá"; rows at least 72 dp tall; the frame picker note "AI chọn 4 khung rõ nhất" then "Đã chọn 2 khung", "Xong" disabled at zero; the spoken mark "Khung hình 0:07 · bạn nói trong video" with "Bỏ vết này"; the step pill "Bước 2 trên 3: Kiểm tra"; the done screen's "Về Khám phá" pops to Home. Screenshots: reading at 1.2 s, the draft (top, scrolled), each sheet, the frame picker, done; four variants for the draft.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Kiểm tra tin`.

### Task 15: Tin của bạn

**Files:** Create `mine/MyListingsViewModel.kt`, `mine/MyListingsScreen.kt`, `mine/BoostSheet.kt`, `mine/SoldSheet.kt`, `mine/DeleteDialog.kt`; strings. Tests: `MyListingsViewModelTest`, `MyListingsScreenTest`, screenshots.

```kotlin
data class MyListingsUiState(
    val content: Loadable<MyListings>, val pane: ListingPane, val menu: ListingId?, val draftMenu: DraftId?,
    val boost: BoostState?, val sold: SoldState?, val delete: DeleteTarget?, val busy: Set<ListingId>,
)
sealed interface MyListingsEvent {
    data class Pane(val pane: ListingPane) : MyListingsEvent
    data class Cut(val id: ListingId) : MyListingsEvent
    data class Undo(val token: UndoToken) : MyListingsEvent
    data class Menu(val id: ListingId?) : MyListingsEvent
    data class Hide(val id: ListingId, val on: Boolean) : MyListingsEvent
    data class AskBoost(val id: ListingId) : MyListingsEvent
    data class BoostDays(val days: Int) : MyListingsEvent
    data object PayBoost : MyListingsEvent
    data class AskSold(val id: ListingId) : MyListingsEvent
    data class Buyer(val id: UserId?) : MyListingsEvent
    data object ConfirmSold : MyListingsEvent
    data class AskDelete(val target: DeleteTarget) : MyListingsEvent
    data object ConfirmDelete : MyListingsEvent
    data object Retry : MyListingsEvent
}
```

- [ ] **Step 1: Failing tests.** `MyListingsViewModelTest`: `aCutOffersUndo` (snackbar "Đã giảm còn 1.700.000 ₫" with "Hoàn tác", which restores 1.900.000 and the suggestion); `boostingShowsProgressThenLeads` (failing first: the sheet stays with "Chưa gửi được. Thử lại"); `aPlanBoostIsUsedFirst` (plan PLUS: the sheet reads "Gói Plus · còn 4 lượt đẩy tháng này", "Đẩy tin · 1 lượt"); `markingSoldOffersUndo`; `deletingADraftSays` ("Đã xóa nháp"); `thePaneSurvivesRecreation`; `arrivingWithPostedSaysPosted`. `MyListingsScreenTest`: "7 ngày qua" tiles 55, 2, 3; tabs "Đang bán 2", "Nháp 1", "Đã bán 2"; the guitar card's counts and "12 ngày", "Cao hơn 12%" in `tertiary`, "Giảm còn 1,7 tr"; the stool's order row opens `OrderRoute("d-huy")`; the stool's menu holds only "Sửa tin" and "Ẩn tin"; the guitar's menu holds the five; a hidden card's note and 50 % alpha by pixel; the draft card's "3 ảnh · chưa có giá", "Cần xác minh để đăng", "Tiếp tục" → `SellRoute("dr-iphone11")`; a video draft → `SellReviewRoute(draftId = …)`; sold cards "Gia Bảo · Thứ Hai" with 5 and "Thu Trang · 28/9"; "Bán cho ai?" lists Minh Quang "Hỏi hôm nay" and "Người ngoài ShopNexus", confirm disabled until a pick, "Minh Quang sẽ được mời đánh giá bạn"; the delete dialogs for a listing and a draft (ruling 16); empty panes with their actions; the add menu's two items; overflow labels "Tùy chọn cho Đàn guitar Yamaha F310"; font scale 1.3 for each pane. Screenshots: each pane, the menu, each sheet and dialog, a boosted and a hidden card; four variants for Đang bán.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Tin của bạn`.

### Task 16: Gói người bán

**Files:** Create `plans/PlansViewModel.kt`, `plans/PlansScreen.kt`; strings; `manage_accounts`, `autorenew`, `query_stats`, `quickreply` and the other new symbols. Tests: `PlansViewModelTest`, `PlansScreenTest`, screenshots.

- [ ] **Step 1: Failing tests.** `PlansViewModelTest.confirmingMovesTheCurrentPlan` (progress, then "Đã chuyển sang gói Plus"); a failed confirm keeps the sheet; the selection survives recreation. `PlansScreenTest`: three radio cards in a group "Gói", "Đang dùng" on Cơ bản, the button "Đang dùng Cơ bản" disabled; picking Plus checks it (ring and check) and the button reads "Dùng Plus · 49.000 ₫/tháng"; the sheet "Xác nhận gói" with "Gói Plus · 49.000 ₫/tháng", "MoMo •• 0912", the renewal sentence; on Plus, picking Cơ bản reads "Về gói Cơ bản" and its sheet has "Gói Cơ bản · Miễn phí" and "Gói đang dùng chạy hết tháng đã trả." without MoMo; the COD note and the service-fee sentence. Screenshots: default, Plus picked, the two sheets; four variants for default.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Gói người bán`.

### Task 17: The seller in Chat

**Files:** Modify `feature/deal/.../chat/Console.kt`, `ChatViewModel.kt`, `ChatUiState.kt`, `Sheets.kt` (counter sheet); create `core/ui/.../deal/CodeSheet.kt` (shared with Task 18). Tests: `ChatViewModelTest`, `ChatScreenTest`, `CodeSheetTest`, screenshots.

- [ ] **Step 1: Failing tests.** `ChatScreenTest`: d-quang with Thảo Vy-style offer 1.800.000 shows the figure, "Giá bạn đăng 1.900.000 ₫", "Trả giá" and "Đồng ý"; "Đồng ý" sends `AcceptCounter`; "Trả giá" opens the sheet with the seller's presets and refuses 1.900.000; a counter open reads "Chờ Minh Quang trả lời" with no action; a buyer's proposal shows "Đổi giờ" and "Đồng ý hẹn"; a confirmed meeting shows "Hiện mã giao dịch", which opens the code sheet. `ChatViewModelTest.aCounterRacingAnAcceptAgreesOnce` (the simulator accepts while a second counter is sent: one agreement, the failed counter rolls back); `theCodeSheetClosesOnTheScan` (virtual time 3 s → `Scanned` effect, snackbar "Giao dịch đã ghi nhận"). `CodeSheetTest`: the QR drawn, "Đưa mã cho Thảo Vy quét sau khi bạn ấy kiểm hàng và trả tiền.", the order number, the 700 ms check. Screenshots for each new console state.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: let the seller answer offers and meetings in Chat`.

### Task 18: Đơn bán gặp mặt and the orders list

**Files:** Create `feature/orders/.../sellmeet/SellMeetViewModel.kt`, `SellMeetScreen.kt`; modify `OrderRouter.kt` (`OrderPage.SELL_MEET`), `list/OrdersViewModel.kt` and `core/ui/.../deal/OrderCopy.kt` (seller in-person lines and actions, `itemRoute` → `MyListingsRoute()`); strings. Tests: `SellMeetViewModelTest`, `SellMeetScreenTest`, `OrderRouterTest`, `OrdersScreenTest`, screenshots.

- [ ] **Step 1: Failing tests.** `OrderRouterTest.aSellersInPersonOrderOpensDonBan` (d-bao → SELL_MEET; stage 3's replace-with-Chat test goes, ledgered under ruling 23). `SellMeetScreenTest` through the d-bao jumps: ARRANGING with the buyer's proposal ("Đã chốt giá", "chờ bạn đồng ý", "Đổi giờ", "Đồng ý hẹn"); WAITING ("Hẹn …", the place, "Hủy hẹn", "Hiện mã giao dịch" opens the code sheet); MET ("Giao dịch đã ghi nhận", "Đã nhận 650.000 ₫ tại chỗ", "Món đồ cũ đã có chủ mới."); REVIEWED ("Gia Bảo đánh giá 5 sao"); CANCELLED; RECORD_OPEN with the incident card, "Từ chối" and "Tự hoàn"; the timeline's four labels; "Nhận trực tiếp từ Gia Bảo / Tiền mặt hoặc chuyển khoản khi gặp"; the item row opens `MyListingsRoute()`. `SellMeetViewModelTest.cancellingCostsTheSeller` (the penalty event), `aRefundShowsProgress`. `OrdersScreenTest.sellerInPersonRowsHaveTheirActions` (ARRANGING "Đồng ý hẹn", WAITING "Hiện mã", RECORD_OPEN "Trả lời"). Screenshots: each status; four variants for WAITING.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Đơn bán for in-person orders`.

### Task 19: Entry points

**Files:** Modify `feature/discover/.../home/HomeScreen.kt`, `HomeViewModel.kt` (the newest draft from `SellRepository`), `feature/notifications/.../NotificationsViewModel.kt` (`MyListings` target), `feature/placeholder/...` (already in Task 1), `PlaceholderScreenTest` (`noStageFourPlaceholderIsLeft` scans `src/main` for `PlaceholderRoute(4,` and `stage = 4`). Tests: `HomeScreenTest`, `NotificationsViewModelTest`, `PlaceholderScreenTest`.

- [ ] **Step 1: Failing tests.** `HomeScreenTest.theFabPostsForReal` ("Chụp ảnh" → `SellRoute()`, "Quay video" → `SellVideoRoute`, "Tiếp tục nháp" → `SellRoute("dr-iphone11")`; with no draft, "Tiếp tục nháp" is absent). `NotificationsViewModelTest.aListingsRowOpensTinCuaBan`. `PlaceholderScreenTest.noStageFourPlaceholderIsLeft`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: open the selling screens from Home, Tôi and the orders`.

### Task 20: End-to-end walks and the device review

**Files:** Create `app/src/test/.../SellWalkTest.kt` with `photoWalk`, `videoWalk`, `codSaleWalk`, `meetSaleWalk` (the four walks of the spec, `simulator.speed = 10.0`, activity results answered with `shadowOf(activity)`). Then build the APK, install on the API 36 emulator and walk every screen with `app2/tmp/ui.py`, comparing with the mockups.

- [ ] **Step 1: Write the walks; run, expect FAIL** where a piece is missing; fix by the owning task's rules.
- [ ] **Step 2: Run, expect PASS**, then the gate.
- [ ] **Step 3: Emulator walk.** Each screen and sheet; Quay video in simulated mode; screenshots to `app2/tmp/work/walk`. Differences that are not rulings become fixes with tests.
- [ ] **Step 4: Commit** `test: walk a listing from photos and video to a sale`.
