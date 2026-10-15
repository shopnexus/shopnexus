# app2 stage 3 (Giao dịch) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Tin nhắn, Đơn hàng, Chi tiết đơn, Giao COD, Đơn COD and Đơn bán, Chat for both roles, new deals from Listing detail, and the QR scanner on CameraX and ML Kit, on the stage 1 and 2 foundation with fake data.

**Architecture:** Two new feature modules (`:feature:inbox`, `:feature:orders`); deal pieces that Chat and the order pages share move into `:core:ui`'s `deal` package. The contract grows in `:core:model`; order states, labels and the console are pure functions in `:core:domain`; the fakes gain the eight seeded deals, the account, the carrier and the new people's replies. Screens follow stages 1 and 2: one ViewModel with `StateFlow` state and a `Channel` of effects per screen.

**Tech Stack:** stage 2's (Kotlin 2.4.21, AGP 9.4.1, Compose BOM 2026.09.00 with material3 1.5.0-beta01, Navigation 3 1.2.0, Hilt 2.60.1, Coil 3.6.3, Robolectric 4.17, Roborazzi 1.76.0, Turbine, Truth), plus CameraX 1.6.2 (`camera-camera2`, `camera-lifecycle`, `camera-compose`), ML Kit `barcode-scanning` 17.3.0 and ZXing `core` 3.5.4.

**Spec:** `/home/beanbocchi/shopnexus/specs/2026-10-15-app2-stage3-deals-design.md`. Data, strings and interactions with source lines: `app2/.superdesign/stage3-digest.md` (committed in Task 7). Mockups: `app2/.superdesign/tools/build_{inbox,orders,order,cod_checkout,cod_order,ship_order}.py`, `order_kit.py`, `common.py`.

**Ruling on this plan's form:** as in stage 2, the plan writes out the contract types, the rule signatures with their test cases, and the fixture formats; screen tasks fix the UI state, events, layout and every test by name and assertion, and the composables are written against them during execution. Cost if wrong: screen code is reviewed only at the final review.

## Global Constraints

- Everything in stages 1 and 2's Global Constraints holds (minSdk 31, compileSdk 37, targetSdk 36, JVM 21, package `vn.shopnexus`, features never depend on features, `:core:model` and `:core:domain` are JVM, colors only through the theme, the type scale, corners 4/8/12/16/20/28/32 dp, touch targets ≥ 48 dp, Vietnamese strings in `strings.xml` with one value per name across modules, money as `Vnd`, new symbols through `core/designsystem/symbols.txt` and `tools/gen_symbols.py`, fixture photos saved with `core/testing/tools/fetch_photos.py`).
- `tertiary` marks bargaining and the agreed price; the sparkle marks AI judgments (scam signals, record notes, check-lists) and nothing else; one primary-filled action per view.
- Every step that touches money shows its `MoneyKey` sentence in the stage 1 words.
- A step that moves money (placing COD, receiving, refusing, a refund) never shows as done before its command succeeds.
- Strings prefixed per module (`inbox_`, `orders_`, `deal_ui_` in `:core:ui`) so `StringResourcesTest` passes.
- `./gradlew check verifyRoborazziDebug` passes at the end of every task (`/tmp/claude-1000/gate.sh <log>`).
- Commit messages and code comments go through the humanizing-writing checker; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. Time crossing a boundary while a page is open: the 48-hour window lapsing on a placed parcel (EXPIRED on both sides), "Vừa xong" turning into a time, a countdown passing an hour. Expected: the page changes within a minute without a reload. Pinned in Task 4 (`orderStatus` at deadline − 1 s and at the deadline) and Task 19 (`CodOrderViewModelTest.theWindowLapsingShowsExpired`).
2. A command racing a simulated reply: withdrawing a record just before Ngọc Hân's decline lands, a double tap on "Đặt COD", "Nhận" while a check is in flight. Expected: the withdrawn record stays withdrawn, one order is placed, the parcel is received once. Pinned in Task 9 (`SimulatorTest.aReplyToAWithdrawnRecordIsDropped`), Task 16 (`CodCheckoutViewModelTest.placingTwiceSendsOneCommand`), Task 19 (`receiveWaitsForPendingChecks`).
3. Role mix-ups: the same screens with me as seller (Minh Quang, Đức Huy, Gia Bảo) and as buyer. Expected: my messages on my side, the seller never sees rating or record actions, the buyer never sees ship or refund actions, Mua and Bán hold the right orders. Pinned in Task 5 (console per role), Task 6 (engine refuses the wrong side), Task 13 (`ChatScreenTest.aSellersOwnMessagesSitOnTheRight`).
4. Recreation mid-flow: the chosen carrier, the ship method, the packing photo, the refusal reasons, an open dialog or sheet, the record draft, the inbox chip. Expected: all come back. Pinned in Tasks 15, 16, 19, 20 (`…survivesRecreation` tests with `SavedStateHandle`).
5. Undo on the inbox after the list moved: archive, then a new message from that person; block, then "Hoàn tác" after another row changed; read toggles and the badge. Expected: the row returns in its time order with its unread count, the badge always equals the sum. Pinned in Task 8 (`FakeInboxRepositoryTest`) and Task 15 (`InboxScreenTest`).

---

## File structure

```
core/model/.../model/
  Deal.kt             DealStage + ENDED, DealEnd, MeetPoint/Meeting fields, CodShipment (new shape), Carrier, DeliveryAddress,
                      TimeWindow, CodStatus, ShipMethod, RefusalReason, IncidentRecord fields, Deal fields, DealView (was ChatView)
  DealCommand.kt      + SendPhotos, PlaceCod, ReceiveParcel, RefuseParcel, CancelMeeting, WithdrawRecord, ShipParcel, RefundRecord, DeclineRecord
  Inbox.kt            WarningSignal, ScamWarning, InboxTag, LastMessage, InboxRow, Inbox, BlockedConversation
  Checkout.kt         CodCheckout
  MoneyKey.kt         + HANDOVER_SELLER, REFUSED_STAT, PAY_SHIPPER
  Notifications.kt    NotificationTarget.Order
core/domain/.../domain/
  Labels.kt           inboxTime, dayLabel, momentLabel, deadlineLabel, timeLeft, itemNoun, shortTitle
  Orders.kt           OrderStatus, roleOf, isOrder, orderStatus, phaseOf, orderRows, inboxTag, openCodOrders, CodSlots, codSlots,
                      refundOptions, cancelPenalty, recordDaysLeft
  DealConsole.kt      roles and the new states
  MoneyNotes.kt       new MoneySteps
core/data/.../data/
  Repositories.kt     DealRepository grows, InboxRepository; QrScanner goes
  fake/FakeDealEngine.kt (roles, new commands), FakeDealRepository.kt, FakeInboxRepository.kt, Simulator.kt (carrier, people),
  fake/Seeds.kt (DealSeed, AccountSeed, RecordReply), fake/OrderJumps.kt (debug), FakeWorld.kt, Fixtures.kt
  tools/stage3_fixtures.py, tools/stage2_fixtures.py (edits)
core/data/src/main/resources/fixtures/  deals.json account.json people.json (new); sellers, pool, notifications (edited); chat-d-kiet.json goes
core/designsystem/.../component/  StatusHero.kt, Timeline.kt, ToggleGroup.kt, SwipeRow.kt, StatusTag.kt, Milestone.kt (NEUTRAL)
core/ui/.../ui/deal/  OrderCopy.kt (lines, actions, nouns), CheckList.kt (block + "Chưa kiểm xong"), RecordSheet.kt, MeetingSheet.kt,
                      Rating.kt, Rows.kt (item, person, money), CarrierEvents.kt, QrCode.kt, Scanner.kt (CameraX + ML Kit + simulated),
                      ScanMode.kt, CodInfoSheet.kt
feature/inbox/        InboxScreen, InboxViewModel, ScamSheet, InboxInstaller
feature/orders/       OrdersScreen/VM, OrderRouter, MeetOrderScreen/VM, CodCheckoutScreen/VM, CodOrderScreen/VM, ShipOrderScreen/VM,
                      RefundSheet, ShippingCodeSheet, OrdersInstaller
feature/deal/         Chat grows (roles, states, photos); Sheets.kt loses the record and meeting sheets to :core:ui
```

---

### Task 1: Stage 3 routes and modules

**Files:**
- Modify: `core/navigation/.../Routes.kt`, `Navigator.kt`, `DeepLinks.kt`; `app/.../AppNavigation.kt`
- Create: `feature/inbox/build.gradle.kts`, `feature/orders/build.gradle.kts`, their `AndroidManifest.xml`, `InboxInstaller.kt`, `OrdersInstaller.kt` (each route renders `PlaceholderScreen(3, title)` until its task); `settings.gradle.kts`, `app/build.gradle.kts`
- Modify: `feature/placeholder/.../PlaceholderInstaller.kt` (Tôi links "Đơn mua", "Đơn bán"; `InboxRoute` leaves in Task 15), `res/values/strings.xml`
- Test: `AppNavigatorTest`, `DeepLinksTest`, `PlaceholderScreenTest`, `InstallersTest`

**Interfaces (Produces):**

```kotlin
@Serializable data class OrdersRoute(val side: String = "BUY") : NavKey      // a Party name
@Serializable data class OrderRoute(val dealId: String) : NavKey
@Serializable data class CodCheckoutRoute(val dealId: String) : NavKey

interface Navigator {
    // …stage 2…
    /** Closes the top screen and opens [route] with the push transition. */
    fun replace(route: NavKey) { back(); push(route) }
}
// DeepLinks: "order" -> OrderRoute(id); fun order(id: String) = "shopnexus://order/$id"
```

- [ ] **Step 1: Failing tests.** `AppNavigatorTest.replaceSwapsTheTopScreen` (stack `[Home, ChatRoute(d), CodCheckoutRoute(d)]`, `replace(OrderRoute(d))` → `[Home, ChatRoute(d), OrderRoute(d)]`, `lastMove == PUSH`; `back()` returns to Chat). `DeepLinksTest.anOrderLinkOpensTheOrder` and round trip. `PlaceholderScreenTest.theMeTabListsOrders` (rows "Đơn mua", "Đơn bán" push `OrdersRoute("BUY")`, `OrdersRoute("SELL")`; "Đã lưu", "Thông báo" stay). `InstallersTest`: ten installers; the provider resolves every route in `Routes.kt`.
- [ ] **Step 2: Run, expect FAIL.** `./gradlew :app:testDebugUnitTest :core:navigation:test :feature:placeholder:testDebugUnitTest --offline -q`.
- [ ] **Step 3: Implement.** `AppNavigator.replace` removes the top entry and adds `route` in one snapshot with `lastMove = PUSH`. The two modules use `shopnexus.android.feature`.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add the stage 3 routes and modules`.

### Task 2: The stage 3 contract (`:core:model`)

**Files:** Modify `Deal.kt`, `DealCommand.kt` (split out of `Deal.kt` if it lives there), `MoneyKey.kt`, `Notifications.kt`; create `Inbox.kt`, `Checkout.kt`; rename `ChatView` → `DealView` everywhere (`git grep -l ChatView`), and `DealRepository.chat` → `deal` in Task 8. Test: `core/model/src/test/.../DealJsonTest.kt` (grows).

**Interfaces (Produces):**

```kotlin
@Serializable enum class DealStage { NEGOTIATE, ARRANGE, HANDOVER, RATE, DONE, ENDED }
@Serializable enum class DealEnd { CANCELLED, REFUSED }

@Serializable data class MeetPoint(val name: String, val why: String, val area: String? = null, val distanceKm: Double? = null)
@Serializable data class Meeting(val at: Moment, val place: MeetPoint, val proposedBy: Party, val confirmed: Boolean, val confirmedAt: Moment? = null)

@Serializable data class Carrier(val id: String, val name: String, val days: String, val fee: Vnd)
@Serializable data class DeliveryAddress(val name: String, val phone: String, val line: String)
@Serializable data class TimeWindow(val from: Moment, val to: Moment)
@Serializable enum class CodStatus { PLACED, SHIPPING, AT_DOOR, RECEIVED, REFUSED }
@Serializable enum class ShipMethod { PICKUP, DROP_OFF }
@Serializable enum class RefusalReason { UNDECLARED_MARK, NOT_AS_DESCRIBED, CHANGED_MIND }

/** A COD parcel from placing to the door. Its status moves only on what the carrier reports, and the buyer's receipt. */
@Serializable
data class CodShipment(
    val carrier: Carrier,
    val placedAt: Moment,
    val deadline: Moment,
    val paidWith: String,
    val to: DeliveryAddress,
    val code: String,
    val status: CodStatus = CodStatus.PLACED,
    val events: List<CarrierEvent> = emptyList(),
    val eta: TimeWindow? = null,
    val method: ShipMethod = ShipMethod.PICKUP,
    val pickupWindow: TimeWindow? = null,
    val postOfficeKm: Double? = null,
    val packPhotoUrl: String? = null,
    val payoutTo: String? = null,
    val returnFee: Vnd = carrier.fee,
    val pickedUpAt: Moment? = null,
    val atDoorAt: Moment? = null,
    val receivedAt: Moment? = null,
    val refusedAt: Moment? = null,
    val refusalReasons: Set<RefusalReason> = emptySet(),
)

// IncidentRecord gains: val openedAt: Moment? = null, val answeredAt: Moment? = null
// Deal: val path: HandoverPath?   (null while both ways are open and the buyer has not chosen)
//       val end: DealEnd? = null, val code: String? = null, val agreedAt: Moment? = null, val ratedAt: Moment? = null

/** Everything Chat and the order pages show about one deal, in one read. */
@Serializable
data class DealView(
    val deal: Deal,
    val listing: ListingSummary,
    val counterpart: SellerSummary,
    val me: Me,
    val declaredMarks: List<DeclaredMark>,
    /** Whether the other person has a Người bán page; buyers who never sold have none. */
    val counterpartSells: Boolean = true,
)

// DealCommand: what the signed-in person can do; the engine reads their side from `me`.
@Serializable @SerialName("sendPhotos") data class SendPhotos(val urls: List<String>) : DealCommand
@Serializable @SerialName("placeCod") data class PlaceCod(val carrierId: String) : DealCommand
@Serializable @SerialName("receiveParcel") data object ReceiveParcel : DealCommand
@Serializable @SerialName("refuseParcel") data class RefuseParcel(val reasons: Set<RefusalReason>) : DealCommand
@Serializable @SerialName("cancelMeeting") data object CancelMeeting : DealCommand
@Serializable @SerialName("withdrawRecord") data class WithdrawRecord(val recordId: RecordId) : DealCommand
@Serializable @SerialName("shipParcel") data class ShipParcel(val photoUrl: String, val method: ShipMethod) : DealCommand
@Serializable @SerialName("refundRecord") data class RefundRecord(val recordId: RecordId, val amount: Vnd) : DealCommand
@Serializable @SerialName("declineRecord") data class DeclineRecord(val recordId: RecordId) : DealCommand
// AcceptCounter's doc: accepts the open counter, or the listed price when there is none.

@Serializable data class WarningSignal(val icon: String, val text: String)
@Serializable data class ScamWarning(val signals: List<WarningSignal>)

@Serializable
sealed interface InboxTag {
    @Serializable @SerialName("counter") data class Counter(val amount: Vnd) : InboxTag
    @Serializable @SerialName("agreed") data class Agreed(val amount: Vnd) : InboxTag
    @Serializable @SerialName("toShip") data object AwaitingShipment : InboxTag
    @Serializable @SerialName("sold") data class Sold(val amount: Vnd) : InboxTag
    @Serializable @SerialName("scam") data object Scam : InboxTag
}

/** The newest text or photos; [photos] counts the photos when the newest item is a photo item. */
@Serializable data class LastMessage(val text: String?, val photos: Int, val mine: Boolean, val at: Moment)

@Serializable
data class InboxRow(
    val dealId: DealId,
    val role: Party,
    val person: SellerSummary,
    val listing: ListingSummary,
    val last: LastMessage?,
    val unread: Int,
    val tag: InboxTag?,
    val warning: ScamWarning?,
)
@Serializable data class Inbox(val rows: List<InboxRow>, val unread: Int)

/** What "Hoàn tác" needs after "Chặn và báo cáo". */
@Serializable data class BlockedConversation(val dealId: DealId, val person: UserId, val reportId: String)

@Serializable
data class CodCheckout(
    val view: DealView,
    val carriers: List<Carrier>,
    val address: DeliveryAddress,
    val payWith: String,
    val openCod: Int,
    val codCap: Int,
    val codBlockedUntil: Moment?,
)

// MoneyKey + HANDOVER_SELLER, REFUSED_STAT, PAY_SHIPPER
// NotificationTarget + @Serializable @SerialName("order") data class Order(val dealId: DealId) : NotificationTarget
```

- [ ] **Step 1: Failing tests.** `DealJsonTest`: a `DealView` with a placed `CodShipment`, a declined record and `path = null` round-trips; `InboxTag` and `NotificationTarget.Order` encode with their `type` names; `CodShipment.returnFee` defaults to the carrier fee; stage 1's `chat-d-kiet.json` still decodes as a `DealView` (until Task 7 replaces it).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**; fix every compile error from the rename and the nullable path (`deal.path` has no readers outside tests today). The money words for the three new keys go into `core/designsystem/.../res/values/strings.xml` with the digest's sentences: "Quá 48 giờ chưa gửi thì đơn tự hủy và người mua được hoàn phí ship.", "Từ chối nhận được tính vào chỉ số 90 ngày của bạn.", "Trả tiền hàng cho shipper sau khi xem, bằng tiền mặt hoặc chuyển khoản."; check the ten existing words against the digest's `MONEY` table and fix any that differ.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: grow the deal contract for orders, COD and the inbox`.

### Task 3: Labels

**Files:** Create `core/domain/.../Labels.kt`; test `LabelsTest.kt`.

```kotlin
fun inboxTime(at: Instant, now: Instant, zone: ZoneId): String      // "14:10", "Hôm qua", "Thứ Hai", "12/10"
fun dayLabel(at: Instant, now: Instant, zone: ZoneId): String       // "Hôm nay", "Hôm qua", "Thứ Hai", "12/10"
fun momentLabel(at: Instant, now: Instant, zone: ZoneId): String    // "Vừa xong", "Hôm nay · 09:40", "Hôm qua · 20:15", "12/10 · 14:20"
fun deadlineLabel(at: Instant, now: Instant, zone: ZoneId): String  // "Trước 20:15 hôm nay", "Trước 18:00 thứ Sáu", "Trước 18:00 · 22/10"
fun timeLeft(deadline: Instant, now: Instant): String               // "còn 26 giờ", "còn 40 phút", "còn 0 phút"
fun itemNoun(kind: ListingKind): String                             // "máy", "xe", "hàng"
fun shortTitle(title: String): String                               // "iPhone X"
```

- [ ] **Step 1: Failing tests.** With now Thursday 15/10/2026 15:10 in `VN_ZONE`: `inboxTime` 14:10 today → "14:10", 20:05 yesterday → "Hôm qua", Monday 12/10 → "Thứ Hai", Sunday 11/10 → "Chủ nhật", 8/10 → "08/10"; `dayLabel` the same with "Hôm nay" for today; `momentLabel` 30 s ago → "Vừa xong", 09:40 → "Hôm nay · 09:40", yesterday 20:15 → "Hôm qua · 20:15", 12/10 14:20 → "12/10 · 14:20"; `deadlineLabel` Friday 18:00 → "Trước 18:00 thứ Sáu", Saturday 15:20 → "Trước 15:20 thứ Bảy", Sunday → "Trước 18:00 chủ nhật", today 20:15 → "Trước 20:15 hôm nay", 22/10 → "Trước 18:00 · 22/10"; `timeLeft` 26 h 50 min → "còn 26 giờ", 47 h 59 min → "còn 47 giờ", 40 min → "còn 40 phút", past → "còn 0 phút"; `itemNoun` PHONE, COMPUTER, WATCH, AUDIO, CAMERA, APPLIANCE → "máy", BIKE, MOTORBIKE → "xe", FURNITURE, FASHION, OTHER → "hàng"; `shortTitle` "iPhone X 64GB, pin 86%, máy zin chưa sửa" → "iPhone X", "Tai nghe chống ồn Sony WH-1000XM4, fullbox" → "Tai nghe chống ồn Sony WH-1000XM4", "Ghế đôn gỗ cao" unchanged, "iPhone 13 Pro 128GB" → "iPhone 13 Pro", "MacBook Air M1 13 inch" unchanged; midnight in Hồ Chí Minh City splits the days.
- [ ] **Step 2: Run** `./gradlew :core:domain:test --tests '*LabelsTest*' --offline -q`, expect FAIL.
- [ ] **Step 3: Implement.** Weekday names reuse `notificationTime`'s table; `deadlineLabel` lower-cases "thứ" and "chủ nhật". `shortTitle` cuts at the first comma, then drops one trailing token matching `\d+(GB|TB)`.
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat: label inbox times, deadlines and order dates`.

### Task 4: Order rules

**Files:** Create `core/domain/.../Orders.kt`; modify `MoneyNotes.kt`; tests `OrdersTest.kt`, `OrderStatusTest.kt`, `MoneyNotesTest.kt` (grows).

```kotlin
enum class OrderStatus {
    ARRANGING, WAITING, MET, PLACED, TO_SHIP, SHIPPING, AT_DOOR, RECEIVED, REVIEWED,
    REFUSED, EXPIRED, CANCELLED, RECORD_OPEN, RECORD_REFUNDED, RECORD_SETTLED, RECORD_DECLINED,
}
fun roleOf(deal: Deal, me: UserId): Party
fun isOrder(deal: Deal): Boolean
/** Null when the deal is not an order yet. */
fun orderStatus(deal: Deal, me: UserId, now: Instant): OrderStatus?
fun phaseOf(deal: Deal): Int
fun orderRows(views: List<DealView>, side: Party): List<DealView>
fun inboxTag(deal: Deal, me: UserId, warning: ScamWarning?): InboxTag?
fun openCodOrders(deals: List<Deal>, me: UserId, now: Instant): Int
data class CodSlots(val after: Int, val cap: Int, val fits: Boolean)
fun codSlots(rights: Rights, openCod: Int, now: Instant): CodSlots
fun refundOptions(price: Vnd): List<Vnd>
fun cancelPenalty(meetingAt: Instant, now: Instant): ReputationEvent
fun recordDaysLeft(openedAt: Instant, now: Instant): Int
// MoneyStep + DEAL_CHOOSING (MEET, COD_BUYER), COD_CHECKOUT (COD_BUYER, REFUSE, HANDOVER), COD_DOOR (REFUSE, AFTER_PAY),
//   COD_MONEY (PAY_SHIPPER, NO_HOLD), SELL_HANDOVER (HANDOVER_SELLER), SELL_MONEY (COD_SELLER, RETURN_LEG, NO_HOLD),
//   MEET_MONEY (MEET, AFTER_PAY, NO_HOLD), COD_INFO (COD_BUYER, REFUSE, HANDOVER, OVER_LIMIT, NO_HOLD)
```

`orderStatus`: not an order → null; the newest record not WITHDRAWN decides (OPEN → RECORD_OPEN, REFUNDED → RECORD_SETTLED when `refundConfirmed` else RECORD_REFUNDED, DECLINED → RECORD_DECLINED); ENDED → CANCELLED or REFUSED; in person ARRANGE → ARRANGING, HANDOVER → WAITING, RATE → MET, DONE → REVIEWED; COD by `cod.status`: PLACED → EXPIRED when `!now.isBefore(deadline)`, else PLACED for the buyer and TO_SHIP for the seller; SHIPPING → SHIPPING; AT_DOOR → AT_DOOR for the buyer, SHIPPING for the seller; RECEIVED → RECEIVED in RATE, REVIEWED in DONE. `phaseOf`: NEGOTIATE 0, ARRANGE 1, HANDOVER 2, RATE 3, DONE 4; ENDED CANCELLED → 2 when the meeting was confirmed else 1; ENDED REFUSED → 2. `inboxTag`: warning → Scam; NEGOTIATE with an open counter → Counter; seller with a PLACED parcel before its deadline → AwaitingShipment; seller in RATE or DONE → Sold(agreed); an agreed price outside DONE and ENDED → Agreed; else null. `openCodOrders`: deals where I buy by COD, in ARRANGE or HANDOVER, before their deadline. `codSlots`: `after = openCod + 1`, `cap = rights.codOpenCap`, `fits = after <= cap && (rights.codBlockedUntil?.let { !now.isBefore(it) } ?: true)`. `refundOptions`: 15 % and 30 % rounded down to 50.000, then the price; zeros and repeats dropped; ascending. `cancelPenalty`: CANCEL_MEETING_LATE from `meetingAt − 2 h`. `recordDaysLeft`: ceiling of the days from now to `openedAt + 3 days`, at least 0. `orderRows`: `isOrder` and my side, newest of (thread's last item, `cod.events` last, `ratedAt`) first.

- [ ] **Step 1: Failing tests.** `OrderStatusTest` builds deals inline (helpers `meetDeal(stage)`, `codDeal(status)`) and checks every row of the spec's three status tables and both sides: a placed parcel one second before its deadline is PLACED/TO_SHIP and at the deadline EXPIRED for both; AT_DOOR reads SHIPPING for the seller; a withdrawn record falls back to the base state; a refunded record reads RECORD_REFUNDED, then RECORD_SETTLED once confirmed; an agreed deal with `path = null` is not an order. `OrdersTest`: `phaseOf` for every stage and both ends; `inboxTag` for the seven seeded rows' shapes (counter 10,6 tr; scam; none for a seller negotiating; AwaitingShipment; Agreed 3,8 tr; Agreed 2,3 tr; Sold 650.000); `openCodOrders` counts a placed and a shipping parcel, not a received, refused, expired or selling one; `codSlots` (0 open, cap 5 → 1/5 fits; 4 → 5/5 fits; 5 → 6/5 does not; blocked until tomorrow → does not); `refundOptions(350.000)` = 50.000, 100.000, 350.000, `refundOptions(100.000)` = 50.000, 100.000 (15 % rounds to 0 and drops), `refundOptions(10.600.000)` = 1.550.000, 3.150.000, 10.600.000; `cancelPenalty` at 15:10 for 18:00 → −20, at 16:00 → −30; `recordDaysLeft` just opened → 3, after 2 days 1 hour → 1, after 4 days → 0; `orderRows` sides and order. `MoneyNotesTest`: each new step's keys in order.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat: work out order states, steps and inbox tags`.

### Task 5: The console for both sides

**Files:** Modify `core/domain/.../DealConsole.kt`; test `DealConsoleTest.kt` (grows).

```kotlin
sealed interface ConsoleState {
    // stage 1's eight stay
    data class Choosing(val price: Vnd) : ConsoleState
    data class OrderStep(val status: OrderStatus, val price: Vnd) : ConsoleState
    data class Selling(val price: Vnd) : ConsoleState
    data class SellerMeeting(val meeting: Meeting?) : ConsoleState
    data class Ended(val status: OrderStatus, val price: Vnd) : ConsoleState
}
object DealConsole {
    fun state(deal: Deal, me: UserId, draft: ConsoleDraft, now: Instant): ConsoleState
    fun reduce(deal: Deal, draft: ConsoleDraft, event: ConsoleEvent): ConsoleStep   // unchanged
    fun needsCheckWarning(state: ConsoleState): Boolean                             // unchanged
}
```

Buyer: NEGOTIATE as stage 1 (no counter → Countered with the listed price); ARRANGE with `path == null` → Choosing(agreed), COD → OrderStep(PLACED) or Ended(EXPIRED), MEET → Agreed/Proposing; HANDOVER MEET → AtMeeting, COD → OrderStep(SHIPPING or AT_DOOR); RATE → Received; DONE → Done; ENDED → Ended(status). Seller: NEGOTIATE → Selling(openOffer ?: listed); ARRANGE and HANDOVER MEET → SellerMeeting(meeting), COD → OrderStep(TO_SHIP or SHIPPING) or Ended(EXPIRED); RATE and DONE → OrderStep(RECORD_OPEN) with an open record on COD, else Done(rating ?: 0); ENDED → Ended.

- [ ] **Step 1: Failing tests.** Stage 1's tests pass `me = u-linh` and keep their results. New: a no-counter deal shows Countered(listed) and Accept sends `AcceptCounter`; `path = null` after agreement → Choosing; each COD status for the buyer and the seller; an expired parcel → Ended(EXPIRED) on both sides; a seller negotiating → Selling(listed), with an open buyer offer → Selling(offer); a seller's received parcel → Done(0), with an open record → OrderStep(RECORD_OPEN); a cancelled meeting → Ended(CANCELLED).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**; update `ChatUiState`'s call (`DealConsole.state(deal, view.me.id, draft, now)`).
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: give the deal console both sides and the COD states`.

### Task 6: The engine's new commands

**Files:** Modify `core/data/.../fake/FakeDealEngine.kt`; create `fake/Seeds.kt` (`AccountSeed`, `EngineContext`); test `FakeDealEngineTest.kt` (grows).

```kotlin
@Serializable
data class AccountSeed(
    val phone: String, val address: DeliveryAddress, val payWith: String, val payoutTo: String,
    val score: Int, val codOrders90: Int, val codRefused90: Int, val lastRefusalAt: Moment? = null,
    val carriers: List<Carrier>, val meetPoints: List<MeetPoint>,
    val checklists: Map<ListingKind, List<CheckItem>>, val generalChecklist: List<CheckItem>,
)
/** What a command needs beyond the deal: the account, and how many COD orders the buyer has open. */
data class EngineContext(val account: AccountSeed, val openCod: Int, val rights: Rights)

class FakeDealEngine {
    fun apply(view: DealView, command: DealCommand, now: Instant, context: EngineContext): Deal
}
/** The agreed price, the order number and the milestone, shared with the simulator's acceptance. */
internal fun Deal.agreedAt(price: Vnd, by: Party, now: Instant): Deal
internal fun orderCode(id: DealId): String       // "SN-" + five digits from the id
internal fun shippingCode(id: DealId): String    // "SNX dddd dddd"
```

Rules: buyer-only commands (`SendOffer`, `AcceptCounter`, `WithdrawOffer`, `ProposeMeeting`, `ConfirmMeeting`, `SetCheck`, `RecordHandover`, `Rate`, `OpenRecord`, `ConfirmRefund`, `PlaceCod`, `ReceiveParcel`, `RefuseParcel`, `WithdrawRecord`) fail with `check` for the seller; seller-only (`ShipParcel`, `RefundRecord`, `DeclineRecord`) for the buyer; `SendText`, `SendPhotos` (1 to 4 urls) and `CancelMeeting` for both. `AcceptCounter` with no counter agrees at the listed price. `ProposeMeeting` on `path == null` sets MEET. `PlaceCod`: ARRANGE, agreed, `path` null or COD, `codAllowed(agreed)`, `codSlots(...).fits`, a known carrier; sets COD, `cod = CodShipment(carrier, now, handoverDeadline(now), payWith, address(me), shippingCode(id))`, thread event truck "Đã đặt giao COD · {carrier} {fee}". `ReceiveParcel`: AT_DOOR → RECEIVED, stage RATE, `handedOverAt`, `receivedAt`, HANDED_OVER milestone. `RefuseParcel`: AT_DOOR → REFUSED, stage ENDED/REFUSED, `refusedAt`, reasons, event undo "Bạn đã từ chối nhận". `CancelMeeting`: MEET in ARRANGE or HANDOVER → ENDED/CANCELLED, event event_busy "Đã hủy hẹn" (the reputation event is the repository's, Task 8). `WithdrawRecord`: an OPEN or DECLINED record → WITHDRAWN. `ShipParcel`: PLACED before its deadline → SHIPPING, `pickedUpAt`, `packPhotoUrl`, `method`, event truck "Bạn đã gửi hàng" and the carrier event "Đã lấy hàng tại {my district}". `RefundRecord`: an OPEN record, `amount` in 1..agreed → REFUNDED with `refund`, `answeredAt`. `DeclineRecord`: OPEN → DECLINED, `answeredAt`. `Rate` sets `ratedAt`; `OpenRecord` sets `openedAt` and lower-cases the first letter of the mark in the note.

- [ ] **Step 1: Failing tests.** One test per command for its happy path and for each refusal above, including: the seller cannot `Rate`, `OpenRecord` or `PlaceCod`; the buyer cannot `ShipParcel` or `RefundRecord`; `PlaceCod` over 5.000.000 ₫, with no slot, or twice fails; `ReceiveParcel` while SHIPPING fails; `RefundRecord` of 0 ₫ or above the price fails; `ShipParcel` after the deadline fails; `SendPhotos` with 0 or 5 urls fails; `orderCode(DealId("d-han"))` is stable across runs.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS.**
- [ ] **Step 5: Commit** `feat: handle COD, cancellations and seller replies in the fake engine`.

### Task 7: Stage 3 fixtures

**Files:** Create `core/data/tools/stage3_fixtures.py`; edit `core/data/tools/stage2_fixtures.py` (p-xm4 to `u-quocbao` and sold, the two declared marks, the door notification out, the meeting notification's "thứ Năm", the ship and meet targets to `order`); generated `deals.json`, `account.json`, `people.json`, `sellers.json`, `pool.json`, `notifications.json`; delete `chat-d-kiet.json`; modify `Fixtures.kt` (`deals()`, `account()`, `people()`); commit `app2/.superdesign/stage3-digest.md`; save new photos (guitar `1525201548942-d8732f6617a0`, shelf `1532372320572-cda25653a26d`). Test: `FixturesTest.kt` (grows).

```kotlin
/** A seeded deal with its conversation's state and how the other person answers a record. */
@Serializable
data class DealSeed(val view: DealView, val unread: Int = 0, val archived: Boolean = false, val warning: ScamWarning? = null, val recordReply: RecordReply? = null)
@Serializable sealed interface RecordReply {
    @Serializable @SerialName("refund") data class Refund(val amount: Vnd, val afterMillis: Long) : RecordReply
    @Serializable @SerialName("decline") data class Decline(val afterMillis: Long) : RecordReply
}
```

Data, from the digest and the spec's Fake data: the eight deals with threads ending on the previews and times (d-kiet as stage 1, `recordReply` Refund 300.000 ₫ after 2.200 ms; d-24h with Thanh Lý 24h `u-24h`, listing `l-24h-s23` 8.700.000 ₫ on `p-s23`'s photo, my question 13:35 and the deposit message 13:41, the three signals; d-quang with Minh Quang `u-quang` and `my-guitar`; d-huy with Đức Huy `u-huy` and `my-stool`, COD placed 14/10 18:00, deadline 16/10 18:00, Giao nhanh, SNX 8841 2207, pickup window today 14:00–18:00, post office 0,4 km, payout Vietcombank •• 4821, his message 09:12; d-nam with `p-iphonex`, agreed 3.800.000 ₫ on 14/10 20:05, `path = null`, the four checks for the iPhone X; d-han with `p-fixed`, SN-24817, agreed 12/10 14:20, meeting confirmed 14/10 14:32 for 15/10 18:00 at Công viên Gia Định (Phú Nhuận, 2,1 km), the four bike checks, `recordReply` Decline after 2.400 ms; d-bao with Gia Bảo buying `my-shelf`, handed over and rated 5 on 12/10; d-xm4 with Quốc Bảo, COD received 12/10, archived); `account.json` with the spec's account values, both carriers, the three meeting points, the phone list (stage 1's six with `{battery}` in the battery row), the bike list and the four general checks; Thanh Lý 24h (Mới, unverified, 2026) and Quốc Bảo (Tin cậy) in `sellers.json`; Minh Quang and Đức Huy in `people.json`.

- [ ] **Step 1: Failing tests.** `FixturesTest`: the new files parse; every deal's listing is in the pool or is one of my three listings or `l-24h-s23`; every counterpart is a seller or a person; the inbox order from the threads is kiet, 24h, quang, huy, nam, han, bao (xm4 archived); unread totals 3; d-huy's deadline is placed + 48 h; `orderStatus` of the seeded orders at `Fixtures.NOW` gives WAITING (han), RECEIVED (xm4), TO_SHIP (huy), REVIEWED (bao); d-nam is not an order; three notifications are unread; every photo has a saved copy.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Write the scripts, run them and the fetch script.**
- [ ] **Step 4: Run, expect PASS**, then the gate. Stage 2 tests that change with rulings 2, 6 and 16 (unread "3 chưa đọc", Home's grid without the headphones, Đức Trí's five listings to four, the meeting notification text) are updated, and their screenshots re-recorded and looked at.
- [ ] **Step 5: Commit** `feat: add the stage 3 fixtures` (the body names rulings 2, 6 and 16).

### Task 8: Fake repositories

**Files:** Modify `Repositories.kt` (`DealRepository` grows, `InboxRepository`, `QrScanner` removed in Task 12), `FakeWorld.kt`, `FakeDealRepository.kt`, `FakeListingRepository.kt`, `FakeSellerRepository.kt`, `FakeHomeRepository.kt`, `di/DataModule.kt`; create `fake/FakeInboxRepository.kt`. Tests: `FakeDealRepositoryTest`, `FakeInboxRepositoryTest`, `FakeWorldConsistencyTest` (grows).

```kotlin
interface DealRepository {
    fun deal(id: DealId): Flow<DealView?>
    fun orders(): Flow<List<DealView>>
    fun checkout(id: DealId): Flow<CodCheckout?>
    fun counterpartTyping(id: DealId): Flow<Boolean>
    /** The person's open deal on [listing], or a new one in Thương lượng. */
    suspend fun start(listing: ListingId): Result<DealId>
    suspend fun send(id: DealId, command: DealCommand): Result<Deal>
}
interface InboxRepository {
    fun inbox(): Flow<Inbox>
    fun unreadCount(): Flow<Int>
    suspend fun setRead(id: DealId, read: Boolean): Result<Unit>
    suspend fun setArchived(id: DealId, archived: Boolean): Result<Unit>
    suspend fun blockAndReport(id: DealId): Result<BlockedConversation>
    suspend fun restore(blocked: BlockedConversation): Result<Unit>
}
// WorldState: chats → deals: Map<DealId, DealView>; + conversations: Map<DealId, Conversation(unread, archived, warning)>,
//   account: AccountSeed, people: Map<UserId, SellerSummary>, recordReplies: Map<DealId, RecordReply>,
//   reports: List<Report(id, person, reason)>, reputation: List<ScoredEvent>
```

`start`: an open deal (not ENDED, not DONE) of mine as buyer on that listing, else a new `d-<listing>-<n>` with the pool listing, its seller, `listedPrice`, `path` from `availablePaths` when one is open, the account's meeting points, the kind's check-list, the listing's declared marks. `send` applies the engine with the context, adds the reputation event for `CancelMeeting` (`cancelPenalty`) and `RefundRecord` (SELF_REFUND), and tells the simulator. `orders()` emits `isOrder` deals; `checkout` builds `CodCheckout` from the account, `openCodOrders` and `rightsFor(tierFor(score), …)`. Inbox rows follow the threads' newest item; blocked people's rows and archived rows are left out; `unread` sums the rest. `blockAndReport` blocks the counterpart, files a SCAM report and returns both; `restore` undoes both. `FakeListingRepository` reads the open deal on a listing from `deals`; `FakeSellerRepository.dealId` takes my newest open deal with that seller.

- [ ] **Step 1: Failing tests.** `FakeDealRepositoryTest`: `start` on `p-giant` creates a deal with the bike checks and both ways open, a second `start` returns it; `start` on `p-iphone13` returns d-kiet; `PlaceCod` on d-nam moves `orders()` from 4 to 5 and `checkout` reads 1/5 before; `CancelMeeting` on d-han adds −20 to the reputation at 15:10; failures roll back. `FakeInboxRepositoryTest`: the seven rows in order with their tags and unread; `setRead(false)` gives 1 unread, `setRead(true)` 0, the count follows; archive hides and unarchive puts the row back in time order with its unread; block hides the row and Thanh Lý 24h's listings, restore brings both back and removes the report; a blocked row stays hidden after another row changes. `FakeWorldConsistencyTest`: a deal started from a listing shows in the inbox and on Listing detail's button; placing COD shows in `orders()` and on the inbox tag.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: fake the inbox, orders, checkout and new deals`.

### Task 9: Simulator and debug jumps

**Files:** Modify `fake/Simulator.kt`, `fake/DebugControls.kt`; create `fake/OrderJumps.kt`; modify the debug panel in `app/src/debug/`. Tests: `SimulatorTest` (grows), `OrderJumpsTest`.

```kotlin
// Simulator.onCommand grows:
//   PlaceCod      → after 3_500: SHIPPING, pickedUpAt, events "Đã lấy hàng tại {seller district}", "Đến kho {my district}", eta (hour−1, hour+1), thread "{seller} đã gửi hàng";
//                   after 7_000: AT_DOOR, atDoorAt, event "Shipper đang giao", thread door "Shipper đang ở cửa", notification door-{id}
//   ShipParcel    → after 1_600: event "Đến kho {buyer district}", eta tomorrow; after 3_200: RECEIVED, stage RATE, receivedAt, handedOverAt
//   SendOffer     → on new deals as stage 1, with "Ok bạn, {giá} mình chốt. Bạn hẹn gặp hay đặt COD đều được nhé." when both ways are open
//   OpenRecord    → the deal's RecordReply, or nothing
//   a reply that adds a seller message unarchives and adds 1 unread
fun DebugControls.jumpOrder(id: DealId, status: OrderStatus)
var DebugControls.simulatedScanner: Boolean
```

`OrderJumps.orderAt(seed, status, now, zone)` builds the seeded deal at each status of the spec's tables for d-nam (PLACED, SHIPPING, AT_DOOR, RECEIVED, REVIEWED, REFUSED, EXPIRED, RECORD_OPEN), d-huy (TO_SHIP, SHIPPING, RECEIVED, REFUSED, EXPIRED, RECORD_OPEN with the mockup's chair-leg text and note, RECORD_REFUNDED, RECORD_DECLINED) and d-han (WAITING, MET, REVIEWED, CANCELLED, RECORD_OPEN, RECORD_DECLINED), with the thread items a real walk leaves.

- [ ] **Step 1: Failing tests** on virtual time: placing COD on d-nam is SHIPPING at 3,5 s and AT_DOOR at 7 s with the three events and one new unread notification; shipping d-huy is RECEIVED at 3,2 s; an offer on a new both-ways deal is accepted at 2,4 s into Choosing; a record on d-han is declined at 2,4 s, on d-kiet refunded at 2,2 s, on d-nam never answered; `aReplyToAWithdrawnRecordIsDropped`; a seller message on an archived deal unarchives it; `speed = 4` divides every timing. `OrderJumpsTest`: each jump's `orderStatus` equals its target.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement**; the debug panel lists the three orders and their states, and a "Quét giả lập" switch.
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: play the carrier and the new people in the simulator`.

### Task 10: Design-system components

**Files:** Create `StatusHero.kt`, `Timeline.kt`, `ToggleGroup.kt`, `SwipeRow.kt`, `StatusTag.kt`; modify `Milestone.kt` (`MilestoneTone.NEUTRAL`: `surfaceContainerHighest` / `onSurfaceVariant`); add symbols (`door_front`, `schedule_send`, `storefront`, `shopping_bag`, `archive`, `mark_email_read`, `mark_email_unread`, `account_balance`, `account_balance_wallet`, `content_copy`, `directions`, `event_busy`, `trending_up`, `block`, `undo`, `receipt_long`, `add_a_photo`, `gavel`, `hourglass_top`, `timer`, `report`, `person_add`, `qr_code_2`, `verified`, `payments`, `local_shipping`, `location_on`, `package_2`, the ones that exist skipped). Test: `DealComponentsTest.kt` with screenshots in four variants.

```kotlin
@Composable fun StatusHero(shape: RoundedPolygon, tone: MilestoneTone, icon: Symbol, title: String, facts: List<Pair<Symbol, String>>, feeling: String? = null, modifier: Modifier = Modifier)
data class TimelinePhase(val label: String, val time: String?, val icon: Symbol)
@Composable fun Timeline(phases: List<TimelinePhase>, current: Int, modifier: Modifier = Modifier)   // current 4 = all done
data class ToggleOption(val label: String, val icon: Symbol)
@Composable fun ToggleGroup(options: List<ToggleOption>, selected: Int, onSelect: (Int) -> Unit, label: String, modifier: Modifier = Modifier)
@Composable fun SwipeRow(startIcon: Symbol, startLabel: String, onStart: () -> Unit, endIcon: Symbol, endLabel: String, onEnd: () -> Unit, modifier: Modifier = Modifier, content: @Composable () -> Unit)
@Composable fun StatusTag(icon: Symbol, text: String, modifier: Modifier = Modifier)
```

`StatusHero` is a polite live region with the title as a heading. `Timeline` uses the stepper's icons (40 dp, 2 dp vertical lines, done = check on `primary`). `ToggleGroup` uses M3 Expressive `ToggleButton`s with `ButtonGroupDefaults.connectedLeadingButtonShapes()`/`connectedTrailingButtonShapes()`, radio semantics and `label` as the group name. `SwipeRow` wraps `SwipeToDismissBox`: positional threshold 96 dp, start-to-end calls `onStart` and springs back (`confirmValueChange` false), end-to-start calls `onEnd`; the backdrop icon scales 1 → 1.2 past the threshold unless reduced motion; `startLabel`/`endLabel` become custom actions.

- [ ] **Step 1: Failing tests.** Screenshots of each component; `ToggleGroupTest` (radio semantics, selection callback); `SwipeRowTest` (a 120 dp right drag calls `onStart` once and returns to offset 0; a 60 dp drag calls nothing; a 120 dp left drag calls `onEnd`; the custom actions call the same); `TimelineTest` (labels and times readable, the current phase's label in the step description); `StatusHeroTest` (heading, live region); every component at font scale 1.3 without clipping.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, record the screenshots and look at each.
- [ ] **Step 5: Commit** `feat: add the hero, timeline, toggle group and swipe row`.

### Task 11: Shared deal pieces (`:core:ui`)

**Files:** Create in `core/ui/.../ui/deal/`: `OrderCopy.kt`, `CheckList.kt`, `RecordSheet.kt` and `MeetingSheet.kt` (moved from `feature/deal/.../chat/Sheets.kt` with their strings, renamed `deal_ui_*`), `Rating.kt`, `Rows.kt`, `CarrierEvents.kt`, `QrCode.kt`, `CodInfoSheet.kt`; add ZXing to `core/ui/build.gradle.kts`. Test: `DealPiecesTest.kt` (screenshots and behaviour).

```kotlin
data class OrderLine(val icon: Symbol, val text: String)
data class OrderAction(val label: String, val route: NavKey)
@Composable fun orderLine(view: DealView, status: OrderStatus, now: Instant, zone: ZoneId): OrderLine     // the spec's Đơn hàng table
@Composable fun orderAction(view: DealView, status: OrderStatus): OrderAction?                          // null: stars or none
/** A pool listing opens Listing detail; one of my own listings opens stage 4's "Tin của bạn" placeholder. */
fun itemRoute(view: DealView): NavKey
@Composable fun CheckListBlock(title: String, checks: List<CheckItem>, marks: List<DeclaredMark>, onCheck: (String, Boolean) -> Unit, modifier: Modifier = Modifier)
@Composable fun ChecksLeftDialog(left: Int, confirm: String, onConfirm: () -> Unit, onKeepChecking: () -> Unit)   // "Vẫn quét" or "Vẫn nhận"
@Composable fun RecordSheet(person: String, draft: RecordDraft, onPhoto: (String) -> Unit, onText: (String) -> Unit, onSend: () -> Unit, onDismiss: () -> Unit)
@Composable fun MeetingSheet(points: List<MeetPoint>, times: List<TimeOption>, current: Meeting?, onSend: (Instant, MeetPoint) -> Unit, onDismiss: () -> Unit)
@Composable fun RatingRow(person: String, stars: Int?, onRate: (Int) -> Unit, modifier: Modifier = Modifier)
@Composable fun ItemRow(listing: ListingSummary, price: Vnd, onClick: () -> Unit)
@Composable fun PersonRow(person: SellerSummary, detail: String, onChat: () -> Unit)
@Composable fun CarrierEvents(events: List<CarrierEvent>, now: Instant, zone: ZoneId)
@Composable fun QrCode(text: String, modifier: Modifier = Modifier)      // ZXing BitMatrix drawn on a Canvas, onSurface on surface
@Composable fun CodInfoSheet(onDismiss: () -> Unit)                     // "COD xem hàng" and MoneyStep.COD_INFO
// RecordDraft and TimeOption move here from the Chat feature.
```

- [ ] **Step 1: Failing tests.** `itemRoute` for d-han (`ListingRoute("p-fixed")`) and d-huy (`PlaceholderRoute(4, "Tin của bạn")`); `orderLine` for every row of the spec's Đơn hàng table (built with `OrderJumps`), with the noun; `orderAction` routes (WAITING → `OrderRoute`, ARRANGING → `ChatRoute`, RECEIVED for the buyer → null); `CheckListBlock` counts "0/4" then "1/4"; `ChecksLeftDialog` body "Còn 3 mục chưa kiểm. …" and both buttons; `RecordSheet` send disabled until a photo and text; `RatingRow` radios "1 sao" … "5 sao"; `QrCode` draws the same matrix for the same text and its content description is the code; screenshots of each piece; Chat's stage 1 tests still pass with the moved sheets.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: share the deal pieces between Chat and the order pages`.

### Task 12: The scanner on CameraX and ML Kit

**Files:** Create `core/ui/.../ui/deal/Scanner.kt` (moved `ScannerOverlay` grows), `ScanMode.kt`; modify `core/ui/build.gradle.kts` (CameraX, ML Kit), `gradle/libs.versions.toml`, `app/src/main/AndroidManifest.xml` (`CAMERA` permission, `android.hardware.camera.any` not required), `MainActivity.kt` (provides `LocalScanMode`); remove `QrScanner`, `FakeQrScanner` and their binding; modify `ChatViewModel` (`Scanned(code)` replaces `scanner.scan()`). Tests: `ScannerTest.kt`, `ChatViewModelTest` (grows).

```kotlin
enum class ScanMode { CAMERA, SIMULATED }
val LocalScanMode = staticCompositionLocalOf { ScanMode.SIMULATED }
/** Full screen: the camera (or the person's photo at 40 % when simulated), what the scan records, the frame and its line. */
@Composable fun ScannerOverlay(person: String, backdrop: String?, onCode: (String) -> Unit, onClose: () -> Unit)
```

CAMERA: `rememberLauncherForActivityResult(RequestPermission())` on first open; granted → `ProcessCameraProvider` with `Preview` (shown through `CameraXViewfinder`) and `ImageAnalysis` (`STRATEGY_KEEP_ONLY_LATEST`) feeding `BarcodeScanning.getClient(BarcodeScannerOptions.Builder().setBarcodeFormats(FORMAT_QR_CODE))`; the first non-blank `rawValue` shows the check for 700 ms, then `onCode`; the camera unbinds on dispose. Refused → "Cần quyền camera để quét mã." with "Cho phép", or "Mở cài đặt" (`ACTION_APPLICATION_DETAILS_SETTINGS`) once `shouldShowRequestPermissionRationale` is false after a refusal. SIMULATED: stage 1's backdrop and a read after 1.6 s with the code `simulated`. `MainActivity` provides CAMERA when `FEATURE_CAMERA_ANY` is present and the debug switch is off.

- [ ] **Step 1: Failing tests.** `ScannerTest` (Robolectric, SIMULATED): the title and text show; `onCode("simulated")` after 1.6 s of the paused clock and not before; close calls `onClose` and no code; reduced motion shows no moving line. CAMERA with the permission denied (Robolectric `ShadowApplication.denyPermissions`): the permission text and "Cho phép" show. `ChatViewModelTest.aScannedCodeRecordsTheHandOver` (StartScan → `scanning`, `Scanned("x")` → `RecordHandover("x")`, `scanning` false).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate; `./gradlew :app:assembleDebug` shows the APK size grows by the ML Kit model (about 3 MB) and no more.
- [ ] **Step 5: Commit** `feat: scan the seller's code with the camera`.

### Task 13: Chat for both sides

**Files:** Modify `feature/deal/.../chat/ChatUiState.kt`, `ChatViewModel.kt`, `ChatScreen.kt`, `Thread.kt`, `Console.kt`, `Composer.kt`, `res/values/strings.xml`. Tests: `ChatViewModelTest`, `ChatScreenTest`, `ConsoleTest` (grow).

UI state gains `mine: Party`, `noun: String`, `orderLine: OrderLine?`, `orderAction: OrderAction?`, `counterpartSells: Boolean`. Events gain `Scanned(code)`, `AttachPhotos(urls)`, `ChooseMeeting` (opens the meeting sheet from Choosing), `PlaceCod` (navigates to `CodCheckoutRoute`), `OpenOrder` (navigates to the action's route). The ViewModel calls `inbox.setRead(id, true)` on start and whenever a new item from the other side arrives while subscribed. Thread bubbles compare `by` with `mine`; the app bar's listing opens `itemRoute(view)`. Console bodies per the spec's table; "Kiểm {noun} n/m" and "{Noun} có vấn đề?"; the seller's Done has no record button; Choosing's notes `MoneyStep.DEAL_CHOOSING`. The attach button opens `PickMultipleVisualMedia(4)` and sends `SendPhotos`.

- [ ] **Step 1: Failing tests.** `ChatViewModelTest`: opening d-quang marks it read; a seller message arriving while open keeps unread 0; `AttachPhotos` sends `SendPhotos` with the urls. `ChatScreenTest`: `aSellersOwnMessagesSitOnTheRight` (d-quang: Minh Quang's question on the left; a sent reply on the right); d-quang's console shows "1.900.000 ₫", "Giá bạn đăng" and no button; d-nam shows Choosing with "Hẹn gặp" and "Đặt COD" and the two sentences, "Đặt COD" pushes `CodCheckoutRoute("d-nam")`, "Hẹn gặp" opens "Hẹn gặp"; d-huy shows "Gửi hàng" pushing `OrderRoute("d-huy")`; d-han shows "Kiểm xe 0/4"; d-bao's menu has no "Trang người bán"; d-24h's console offers "Đồng ý" on 8.700.000 ₫; font scale 1.3 for the new states. Screenshots: Choosing, OrderStep (TO_SHIP, AT_DOOR), Selling, Ended (REFUSED).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: open every conversation in Chat, as buyer or seller`.

### Task 14: New deals

**Files:** Modify `feature/discover/.../detail/ListingDetailViewModel.kt` and screen; `feature/seller/.../profile/SellerScreen.kt`, `SellerViewModel.kt`, create `ListingPickSheet.kt`; `feature/saved/.../page/SavedViewModel.kt`; `core/ui` card helpers if they route to stage 3's placeholder. Tests: `ListingDetailViewModelTest`, `SellerScreenTest`, `SavedScreenTest` (grow).

"Nhắn tin" without a deal calls `start` and opens Chat; "Trả giá" opens the offer sheet and `SendOffer` starts the deal first; a question chip starts it and sends the text with its snackbar ("Đã gửi câu hỏi" + "Xem"); Người bán's chat button opens `profile.dealId` or the sheet "Nhắn về tin nào?" (the seller's listings on sale as 64 dp rows), whose choice starts a deal and opens Chat; the compare pick's "Nhắn người bán" starts a deal on `pick.listing`; a failed `start` leaves the screen as it was and shows the snackbar "Chưa gửi được. Thử lại".

- [ ] **Step 1: Failing tests.** On `p-giant`: "Nhắn tin" opens `ChatRoute` of the new deal; an offer of 2.500.000 ₫ creates the deal and puts the price move in it; a question chip sends it; on Ngọc Hân's page the chat button opens `ChatRoute("d-han")`; on Mai Anh's page it opens the sheet with her five listings and a choice opens a new deal's Chat; the bike pick in "So sánh" opens a deal on the single speed; no `PlaceholderRoute(3, …)` is pushed anywhere (`grep` in the test sources asserts none remain in `main`).
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: start a deal from a listing, a seller or a comparison`.

### Task 15: Tin nhắn

**Files:** Create `feature/inbox/.../InboxScreen.kt`, `InboxViewModel.kt`, `ScamSheet.kt`, strings; modify `InboxInstaller.kt`; remove `InboxRoute` from `PlaceholderInstaller`; modify `MainActivity.kt` and `AppNavigation.kt` (`AppViewModel` with `InboxRepository.unreadCount()`; `NavItem(badge = n.takeIf { it > 0 })` on Tin nhắn). Tests: `InboxViewModelTest`, `InboxScreenTest`, `AppNavigationTest` (grows).

```kotlin
enum class InboxFilter { ALL, BUY, SELL, UNREAD }
data class InboxUiState(val content: InboxContent, val filter: InboxFilter, val scamFor: DealId?)
sealed interface InboxEvent {
    data class Filter(val filter: InboxFilter) : InboxEvent
    data class Open(val row: InboxRow) : InboxEvent         // a warning opens the sheet, else Chat
    data class ToggleRead(val row: InboxRow) : InboxEvent
    data class Archive(val row: InboxRow) : InboxEvent
    data object BlockAndReport : InboxEvent
    data object OpenAnyway : InboxEvent
    data object CloseScam : InboxEvent
    data object Retry : InboxEvent
}
```

Layout from the spec. The chip counts read from the rows (Chưa đọc counts rows with unread). The filter and the open sheet live in `SavedStateHandle`.

- [ ] **Step 1: Failing tests.** `InboxScreenTest`: the seven rows in order with names, times ("14:10" … "Thứ Hai"), titles, "Tin của bạn" on three, previews ("Bạn: Hẹn bạn 18h ở công viên Gia Định nhé."), tags ("10,6 tr", "Nghi lừa đảo", "Chờ gửi", "3,8 tr", "2,3 tr", "650.000 ₫"); "Chưa đọc (3)"; Mua shows four rows, Bán three, Chưa đọc three; each empty text with a matching filter over an empty inbox and "Khám phá tin quanh bạn" selecting Home; a row opens `ChatRoute`; the scam row opens the sheet; "Chặn và báo cáo" removes the row and "Hoàn tác" restores it; "Vẫn mở cuộc trò chuyện" opens Chat; the swipe custom actions ("Đánh dấu đã đọc", "Lưu trữ") call the repository and show their snackbars; "Tìm trong tin nhắn" pushes `PlaceholderRoute(0, …)`; font scale 1.3. `InboxViewModelTest`: `filterSurvivesRecreation`, `scamSheetSurvivesRecreation`, a failed archive restores the row and says "Chưa lưu được. Thử lại". `AppNavigationTest`: the badge reads 3, then 2 after a row is read. Screenshots: the inbox, each empty chip, the scam sheet, a row mid-swipe both ways.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Tin nhắn`.

### Task 16: Giao COD

**Files:** Create `feature/orders/.../checkout/CodCheckoutScreen.kt`, `CodCheckoutViewModel.kt`, strings; modify `OrdersInstaller.kt`. Tests: `CodCheckoutViewModelTest`, `CodCheckoutScreenTest`.

```kotlin
data class CodCheckoutUiState(val content: CheckoutContent, val carrier: String, val placing: Boolean, val placed: Boolean)
sealed interface CodCheckoutEvent {
    data class Carrier(val id: String) : CodCheckoutEvent
    data object Place : CodCheckoutEvent
    data object ViewOrder : CodCheckoutEvent      // navigator.replace(OrderRoute)
    data object ChangeAddress : CodCheckoutEvent  // PlaceholderRoute(5, "Địa chỉ giao hàng")
    data object ChangePayment : CodCheckoutEvent  // PlaceholderRoute(5, "Phương thức thanh toán")
    data object ViewRights : CodCheckoutEvent     // PlaceholderRoute(5, "Điểm uy tín")
    data object Retry : CodCheckoutEvent
}
```

- [ ] **Step 1: Failing tests.** `CodCheckoutScreenTest` on d-nam: the item with "Đã chốt" and "3.800.000 ₫"; "Khánh Linh · 09•• ••• 812"; Giao nhanh selected; choosing Tiết kiệm changes "Trả bây giờ" and the docked amount to "16.000 ₫"; the three sentences; "COD của bạn: 1/5 đơn đang mở sau đơn này"; "Đặt COD" shows the milestone "Đã đặt giao COD" with "Hoàng Nam có 48 giờ để gửi hàng. Bạn xem máy rồi mới trả." and "Xem đơn" replaces with `OrderRoute("d-nam")`; with four open COD orders the line reads "COD của bạn: đã đủ 5/5 đơn đang mở" and "Đặt COD" is disabled; font scale 1.3. `CodCheckoutViewModelTest`: `placingTwiceSendsOneCommand`; a failed place keeps the screen, says "Chưa gửi được. Thử lại" and the button enabled; `carrierSurvivesRecreation`; `placedSurvivesRecreation` (the deal is placed, so a recreated screen shows the milestone). Screenshots: before and after placing, in four variants for the first.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Giao COD`.

### Task 17: Đơn hàng

**Files:** Create `feature/orders/.../list/OrdersScreen.kt`, `OrdersViewModel.kt`, strings. Tests: `OrdersViewModelTest`, `OrdersScreenTest`.

```kotlin
data class OrdersUiState(val content: OrdersContent, val side: Party, val buyCount: Int, val sellCount: Int, val now: Instant)
sealed interface OrdersEvent {
    data class Side(val side: Party) : OrdersEvent
    data class Rate(val dealId: DealId, val stars: Int) : OrdersEvent
    data object Retry : OrdersEvent
}
```

The header opens `OrderRoute` except a seller's in-person order, which opens `ChatRoute`; the chat button opens `ChatRoute`; the action from `orderAction`.

- [ ] **Step 1: Failing tests.** `OrdersScreenTest`: "Mua · 2" and "Bán · 2"; Mua shows the bike ("location · 18:00 hôm nay · Công viên Gia Định", "Kiểm xe và quét mã", stepper "Bước 3 trên 4: Gặp và kiểm") and the headphones ("Đã xem và trả shipper · Thứ Hai" and five stars, "Bước 4 trên 4: Đánh giá"); rating 5 turns the line into "5 sao cho Quốc Bảo" and the stepper into "Đã xong cả 4 bước"; `OrdersRoute("SELL")` opens on Bán with the stool ("Gửi trước 18:00 thứ Sáu · còn 26 giờ", "Gửi hàng") and the shelf ("Đã gặp và nhận tiền · Thứ Hai", no action); the shelf's header opens `ChatRoute("d-bao")`; "Nhắn Ngọc Hân" opens `ChatRoute("d-han")`; after placing d-nam's COD the Mua count reads 3; both empty sides with their text; font scale 1.3. `OrdersViewModelTest`: `sideSurvivesRecreation`; a failed rating keeps the stars and shows the error. Screenshots: Mua, Bán, empty, in four variants for Mua.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Đơn hàng`.

### Task 18: Chi tiết đơn and the order router

**Files:** Create `feature/orders/.../OrderRouter.kt`, `meet/MeetOrderScreen.kt`, `MeetOrderViewModel.kt`, strings. Tests: `OrderRouterTest`, `MeetOrderViewModelTest`, `MeetOrderScreenTest`.

```kotlin
/** Reads the deal once and shows its page: in person as buyer, COD as buyer, COD as seller; a seller's in-person order becomes its Chat. */
@Composable fun OrderRouter(route: OrderRoute, navigator: Navigator)
sealed interface MeetOrderEvent {
    data class Check(val id: String, val on: Boolean) : MeetOrderEvent
    data object Scan : MeetOrderEvent
    data class Scanned(val code: String) : MeetOrderEvent
    data object CloseScanner : MeetOrderEvent
    data class Rate(val stars: Int) : MeetOrderEvent
    data object AskCancel : MeetOrderEvent
    data object Cancel : MeetOrderEvent
    data object ConfirmMeeting : MeetOrderEvent
    data object ChangeMeeting : MeetOrderEvent
    data class ProposeMeeting(val at: Instant, val place: MeetPoint) : MeetOrderEvent
    data object Directions : MeetOrderEvent
    data object CopyCode : MeetOrderEvent
    data object OpenRecord : MeetOrderEvent
    // record draft events as Chat's, WithdrawRecord, ConfirmRefund, Help, Retry
}
```

The hero and bar per the spec's Chi tiết đơn table; the "Chưa kiểm xong" dialog before the scanner; the cancel dialog's body from `cancelPenalty`; `Directions` fires an `ACTION_VIEW geo:0,0?q=Công viên Gia Định, Phú Nhuận` intent and, when no app resolves it, the snackbar "Chưa có ứng dụng bản đồ"; `CopyCode` writes a `ClipData` and shows the snackbar only below API 33; "Trợ giúp" opens `PlaceholderRoute(0, "Trợ giúp")`.

- [ ] **Step 1: Failing tests.** `OrderRouterTest`: d-han → Chi tiết đơn, d-nam after placing → Đơn COD, d-huy → Đơn bán, d-bao → `replace(ChatRoute("d-bao"))`, an unknown id → the missing state. `MeetOrderScreenTest` (d-han and its jumps): WAITING's hero, timeline labels and times ("12/10 · 14:20", "Hôm qua · 14:32", "18:00 hôm nay"), "Kiểm tra khi gặp 0/4", the mark, the meeting rows, the money rows and sentences, SN-24817; checking two items reads "2/4"; "Quét mã của Ngọc Hân" with checks left opens "Chưa kiểm xong"; "Vẫn quét" opens the scanner and the simulated read moves to MET ("Giao dịch đã ghi nhận", "Đã trả 2.300.000 ₫ tại chỗ", "Chúc bạn đạp xe thật vui!"); rating 5 → REVIEWED; "Hủy hẹn" asks with −20 at 15:10 and −30 at 16:30 and ends on CANCELLED with "−20 điểm uy tín"; "Xe có vấn đề?" → record → RECORD_OPEN, then after 2,4 s RECORD_DECLINED's line; "Rút ghi nhận" returns to REVIEWED with "Đã rút ghi nhận"; d-kiet after agreement shows ARRANGING with "Đồng ý hẹn", and its refunded record shows "Đã nhận tiền hoàn"; copy writes the clipboard; directions fire the geo intent (Robolectric `shadowOf(app).nextStartedActivity`); font scale 1.3 for WAITING and MET. `MeetOrderViewModelTest`: `recordDraftSurvivesRecreation`, `cancelDialogSurvivesRecreation`, a failed scan record keeps WAITING. Screenshots: each status, four variants for WAITING.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Chi tiết đơn and route each order to its page`.

### Task 19: Đơn COD

**Files:** Create `feature/orders/.../cod/CodOrderScreen.kt`, `CodOrderViewModel.kt`, `RefuseDialog.kt`, strings. Tests: `CodOrderViewModelTest`, `CodOrderScreenTest`.

```kotlin
sealed interface CodOrderEvent {
    data class Check(val id: String, val on: Boolean) : CodOrderEvent
    data object Receive : CodOrderEvent          // checks left → the dialog with "Vẫn nhận"
    data object ReceiveAnyway : CodOrderEvent
    data object AskRefuse : CodOrderEvent
    data class ToggleReason(val reason: RefusalReason) : CodOrderEvent
    data object Refuse : CodOrderEvent
    data class Rate(val stars: Int) : CodOrderEvent
    // record draft events, WithdrawRecord, ConfirmRefund, Chat, Item, Retry
}
```

The ViewModel's clock ticks each minute (`flow { while (true) { emit(clock.instant()); delay(60_000) } }`), so the countdown and EXPIRED follow time. Status changes from the simulator show their snackbars ("Hoàng Nam đã gửi hàng", "Shipper đang ở cửa") while the screen is subscribed.

- [ ] **Step 1: Failing tests.** `CodOrderScreenTest` (d-nam after `PlaceCod` and the jumps): PLACED "Chờ Hoàng Nam gửi hàng", "Còn 47 giờ" and the "Hạn gửi hàng" sentence, timeline "Trước … thứ Bảy"; SHIPPING "Đang giao" with "Dự kiến 14:00–16:00 hôm nay" and two carrier events; AT_DOOR "Shipper đang ở cửa", "Xem hàng 0/4", "Xước nhẹ cạnh phải", both sentences, the bar; "Nhận · trả 3,8 tr" with checks left opens the dialog with "Vẫn nhận"; receiving → "Đã nhận iPhone X", "Đã trả 3.800.000 ₫ cho shipper", the stars; "Từ chối nhận" → the dialog with its body and three chips, choosing two and confirming → REFUSED with "Máy quay về Hoàng Nam", "Bạn mất 22.000 ₫ phí ship" and "Đã báo shipper trả máy về Hoàng Nam"; EXPIRED "Hoàng Nam chưa gửi hàng", "Đã hoàn 22.000 ₫ phí ship về MoMo"; RECORD_OPEN "Chờ Hoàng Nam trả lời"; money rows "Đã trả phí ship 22.000 ₫", "MoMo · hôm qua 20:16 · không hoàn" for a placement yesterday at 20:16; font scale 1.3 for AT_DOOR and RECEIVED. `CodOrderViewModelTest` on virtual time: `theDoorArrivesWhileOpen` (snackbars in order), `theWindowLapsingShowsExpired` (advance the clock 48 h with no pickup), `receiveWaitsForPendingChecks`, `refusalReasonsSurviveRecreation`, a failed receive stays AT_DOOR. Screenshots: each status, four variants for AT_DOOR.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Đơn COD`.

### Task 20: Đơn bán

**Files:** Create `feature/orders/.../ship/ShipOrderScreen.kt`, `ShipOrderViewModel.kt`, `RefundSheet.kt`, `ShippingCodeSheet.kt`, strings; reuse `:core:ui`'s camera capture from Photo search (`rememberTakePicture` or its equivalent; extract it if it is private). Tests: `ShipOrderViewModelTest`, `ShipOrderScreenTest`.

```kotlin
sealed interface ShipOrderEvent {
    data class Photo(val uri: String) : ShipOrderEvent
    data class Method(val method: ShipMethod) : ShipOrderEvent
    data object ShowCode : ShipOrderEvent
    data object Confirm : ShipOrderEvent
    data object AskRefund : ShipOrderEvent
    data class RefundAmount(val amount: Vnd) : ShipOrderEvent
    data object Refund : ShipOrderEvent
    data object AskDecline : ShipOrderEvent
    data object Decline : ShipOrderEvent
    // Chat, Close, Retry
}
```

- [ ] **Step 1: Failing tests.** `ShipOrderScreenTest` (d-huy and its jumps): TO_SHIP "Gửi trước 18:00 thứ Sáu", "Còn 26 giờ"; the three steps; "Xác nhận gửi" disabled; a photo result turns step 1 into a check with "Chụp trong app · vừa xong" and enables it; "Hiện mã QR" opens "Mã gửi hàng" with the drawn code described as "SNX 8841 2207"; drop-off selected then confirming says "Đã báo bên vận chuyển. Mang ra bưu cục trước 18:00 thứ Sáu"; pickup says "… Shipper tới lấy 14:00–18:00"; after 3,2 s "Đức Huy đã nhận hàng", "Tiền về tài khoản trong 1–2 ngày", "Món đồ cũ đã có chủ mới."; REFUSED "Đức Huy từ chối nhận", "Phí chiều về 22.000 ₫"; RECORD_OPEN shows the incident card ("Ghi nhận của Đức Huy", the text, the note, the declared-marks sentence), "Bạn trả lời trong 3 ngày" and the bar; "Tự hoàn" opens the sheet with 50.000, 100.000 (selected), 350.000 "Hoàn toàn bộ" and the note; confirming → "Bạn đã tự hoàn", "+15 điểm uy tín", "Đã báo Đức Huy bạn hoàn 100.000 ₫"; "Từ chối" asks and ends on "Bạn đã từ chối", "Ghi nhận hiện trên hồ sơ của bạn"; EXPIRED "Đơn đã tự hủy"; the money rows and sentences; font scale 1.3 for TO_SHIP and RECORD_OPEN. `ShipOrderViewModelTest`: `photoAndMethodSurviveRecreation`, `refundSheetSurvivesRecreation`, a failed confirm keeps TO_SHIP with the photo. Screenshots: each status, four variants for TO_SHIP.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: build Đơn bán`.

### Task 21: Entry points

**Files:** Modify `feature/discover/.../home/HomeScreen.kt` (the COD slide opens `CodInfoSheet`), `feature/notifications/.../NotificationsViewModel.kt` (`Order(dealId)` → `OrderRoute`), `feature/placeholder` (no stage 3 placeholder left). Tests: `HomeScreenTest`, `NotificationsViewModelTest`, `PlaceholderScreenTest` (grow).

- [ ] **Step 1: Failing tests.** The COD slide's "Tìm hiểu" opens "COD xem hàng" with its five sentences; the "ship" notification opens `OrderRoute("d-huy")`, "meet" `OrderRoute("d-han")`, the posted door notification `OrderRoute("d-nam")`; a test fails if any `PlaceholderRoute(3, …)` remains in `main` sources.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: open the stage 3 screens from Home, Thông báo and Tôi`.

### Task 22: End-to-end walks and the device review

**Files:** Create `app/src/test/.../DealsWalkTest.kt`; fixes found on the device go in their own commits with their tests.

- [ ] **Step 1: Walk tests** on the whole app with Hilt test bindings and virtual time: `codWalk` (Tin nhắn → Hoàng Nam → "Đặt COD" → Giao COD → "Đặt COD" → "Xem đơn" → 7 s → "Nhận · trả 3,8 tr" → "Vẫn nhận" → 5 stars → back to Chat → Tôi → Đơn mua shows "5 sao cho Hoàng Nam"); `shipWalk` (Tôi → Đơn bán → the stool → a photo → "Xác nhận gửi" → 3,2 s → "Đức Huy đã nhận hàng" → Tin nhắn's Đức Huy row has no "Chờ gửi" tag); `meetWalk` (Home bell → Ngọc Hân's row → Chi tiết đơn → four checks → scan (simulated) → 5 stars → "Xe có vấn đề?" → a photo and text → "Gửi ghi nhận" → 2,4 s → "Ngọc Hân từ chối · hiện trên hồ sơ của họ").
- [ ] **Step 2: Run, expect PASS** (the screens exist; a failure here is a bug to fix with its own test).
- [ ] **Step 3: Device walk** on the API 36 emulator: every control of the six screens and Chat's new states, the three walks by hand, the debug jumps for each status, predictive back from each screen, TalkBack on Tin nhắn's swipe actions, font scale 1.3, dark theme; the camera scanner on a device or the emulator's virtual scene reading a QR code. Every dead control or difference from the mockup that is not a ruling gets a failing test, a fix and a commit.
- [ ] **Step 4: Side-by-side review** of each screen state's screenshot with its mockup render (`node tools/shoot.mjs` in `app2/.superdesign`, `montage` for the pairs) and the mockup checker (`node tools/check_mockups.mjs`) passing for all 31 screens.
- [ ] **Step 5: Gate and commit** `test: walk the COD, shipping and meeting flows end to end`.
