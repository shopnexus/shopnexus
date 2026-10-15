# app2 stage 5 (Tài khoản và tin cậy) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Tôi, Hoàn thiện hồ sơ, Điểm uy tín, the five eKYC steps, Chào mừng and Đăng nhập on the stage 1 to 4 foundation with fake data, and retire every stage placeholder left in the app.

**Architecture:** Three new feature modules (`:feature:me`, `:feature:kyc`, `:feature:auth`); the session lives in `:app` and the navigator. The contract grows in `:core:model`; account rules are pure functions in `:core:domain`; the fakes gain the session, the profile, the reputation history and eKYC, and the simulator approves a manual review. Screens follow stages 1 to 4: one ViewModel with `StateFlow` state and a `Channel` of effects per screen.

**Tech Stack:** stage 4's (Kotlin 2.4.21, AGP 9.4.1, Compose BOM with material3 1.5.0-beta01, Navigation 3, Hilt, Coil 3, CameraX 1.6.2, Robolectric, Roborazzi, Turbine, Truth). No new dependency: the CCCD capture uses CameraX `ImageCapture`, the face step the front `Preview`, and NFC presence `NfcAdapter.getDefaultAdapter`.

**Spec:** `/home/beanbocchi/shopnexus/specs/2026-10-16-app2-stage5-account-design.md`. Data, strings and interactions with source lines: `app2/.superdesign/stage5-digest.md` (committed in Task 4). Mockups: `app2/.superdesign/tools/build_{me,tasks,rep,kyc,welcome,login}.py`, `common.py`.

**Ruling on this plan's form:** as in stages 2 to 4, the plan writes out the contract types, the rule signatures with their test cases and the fixture formats; screen tasks fix the UI state, events, layout and every test by name and assertion, and the composables are written against them during execution. Cost if wrong: screen code is reviewed only at the final review.

## Global Constraints

- Everything in stages 1 to 4's Global Constraints holds (minSdk 31, compileSdk 37, targetSdk 36, JVM 21, package `vn.shopnexus`, features never depend on features, `:core:model` and `:core:domain` are JVM, colors only through the theme, the type scale, corners 4/8/12/16/20/28/32 dp, touch targets ≥ 48 dp, Vietnamese strings in `strings.xml` with one value per name across modules, money as `Vnd`, new symbols through `core/designsystem/symbols.txt` and `tools/gen_symbols.py`, fixture photos saved with `core/testing/tools/fetch_photos.py`).
- `primary` marks the next thing to do (the open identity task, the due deadline, gains); `error` marks losses and "Đăng xuất"; `tertiary` stays for price judgments; one primary-filled action per view.
- Identity, the code check and a save never show as done before the command succeeds.
- Strings prefixed per module (`me_`, `kyc_`, `auth_`) so `StringResourcesTest` passes.
- `./gradlew check verifyRoborazziDebug` passes at the end of every task (`app2/tmp/gate.sh <log>`, wrapped in `timeout 1500`).
- Scratch files, logs and review worktrees go under `app2/tmp/` (git-ignored), never `/tmp`.
- Commit messages and code comments go through the humanizing-writing checker; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. The session around a detour: a guest opening Tin nhắn, signing in, and landing back on Tin nhắn with the back stack intact; signing out with sheets or eKYC open; process death on each login step. Expected: one Đăng nhập on top, the stack restored, nothing of the person shown after sign-out. Pinned in Task 7 (`SessionNavigatorTest`) and Task 9 (`LoginViewModelTest.theStepSurvivesRecreation`).
2. eKYC interrupted: leaving at each step, process death with photos taken, the camera refused, a phone without NFC, a failed submit, the manual review approving while the person is on another screen. Expected: the exit dialog of ruling 13, the step and photos kept, the permission view, the sheet at once, the review again with consent kept, the check-list and Đăng tin updating. Pinned in Task 14 (`KycViewModelTest`) and Task 15 (`KycScreenTest`).
3. The score and the rights after play: a hand-over, a five-star rating, a cancellation, a self-refund, identity. Expected: Điểm uy tín, Tôi's chip and the tier agree; history newest first; `rightsFor()` caps in "Quyền của bạn". Pinned in Task 5 (`FakeReputationRepositoryTest`) and Task 12 (`ReputationScreenTest`).
4. Sheet validation on Hoàn thiện hồ sơ: an account number with spaces or 17 digits, a street of two letters, a bio of nine characters and of 151, "Viết giúp" over typed text. Expected: digits only, the errors of the digest, the counter, the save only when valid. Pinned in Task 3 and Task 11.
5. Giao COD's address change through Hoàn thiện hồ sơ while an order is open, and Tôi's due row as orders move. Expected: the new address on the next checkout, the due row following the nearest deadline and vanishing when nothing is due. Pinned in Task 10 and Task 16.

---

### Task 1: Stage 5 routes and modules

**Files:** Modify `core/navigation/.../Routes.kt`, `app/.../AppNavigation.kt` (installers), `settings.gradle.kts`, `app/build.gradle.kts`; create `feature/{me,kyc,auth}/build.gradle.kts`, manifests, `MeInstaller.kt`, `KycInstaller.kt`, `AuthInstaller.kt` (each route renders `PlaceholderScreen(title, 5)` until its task; `MeRoute` moves from `:feature:placeholder` to `:feature:me` with the existing links kept until Task 10). Tests: `InstallersTest`, `PlaceholderScreenTest`.

**Interfaces (Produces):**

```kotlin
@Serializable data class ProfileTasksRoute(val sheet: String? = null) : NavKey
@Serializable data object ReputationRoute : NavKey
/** [origin] is a KycOrigin name; [start] INTRO or CARD. */
@Serializable data class KycRoute(val origin: String, val start: String = "INTRO") : NavKey
@Serializable data object WelcomeRoute : NavKey
@Serializable data object LoginRoute : NavKey
```

- [ ] **Step 1: Failing tests.** `InstallersTest` expects 15 installers; `PlaceholderScreenTest.theMeTabListsSavedAndNotifications` keeps passing from `:feature:me`.
- [ ] **Step 2: Run, expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run, expect PASS**, then the gate.
- [ ] **Step 5: Commit** `feat: add the stage 5 routes and modules`.

### Task 2: The stage 5 contract (`:core:model`)

**Files:** Modify `People.kt` / `Account.kt` (whichever holds `Account`), `Notifications.kt`; create `Session.kt`, `Profile.kt`, `Reputation.kt` (model side), `Kyc.kt`, `Me.kt`. Test: `core/model/src/test/.../AccountJsonTest.kt`.

**Interfaces (Produces):**

```kotlin
@Serializable enum class Session { SIGNED_IN, GUEST, SIGNED_OUT }
@Serializable enum class KycState { NONE, PENDING, VERIFIED }
// Account grows: val bio: String? = null, val kyc: KycState = KycState.NONE; `verified` becomes `kyc == VERIFIED` (a getter kept for stage 4 callers; the JSON field `verified` is read for old fixtures).

@Serializable enum class TaskKey { IDENTITY, PAYOUT, ADDRESS, BIO, PHONE, AVATAR }
@Serializable data class ProfileTask(val key: TaskKey, val done: Boolean, val value: String? = null, val pending: Boolean = false)
@Serializable data class ProfileTasks(val tasks: List<ProfileTask>, val banks: List<String>, val wards: List<String>, val payout: PayoutForm?, val address: AddressForm?, val bio: String?)
@Serializable data class PayoutForm(val bank: String, val number: String)
@Serializable data class AddressForm(val street: String, val ward: String)

@Serializable data class HistoryRow(val icon: String, val text: String, val at: Moment, val points: Int)
@Serializable data class RightUse(val key: String, val used: Int, val cap: Int)   // "COD", "LISTINGS"
@Serializable data class Figures90(val codRefused: Int, val codOrders: Int, val recordsDeclined: Int, val recordsUnanswered: Int)
@Serializable data class Reputation(val score: Int, val tier: Tier, val identityDone: Boolean, val replyRate: String, val rights: List<RightUse>, val figures: Figures90, val history: List<HistoryRow>)

@Serializable enum class KycOrigin { SELL, REVIEW, TASKS, REP, ME }
@Serializable enum class CardSide { FRONT, BACK }
@Serializable data class CardCheck(val sharp: Boolean, val noGlare: Boolean, val corners: Boolean)
@Serializable data class ChipFields(val name: String, val number: String, val born: String, val home: String, val validUntil: String, val photoUrl: String)
@Serializable data class ChipRead(val percent: Int, val fields: ChipFields? = null)

@Serializable data class DueOrder(val dealId: DealId, val icon: String, val line: String, val deadline: String)
@Serializable sealed interface MeRow { … Draft(DraftCard), Live(LiveCard), Sold(SoldCard) }   // the Tin của bạn cards
@Serializable data class MeSummary(
    val name: String, val photoUrl: String?, val rating: Double, val reviews: Int, val district: String, val area: String,
    val score: Int, val tier: Tier, val kyc: KycState, val tasksDone: Int, val nextTask: TaskKey?,
    val due: DueOrder?, val saved: Int, val buying: Int, val selling: Int, val rows: List<MeRow>, val plan: PlanKey, val sellerId: UserId,
)
// NotificationTarget gains data object ProfileTasks and data object Reputation.
```

- [ ] **Step 1: Failing test.** `AccountJsonTest`: an old account JSON with `"verified": true` reads as `kyc == VERIFIED`; a `MeSummary` and a `Reputation` round-trip; `NotificationTarget.ProfileTasks` round-trips.
- [ ] **Steps 2–5** as Task 1; commit `feat: add the stage 5 contract`.

### Task 3: Account rules (`:core:domain`)

**Files:** Create `core/domain/.../Account.kt` (phone, resend, field checks, payout label, progress), `Standing.kt` (next tier, track, perks, history rows, 90-day figures, due order), `Kyc.kt` (`kycAfterSubmit`). Modify `core/navigation/.../Routes.kt` with `requiresAccount(route)`. Tests: `AccountRulesTest`, `StandingTest`, `RequiresAccountTest` (in `:core:navigation`).

**Interfaces (Produces):**

```kotlin
fun phoneDigits(text: String): String          // "0912 345 812" -> "912345812"; "+84 912" -> "84912"? no: non-digits dropped, one leading 0 dropped, at most 9
fun phoneValid(digits: String): Boolean        // ^[35789][0-9]{8}$
fun phoneLabel(digits: String, withZero: Boolean): String   // "912 345 812" / "0912 345 812"
const val RESEND_SECONDS = 45
fun resendLeft(sentAt: Instant, now: Instant): Int          // 45 … 0
fun accountDigits(text: String): String; fun accountValid(digits: String): Boolean   // 6..16
fun streetValid(text: String): Boolean          // trimmed length >= 3
const val BIO_MAX = 150; fun bioValid(text: String): Boolean   // trimmed 10..150
fun payoutLabel(form: PayoutForm): String       // "Vietcombank •• 3456"
data class Progress(val done: Int, val total: Int, val next: TaskKey?)
fun profileProgress(tasks: List<ProfileTask>): Progress
data class NextTier(val tier: Tier, val points: Int)
fun nextTier(score: Int): NextTier?             // 386 -> (REPUTABLE, 114); 486 -> (REPUTABLE, 14); 900 -> null
fun tierMin(tier: Tier): Int                    // 0, 200, 500, 800
fun trackFill(score: Int): Float                // score / 1000f, clamped
enum class Perk { COD_2, LISTINGS_5, COD_5, LISTINGS_20, COD_10, PRIORITY, COD_20, BADGE, BOOST_DISCOUNT }
fun tierPerks(tier: Tier): List<Perk>
fun historyRow(event: ReputationEvent, at: Instant, words: String): HistoryRow   // icon per event
fun dayLabel(at, now, zone) (existing) gives "Hôm nay", "12/10"
fun figures90(views: List<DealView>, account codOrders/codRefused, me: UserId, now: Instant): Figures90
fun dueOrder(views: List<DealView>, me: UserId, now: Instant, zone: ZoneId): DueOrder?   // TO_SHIP with the nearest deadline, then ARRANGING waiting for the seller, then RECORD_OPEN as seller
fun kycAfterSubmit(manual: Boolean): KycState   // VERIFIED / PENDING
fun requiresAccount(route: NavKey): Boolean     // Inbox, Me, Chat, Sell*, MyListings, Plans, Orders, Order, CodCheckout, Saved, Notifications, ProfileTasks, Reputation, Kyc
```

- [ ] **Step 1: Failing tests.**
  - `phoneDigits("0912 345 812") == "912345812"`, `phoneDigits("912-345-8123") == "912345812"`, `phoneValid("912345812")`, `!phoneValid("212345812")`, `phoneLabel("912345812", false) == "912 345 812"`, `phoneLabel("912345812", true) == "0912 345 812"`, `phoneLabel("9123", false) == "912 3"`.
  - `resendLeft(t, t) == 45`, `resendLeft(t, t + 44.2 s) == 1`, `resendLeft(t, t + 50 s) == 0`.
  - `accountDigits("0123 4567 89") == "0123456789"`, `accountValid` for 6 and 16 digits, not 5 or 17; `streetValid("12")` false, `streetValid(" 12 A ")` true; `bioValid` at 9 and 151 trimmed false, 10 and 150 true.
  - `payoutLabel(PayoutForm("Vietcombank", "0123453456")) == "Vietcombank •• 3456"`.
  - `profileProgress` of the seeded six (PAYOUT, ADDRESS, PHONE, AVATAR done) is `Progress(4, 6, IDENTITY)`; with identity done `next == BIO`; all done `next == null`; identity pending still counts open.
  - `nextTier(386) == NextTier(REPUTABLE, 114)`, `nextTier(199) == NextTier(TRUSTED, 1)`, `nextTier(800) == null`; `trackFill(386) == 0.386f`.
  - `tierPerks(TRUSTED) == listOf(COD_5, LISTINGS_20)`, `tierPerks(TOP)` has three.
  - `dueOrder` picks d-huy's TO_SHIP over d-bao jumped to ARRANGING when the stool's deadline is nearer, gives "Gửi Ghế đôn gỗ cao cho Đức Huy" and "Trước 18:00 thứ Sáu · còn 26 giờ", and is null when no selling order waits.
  - `figures90`: d-bao at RECORD_DECLINED counts one declined; RECORD_OPEN one unanswered.
  - `requiresAccount(ChatRoute("x"))`, `!requiresAccount(HomeRoute)`, `!requiresAccount(ListingRoute("p"))`, `!requiresAccount(LoginRoute)`.
- [ ] **Steps 2–5**; commit `feat: add the account rules`.

### Task 4: Stage 5 fixtures

**Files:** Create `core/data/tools/stage5_fixtures.py` (writes `kyc.json`; edits `account.json` with `bio`, `kyc`, `history`; adds Khánh Linh to `sellers.json` with her two live listings and reviews; points the two account notifications at `ProfileTasks` and `Reputation` and rewrites "còn 4 việc" to "còn 2 việc"); commit `.superdesign/stage5-digest.md`. Modify `Seeds.kt`, `Fixtures.kt`. Then `cd core/testing && python3 tools/fetch_photos.py`. Test: `FixturesTest`.

- [ ] **Step 1: Failing tests.** `FixturesTest.stageFiveFixturesLoad`: `Fixtures.kyc().chip.name == "Nguyễn Khánh Linh"`, six banks, four wards, the bio draft is 70 characters; `Fixtures.account().history` has six rows summing to +27; `Fixtures.sellers()` has `u-linh` with district "Bình Thạnh"; the notification `tasks` targets `ProfileTasks` and reads "Hoàn thiện hồ sơ: còn 2 việc".
- [ ] **Steps 2–5**; commit `feat: add the stage 5 fixtures`.

### Task 5: The fakes

**Files:** Modify `Repositories.kt` (SessionRepository, ProfileRepository, ReputationRepository, KycRepository), `FakeWorld.kt` (`session`, `bio`, `kyc`, saved guest hearts), `DataModule.kt`, `Simulator.kt` (`onKycSubmitted`: 10 s, VERIFIED, IDENTITY, the notification), `DebugControls.kt` (`signOut()`, the identity switch sets `kyc`); create `FakeSessionRepository.kt`, `FakeProfileRepository.kt`, `FakeReputationRepository.kt`, `FakeKycRepository.kt`. Tests: one `Fake…Test` each, `SimulatorTest.aManualReviewIsApproved`.

**Interfaces (Produces):**

```kotlin
interface SessionRepository {
    fun session(): Flow<Session>
    suspend fun sendCode(digits: String): Result<Unit>
    suspend fun verifyCode(digits: String, code: String): Result<Unit>   // fails with WrongCode for "000000"
    suspend fun locate(): Result<String>                                  // "Bình Thạnh"
    suspend fun finishSignIn(district: String): Result<Unit>              // SIGNED_IN, district and area set
    suspend fun browseAsGuest(): Result<Unit>
    suspend fun signOut(): Result<Unit>
}
interface ProfileRepository {
    fun me(): Flow<MeSummary>
    fun tasks(): Flow<ProfileTasks>
    suspend fun savePayout(form: PayoutForm): Result<Unit>
    suspend fun saveAddress(form: AddressForm): Result<Unit>
    suspend fun saveBio(text: String): Result<Unit>
    suspend fun draftBio(): Result<String>
}
interface ReputationRepository { fun reputation(): Flow<Reputation> }
interface KycRepository {
    fun state(): Flow<KycState>
    suspend fun checkCard(side: CardSide, photo: String): Result<CardCheck>
    fun readChip(): Flow<ChipRead>
    suspend fun checkFace(photo: String?): Result<Unit>
    suspend fun submit(manual: Boolean): Result<KycState>
}
```

- [ ] **Step 1: Failing tests.**
  - `FakeSessionRepositoryTest`: starts SIGNED_IN; `signOut` → SIGNED_OUT; `verifyCode(…, "000000")` fails, `"123456"` passes; `finishSignIn("Phú Nhuận")` → SIGNED_IN with account district "Phú Nhuận" and area "Phú Nhuận, TP.HCM"; a guest's saved heart stays saved after `finishSignIn`.
  - `FakeProfileRepositoryTest`: `me()` reads "Khánh Linh", score 386, `tasksDone == 4`, `next == IDENTITY`, due "Gửi Ghế đôn gỗ cao cho Đức Huy", tiles 12/2/2, three rows (draft, guitar with its cut, shelf sold); `saveAddress` changes `account.address.line` and `tasks()`; `savePayout` writes "Techcombank •• 7890" to `payoutTo`.
  - `FakeReputationRepositoryTest`: 386 and TRUSTED at start; a RATED_5 event adds 5 and a history row "… đánh giá bạn 5 sao" on top; IDENTITY gives 486; rights `COD 0/5` and `LISTINGS 2/20` (app data).
  - `FakeKycRepositoryTest`: `readChip()` emits rising percents to 100 then the fields; `submit(false)` → VERIFIED, account verified, IDENTITY earned; `submit(true)` → PENDING.
  - `SimulatorTest.aManualReviewIsApproved`: after `submit(true)`, 10 s of virtual time → VERIFIED, IDENTITY, the notification "Đã xác minh danh tính" targeting `ProfileTasks`.
- [ ] **Steps 2–5**; commit `feat: fake the session, the profile, the reputation and eKYC`.

### Task 6: Design-system pieces

**Files:** Modify `TierChip.kt` (trailing text); create `ProgressRing.kt` (count ring: size, stroke, done/total, animated), `OtpBoxes.kt` (one field over six 48 × 56 dp boxes, error ring), `ScoreTrack.kt` (fill and four markers). New symbols. Tests: `ChromeComponentsTest` additions and screenshots.

- [ ] **Step 1: Failing tests.** `TierChip(TRUSTED, trailing = "· 386")` shows "Tin cậy" and "· 386"; `ProgressRing(4, 6)` has the description "4 trên 6 bước"; `OtpBoxes` takes "12a3456" as "123456" and reports completion once; markers are toggle buttons "Quyền lợi bậc Uy tín". Screenshots of each.
- [ ] **Steps 2–5**; commit `feat(designsystem): add the ring, the code boxes, the score track and the chip's score`.

### Task 7: The session in the app

**Files:** Modify `AppViewModel.kt` (session flow), `MainActivity.kt`, `AppNavigation.kt` (Chào mừng as the root when SIGNED_OUT; the guest rule in `AppNavigator.push` and `selectTab`: an account route opens `LoginRoute` on top and remembers the target; signing in closes Đăng nhập and opens the target), `AuthInstaller.kt`. Tests: `SessionNavigatorTest`.

- [ ] **Step 1: Failing tests.** SIGNED_OUT shows Chào mừng and no navigation bar; GUEST selecting Tin nhắn pushes `LoginRoute`; after SIGNED_IN the stack is Home → Tin nhắn tab; SIGNED_IN → SIGNED_OUT clears every tab's stack.
- [ ] **Steps 2–5**; commit `feat: show Chào mừng when signed out and send a guest to Đăng nhập`.

### Task 8: Chào mừng

**Files:** Create `feature/auth/.../welcome/WelcomeScreen.kt`. Tests: `WelcomeScreenTest`, screenshots (four variants).

- [ ] **Step 1: Failing tests.** "Giá tốt, gần bạn, chốt nhanh!", the three promises, "Bắt đầu với số điện thoại" → `LoginRoute`, "Xem trước, đăng nhập sau" → `browseAsGuest`; the collage has no TalkBack node; no clipping at 1.3.
- [ ] **Steps 2–5**; commit `feat: build Chào mừng`.

### Task 9: Đăng nhập

**Files:** Create `feature/auth/.../login/LoginViewModel.kt`, `LoginScreen.kt`. Tests: `LoginViewModelTest`, `LoginScreenTest`, screenshots.

**State:** `LoginUiState(step: PHONE|CODE|AREA, digits, code, verifying, wrong, resendLeft, district, locating)`; events `Digits`, `SendCode`, `Code`, `Confirm`, `Resend`, `ChangeNumber`, `Locate`, `District`, `Done`, `Back`.

- [ ] **Step 1: Failing tests.**
  - VM: "0912 345 812" enables "Gửi mã"; the code step counts 45 → 0 on virtual time and "Gửi lại mã" restarts it (twice); the sixth digit verifies; "000000" sets `wrong` and keeps the step; a right code moves to AREA; `Locate` picks "Bình Thạnh"; `Done` calls `finishSignIn` with the district; `theStepSurvivesRecreation` (CODE with the number and `sentAt`).
  - Screen: the pill reads "Bước 2 trên 3: Mã xác nhận"; "Gửi tới 0912 345 812"; the error "Mã chưa đúng. Kiểm tra tin nhắn rồi nhập lại."; "Gửi lại sau 0:45"; six district chips single-choice; Back on CODE returns to PHONE with the number kept.
  - Screenshots: each step, the error, verifying, the countdown; four variants of the phone step.
- [ ] **Steps 2–5**; commit `feat: build Đăng nhập`.

### Task 10: Tôi

**Files:** Create `feature/me/.../me/MeViewModel.kt`, `MeScreen.kt`, `ThemeSheet.kt`, `SignOutDialog.kt`; remove the Tôi placeholder links. Tests: `MeViewModelTest`, `MeScreenTest`, screenshots.

- [ ] **Step 1: Failing tests.**
  - Screen: "Khánh Linh", "4,8 · 21 đánh giá · Bình Thạnh", the chip "Tin cậy" and "· 386" → `ReputationRoute`, "Trang của bạn" → `SellerRoute("u-linh")`, share sends the page link, "4/6" and "Xác minh danh tính" → `ProfileTasksRoute()`, the due row → `OrderRoute("d-huy")`, tiles → Saved, Orders BUY, Orders SELL, the guitar's "Cao hơn 12%" in `tertiary` and "Giảm còn 1,7 tr" (event), "Tiếp tục" → `SellRoute(draftId = "dr-iphone11")`, the sold shelf "Đã bán · Thứ Hai", "Giao diện tối" opens the sheet, "Màu theo hình nền" toggles, the rows (Thông báo, Gói người bán "Cơ bản · miễn phí", Khu vực, Bảo mật và xác minh "Chưa xác minh danh tính" → `KycRoute("ME")`, Trợ giúp và an toàn), "Đăng xuất" asks first; verified shows "Đã xác minh" and "CCCD gắn chip"; pending "Đang chờ duyệt"; no due row when nothing waits.
  - VM: the cut sends `setPrice` with undo; turning Material You on says "Đã lấy màu từ hình nền" with undo; signing out calls `signOut` after the dialog.
  - Screenshots: default (four variants), verified, the theme sheet, the sign-out dialog.
- [ ] **Steps 2–5**; commit `feat: build Tôi`.

### Task 11: Hoàn thiện hồ sơ

**Files:** Create `feature/me/.../tasks/TasksViewModel.kt`, `TasksScreen.kt`, `TaskSheets.kt`. Tests: `TasksViewModelTest`, `TasksScreenTest`, screenshots.

- [ ] **Step 1: Failing tests.**
  - Screen: "4" and "/6" ("4 trên 6 bước"), "Còn 2 bước", "Cần làm" with identity ("Cần để đăng tin · +100 điểm uy tín" in `primary`) and bio, "Đã xong · 4" with payout "Vietcombank •• 4821", address "Phường 25, Bình Thạnh", phone "09•• ••• 812", photo "Đã thêm"; identity → `KycRoute("TASKS")`; pending shows "Đang chờ duyệt · 1–2 ngày"; complete shows "Hồ sơ đầy đủ" and "Người bán tin cậy".
  - Sheets: payout keeps digits only and errors "Số tài khoản cần 6–16 chữ số" on a 5-digit save; address errors "Nhập số nhà và tên đường"; bio counts "70/150" after "Viết giúp" and errors "Viết ít nhất 10 ký tự"; typing clears an error; a save closes the sheet with "Đã lưu".
  - VM: `ProfileTasksRoute(sheet = "ADDRESS")` opens the address sheet; the open sheet and its fields survive recreation.
  - Screenshots: 4/6 (four variants), pending, complete, each sheet and its error.
- [ ] **Steps 2–5**; commit `feat: build Hoàn thiện hồ sơ`.

### Task 12: Điểm uy tín

**Files:** Create `feature/me/.../rep/ReputationViewModel.kt`, `ReputationScreen.kt`, `RulesSheet.kt`, `HistorySheet.kt`. Tests: `ReputationViewModelTest`, `ReputationScreenTest`, screenshots.

- [ ] **Step 1: Failing tests.**
  - Screen: "Tin cậy", "386" and "/1000" (set at once with animations off), "Còn 114 điểm lên Uy tín", the marker "Quyền lợi bậc Tin cậy" pressed with "COD tối đa 5 đơn đang mở" and "Đăng tối đa 20 tin"; tapping "Uy tín" shows its perks with "từ 500" and the lock; identity row → `KycRoute("REP")`, verified "Đã xong · +100"; "Quyền của bạn" "0/5" and "2/20"; "Từ chối nhận COD" "0 trên 3 đơn"; the ladder sentence; six history rows, gains in `primary`, losses in `error` with U+2212; "Xem toàn bộ lịch sử" opens the sheet; "Cách tính điểm" opens the rules with "Cộng", "Trừ", "Bậc" and the notes.
  - VM: a new event in the world updates the score and puts its row on top; the chosen tier survives recreation.
  - Screenshots: default (four variants), each tier's perks, the rules and history sheets, verified.
- [ ] **Steps 2–5**; commit `feat: build Điểm uy tín`.

### Task 13: eKYC camera parts (`:core:ui`)

**Files:** Create `core/ui/.../camera/StillCamera.kt` (back camera preview plus `ImageCapture` into the cache, torch, `onCaptured(file)`), `FaceCamera.kt` (front preview clipped by the caller); simulated variants draw nothing (the screens draw the mockup's card and photo). Tests: `StillCameraTest` (the permission view without permission; the simulated mode reports a capture on request).

- [ ] **Steps 1–5**; commit `feat(ui): add the still camera and the front camera feed`.

### Task 14: eKYC flow and the first three steps

**Files:** Create `feature/kyc/.../KycViewModel.kt` (steps INTRO → CARD_FRONT → CARD_BACK → CHIP → FACE → REVIEW → SENDING → DONE | PENDING; auto-capture timers 1,1 s hold and 2,1 s capture; chip read collection; the no-NFC sheet; manual path; origin), `KycScreen.kt` with `IntroStep`, `CardStep`, `ChipStep`. Tests: `KycViewModelTest`, `KycScreenTest` (part one), screenshots.

- [ ] **Step 1: Failing tests.**
  - VM: `start = "CARD"` opens CARD_FRONT; the hold comes at 1,1 s and the capture at 2,1 s on virtual time; "Dùng ảnh" on the front moves to the back, on the back to CHIP; "Chụp lại" restarts the timers; CHIP reads to 100 then shows the rows; no NFC opens the sheet at once; "Tiếp tục không NFC" sets the manual path and opens FACE; the step and the captured files survive recreation; back on CARD_BACK returns to CARD_FRONT, elsewhere asks to exit.
  - Screen: intro strings; "Mặt trước CCCD", "Đặt thẻ vừa khung", the tips, "Giữ yên", the checks staggered, "Chụp lại", "Dùng ảnh"; "Áp CCCD vào lưng máy", the percent, "Đã đọc chip", the three rows, "Máy không có NFC?" and the sheet.
  - Screenshots: intro, card scan / hold / review (front and back), chip wait / read / done, the sheet.
- [ ] **Steps 2–5**; commit `feat: build eKYC's first steps`.

### Task 15: The last eKYC steps

**Files:** Modify `KycViewModel.kt`, `KycScreen.kt` with `FaceStep`, `ReviewStep`, `ResultStep`, `ExitDialog`. Tests: `KycViewModelTest`, `KycScreenTest` (part two), screenshots.

- [ ] **Step 1: Failing tests.**
  - VM: the three prompts at 0,7 s and every 1,5 s, done at about 5,2 s; consent enables "Gửi xác minh"; submit shows SENDING for 2 s then DONE (chip path) or PENDING (manual); a failed submit returns to REVIEW with consent kept and a message; "Đăng tin ngay" from SELL backs to the form below, from TASKS replaces with `SellRoute()`; "Về hồ sơ" opens `ProfileTasksRoute()`; "Thoát" backs to the origin.
  - Screen: "Nhìn thẳng", "Quay sang trái", "Chớp mắt", "Xong", the tips; "Kiểm tra thông tin", "Đọc từ chip, không sửa được", "Khớp", the five fields, the consent; "Đang xác minh…"; "Đã xác minh", "CCCD gắn chip", "Khuôn mặt", "Đăng tin ngay", "Về hồ sơ"; "Đang chờ duyệt", "1–2 ngày · ShopNexus báo bạn"; the exit dialog with its body only for SELL and REVIEW; the manual review shows the card photos.
  - Screenshots: face prompts and done, review (four variants), sending, done, pending, the exit dialog.
- [ ] **Steps 2–5**; commit `feat: build eKYC's face, review and results`.

### Task 16: Entry points and the last placeholders

**Files:** Modify `SellScreen.kt` and `ReviewScreen.kt` (banner → `KycRoute("SELL"|"REVIEW")`, gate → `start = "CARD"`), `CodCheckoutScreen.kt` (address → `ProfileTasksRoute("ADDRESS")`, rights → `ReputationRoute`, payment → `PlaceholderRoute(0, …)`), `MyListingsScreen.kt` (payment → stage 0), `NotificationsScreen.kt` (settings → stage 0), `NotificationsViewModel.kt` (`ProfileTasks`, `Reputation`), `PlaceholderScreenTest` (`noStageFivePlaceholderIsLeft`). Tests: those screens' tests, `NotificationsViewModelTest.eachTargetOpensItsScreen`.

- [ ] **Steps 1–5**; commit `feat: open the account screens from every entry point`.

### Task 17: End-to-end walks and the device review

**Files:** Create `app/src/test/.../AccountWalkTest.kt` with `signOutAndInWalk`, `guestDetourWalk`, `verifyFromTheGateWalk`, `manualReviewWalk` (the spec's four walks, `simulator.speed = 10.0`). Then build the APK, install on the API 36 emulator and walk every screen with `app2/tmp/ui.py`, comparing with the mockups.

- [ ] **Step 1: Write the walks; run, expect FAIL** where a piece is missing; fix by the owning task's rules.
- [ ] **Step 2: Run, expect PASS**, then the gate.
- [ ] **Step 3: Emulator walk.** Each screen and sheet; the two camera steps on the emulator's cameras; screenshots to `app2/tmp/work/walk/s5-*`. Differences that are not rulings become fixes with tests.
- [ ] **Step 4: Commit** `test: walk the account from sign-in to a verified seller`.
