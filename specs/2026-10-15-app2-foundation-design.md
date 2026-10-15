# Design: app2 foundation and first vertical slice

Date: 2026-10-15
Status: draft, waiting for review

## Goal

`app2` is the native Android rebuild of the ShopNexus app. The 31 screens are
designed as HTML mockups in `app2/.superdesign/` (rules in
`app2/.superdesign/design-system.md`), and the deal model they follow is
`app2/mohinh.md`. This spec covers the first of five build stages: the project
foundation and one vertical slice, Home → Listing detail → Chat, running on
fake data with real interactions.

The app runs on mock data first. The domain types and repository interfaces
are the API contract: the Go server will be changed to serve them, so they are
shaped for the app's screens and for small payloads, and nothing in them
follows today's server API.

## Stages

| Stage | Screens | Spec |
|---|---|---|
| 1. Foundation + slice | Home, Listing detail, Chat (in-person deal) | this one |
| 2. Khám phá | Search before typing, Search results, Danh mục, Category, Người bán, Đã lưu, Thông báo | later |
| 3. Giao dịch | Tin nhắn, Đơn hàng, Chi tiết đơn, Giao COD, Đơn COD, Đơn bán | later |
| 4. Bán | Đăng tin, Quay video, Kiểm tra tin, Tin của bạn, Gói người bán | later |
| 5. Tài khoản và tin cậy | Tôi, Hoàn thiện hồ sơ, Điểm uy tín, eKYC (5 steps), Chào mừng, Đăng nhập | later |

Each stage gets its own spec, plan and implementation. Stage 1 builds the
modules, the design system, the domain rules and the fake data that the later
stages reuse.

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Platforms | Android only, native Kotlin | iOS is dropped, so Android libraries are allowed without a multiplatform constraint |
| minSdk / targetSdk | 31 / 36 | Material You is available on every supported device |
| Repository | new repo `shopnexus/app2`, a submodule at `app2/` | the umbrella keeps one submodule per component; `.superdesign/` and `mohinh.md` move into it |
| Architecture | multi-module, after Now in Android | enforced boundaries, incremental builds, the API contract in its own module |
| UI | Jetpack Compose, Material 3 Expressive | the design system is M3 Expressive |
| Material 3 | `androidx.compose.material3:material3:1.5.0-beta01`, pinned | MaterialShapes, LoadingIndicator, FloatingActionButtonMenu and ButtonGroup exist only in the 1.5.0 line; stable 1.4.0 lacks them |
| Navigation | Navigation 3 (`androidx.navigation3`) | the Compose-first navigation library, stable since 1.1 |
| DI | Hilt with KSP | compile-time graph checks |
| State | ViewModel + `StateFlow`, one immutable UI state per screen | standard Android lifecycle handling |
| Async | kotlinx.coroutines and Flow | |
| Serialization | kotlinx.serialization | routes and fixtures |
| Images | Coil 3 with a disk cache | |
| Settings | DataStore (theme mode, Material You toggle) | |
| Tests | JUnit, Turbine, Robolectric, Roborazzi | everything runs on the JVM, without an emulator |

Versions current on 2026-10-15: AGP 9.4.1 (Kotlin built in, so no
`kotlin-android` plugin), Kotlin 2.4.21, Gradle 9.x, JDK 17 or later,
Navigation 3 1.2.0, material3 1.5.0-beta01. The implementation plan
re-checks each version and pins it in `gradle/libs.versions.toml`.

## Environment

The machine has no JDK, Android SDK or Gradle. Setup, in order:

1. JDK 21 (Temurin), with `JAVA_HOME` set.
2. Android command-line tools in `~/Android/Sdk`, with `ANDROID_HOME` set;
   `sdkmanager "platform-tools" "platforms;android-36" "build-tools;36.0.0"
   "emulator" "system-images;android-36;google_apis;x86_64"`; one AVD on API 36.
3. The Gradle wrapper, committed with the project; no system Gradle.

Unit and screenshot tests need only steps 1 and 3 and the SDK platform. The
emulator is for walking the slice by hand.

## Modules

| Module | Holds | May depend on |
|---|---|---|
| `:app` | `MainActivity`, `NavDisplay`, the four-tab navigation bar, the Hilt application | every module |
| `:feature:discover` | Home and Listing detail: screens, ViewModels, entry installers | `:core:*` |
| `:feature:deal` | Chat: screen, ViewModel, sheets, entry installer | `:core:*` |
| `:feature:placeholder` | the screen that stands in for work of later stages | `:core:*` |
| `:core:designsystem` | theme, tokens, fonts, shared components, money sentences | `:core:model` |
| `:core:navigation` | `@Serializable` route keys and the entry installer interface | `:core:model` |
| `:core:model` | plain Kotlin domain types: the API contract | nothing |
| `:core:domain` | deal-model rules and the deal console state machine, plain Kotlin | `:core:model` |
| `:core:data` | repository interfaces, fakes, fixtures, the simulator | `:core:model`, `:core:domain` |
| `:core:testing` | test dispatchers, a fake clock, fixture builders | `:core:model`, `:core:data` |

A feature never depends on another feature; one feature opens another's
screen by pushing a route from `:core:navigation`. `:core:model` and
`:core:domain` have no Android dependency and build as JVM modules.

`build-logic` holds the convention plugins `shopnexus.android.application`,
`shopnexus.android.library.compose`, `shopnexus.android.feature`,
`shopnexus.jvm.library` and `shopnexus.hilt`. Feature modules only apply
`shopnexus.android.feature`, which brings Compose, Hilt, the ViewModel and
Navigation 3 dependencies and `:core:*`.

## Design system (`:core:designsystem`)

The values come from `.superdesign/tools/common.py` and
`design-system.md`. Those two files stay the source of truth; the Kotlin
tokens are copied from them once and checked by screenshot tests.

### Color

- `ShopNexusTheme(themeMode, dynamicColor)` builds the brand light and dark
  schemes from `LIGHT` and `DARK` (seed #066A61, terracotta tertiary #924628,
  spec 2025 Fidelity). With Material You on, it uses
  `dynamicLightColorScheme` / `dynamicDarkColorScheme`.
- The fixed tertiary roles (`tertiaryFixed` #FFDBCF and
  `onTertiaryFixedVariant` #773215 in both modes) come from `ColorScheme`
  where material3 1.5 has them, else from an `ExtendedColors` holder in a
  CompositionLocal, which also carries their dynamic-color values.
- `tertiary` is the bargaining role and marks nothing else: price
  judgments, the "Trả giá" and "Gửi" offer buttons, a sent offer, a picked
  amount, and the agreed price (its milestone, the handshake circle in the
  deal console, "Đã chốt" on Listing detail). "Đồng ý" and the seller's
  acceptance pill are actions and stay teal. The rule names the role, so it
  holds under Material You, where the wallpaper picks the colour.
- Icons in the deal flow keep one meaning: the tag is bargaining (the
  Thương lượng phase, offer pills), the handshake the agreed price, and
  `group` meeting in person (the Gặp mặt path, the over-the-limit sentence).
- A `checkNoRawColors` task from `build-logic` scans
  the `src/main` sources of every module except this one and fails `check` on
  any `Color(0x…)` or `Color.Red`-style constant.

### Typography and shapes

- Be Vietnam Pro, bundled as font resources (400, 500, 600). Downloadable
  fonts are not used, because they need Google Play services and a network at
  first launch.
- Twelve styles, exactly the mockup scale: displaySmall 36/44 400,
  headlineMedium 28/36 400, headlineSmall 24/32 400, titleLarge 22/28 400,
  titleMedium 16/24 500, titleSmall 14/20 500, bodyLarge 16/24 400,
  bodyMedium 14/20 400, bodySmall 12/16 400, labelLarge 14/20 500,
  labelMedium 12/16 500, labelSmall 11/16 500.
- Corner radii 4, 8, 12, 16, 20, 28, 32 dp. MaterialShapes from material3
  1.5 (Cookie9Sided, SoftBurst, Flower, Gem, Clover4Leaf, Arch, Sunny).
- `MotionScheme.expressive()`.

### Components built in stage 1

Only what the slice uses; later stages add the rest.

| Component | Used for |
|---|---|
| `ListingCard`, `ListingRail`, `ListingGrid` | Home rails and grid, similar listings; square photo, price with save, optional price insight in `tertiary`, two-line title, meta |
| `SectionHeader` | title with the 36 dp arrow button |
| `GroupedList`, `GroupRow` | Pixel Settings groups: 28 dp outer corners, 4 dp inner, 2 dp gaps |
| `Figure`, `AmountStepper` | light large price with its smaller unit; − / amount / + in 100.000 ₫ steps |
| `PhaseStepper` | the four-phase deal stepper, in-person and COD variants, with accessible labels ("Bước 2 trên 4: Hẹn gặp") |
| `MoneyNote(key: MoneyKey)` | the plain sentence at each money step; the words live in string resources, one per key |
| `Milestone(tone)` | the deal moment: shape, icon, title, one feeling line; deal (`tertiaryFixed`), trust (`primaryContainer`), calm (`secondaryContainer`) |
| `TierChip`, `ConditionScale`, `DeclaredMarkRow`, `SparkleLabel` | Listing detail and Chat |
| `ShopNexusTopBar`, `DockedActionBar`, `ShopNexusNavigationBar` (labels on), `FabMenu` | screen chrome |
| `FullWidthSheet`, `ShopNexusDialog`, `LoadingIndicator` | sheets span the screen width; dialogs follow the M3 alert layout |

Every component has a preview and a Roborazzi screenshot in four variants:
light, dark, Material You from a fixed sample seed, and font scale 1.3.

## Domain model and API contract (`:core:model`)

Reads are shaped per screen, so one screen is one call: `HomeFeed` (hero
slides, categories, nearby, for-you with interest chips) and
`ListingDetail` (listing, seller summary, similar listings). Writes are
commands on a deal (`SendOffer`, `AcceptCounter`, `WithdrawOffer`,
`ProposeMeeting`, `ConfirmMeeting`, `SetCheck`, `RecordHandover(code)`,
`Rate`, `OpenRecord`, `ConfirmRefund`), each returning the updated `Deal`.
An open deal is observed as `Flow<Deal>`; the fake emits through Flow, and a
real backend can serve the same stream over SSE or a WebSocket.

Types, all `@Serializable`:

- Ids as value classes (`ListingId`, `UserId`, `DealId`, `RecordId`) and
  money as `Vnd(amount: Long)`.
- `Listing`: title, price, category path, `Condition` (NEW, LIKE_NEW, USED),
  `declaredMarks: List<DeclaredMark>` (text, close-up photo), photos with
  `source` (APP, LIBRARY) and `capturedAt`, specs, description, district,
  `paths: Set<HandoverPath>` (MEET, COD), `allowOffers`, `postedAt`.
- `ListingSummary`: only the card's fields, for feeds and rails.
- `PriceInsight`: direction, percent, range low/high, sample size and
  window; separate from `Listing`, since a different service may compute it.
- `Deal`: listing, buyer, seller, `path`, `phase`, offers (`Offer`: who,
  amount, time, status), `Meeting` (time, `MeetPoint` with name and why it is
  safe), checklist items, `CodShipment` (fee, deadline, carrier events; empty
  in stage 1), incident records, rating.
- `ThreadItem` for the chat: Text, Photos, PriceMove, Event, Milestone,
  Record.
- `IncidentRecord`: photo, text, AI note, status (OPEN, REFUNDED with an
  amount, DECLINED, WITHDRAWN), public flag.
- `MoneyKey`: one entry per money sentence (`MEET`, `OVER_LIMIT`, `NO_HOLD`,
  `AFTER_PAY`, `DECLARED`, and the COD keys used from stage 3). It sits here so
  both `:core:domain` (which step shows which key) and `:core:designsystem`
  (the words) can use it.
- `PublicProfile`: what other people may see (tier, public stats, public
  records). `MyReputation` (score, rights in use, 90-day stats, history) is
  defined now and used in stage 5.

## Deal rules (`:core:domain`)

One pure function per file, each with unit tests. The numbers are the ones
agreed in `mohinh.md` and the follow-up decisions of 2026-10-15.

| Function | Rule |
|---|---|
| `codAllowed(price)` | COD up to 5.000.000 ₫; above, in person only |
| `handoverDeadline(placedAt)` | the seller hands a COD parcel over within 48 hours, or the buyer's shipping is refunded |
| `refusalCost(deal)` | refusing at the door costs the buyer the outbound shipping; the seller pays the return leg |
| `offerRange(listed, counter)` | from half the listed price, rounded up to 100.000 ₫, to below the counter, in 100.000 ₫ steps |
| `tierFor(score)` | Mới from 0, Tin cậy from 200, Uy tín from 500, Xuất sắc from 800 |
| `pointsFor(event)` | +10 deal, +5 / +2 for a 5 / 4 star rating, +15 self-refund, +20 a month of one-hour replies, +100 identity; −15 for a 1–2 star rating, −20 cancel after agreeing, −30 cancel a meeting under 2 hours before it; points older than 12 months count half |
| `rightsFor(tier, stats)` | COD open orders 2 / 5 / 10 / 20 by tier; over 90 days, from five orders, a buyer refusal rate of 20 % limits COD to one open order and 35 % removes COD for 30 days; 30 clean days lift a step |
| `canPost(draft)` | no AI-seen mark left undecided |
| `moneyNotes(step)` | which `MoneyKey`s a deal step shows |
| `DealConsole.reduce(state, event)` | the Chat console: Countered, Offering, Waiting, Agreed, Proposing, Meeting, Received, Done |

ViewModels call these functions and never re-implement a rule. The backend
can test its own implementation against the same tables.

## Fake data (`:core:data`)

- Fixtures are JSON files in `core/data/src/main/resources/fixtures/`, read
  with kotlinx.serialization, so JVM tests load them too. They hold the
  mockups' data: Khánh Linh as the signed-in buyer, Tuấn Kiệt and the iPhone
  13 Pro 128GB at 10.900.000 ₫ with a counter of 10.600.000 ₫, the Home rails
  and grid listings, the price range 11,8 – 13,2 triệu.
- `FakeWorld` holds all state in one `MutableStateFlow`. Every fake
  repository reads and writes through it, so a save on Home shows on Listing
  detail and an agreed price shows in every view of that deal.
- `Simulator` plays the other side: Tuấn Kiệt accepts a counter-offer 2.4 s
  after it is sent, proposes "19:00 hôm nay · Sảnh Landmark 81", agrees to a
  new meeting after 1.6 s, and refunds 300.000 ₫ 2.2 s after a record. It runs
  on an injected `Clock` and `CoroutineScope`, so tests use virtual time.
- Photos use the mockups' Unsplash URLs through Coil. Without a network, a
  `surfaceContainerHigh` placeholder takes their place.
- A debug-only panel in `:app`'s `debug` source set (opened by a long press
  on the app bar title) jumps the deal to any console state, resets `FakeWorld`, speeds the simulator up, and
  turns on failure injection.
- `QrScanner` is an interface. Stage 1 binds a fake that reads after 1.6 s;
  CameraX and ML Kit arrive in stage 3, with the seller's code screen.

## Navigation

- `:core:navigation` declares the routes as `@Serializable` keys:
  `HomeRoute`, `CategoriesRoute`, `InboxRoute`, `MeRoute`,
  `ListingRoute(id)`, `ChatRoute(dealId)`, `PlaceholderRoute(stage, title)`.
- Each feature module contributes its entries through a Hilt multibinding of
  `EntryProviderInstaller`; `:app` collects them into the `NavDisplay`
  entry provider.
- The four tabs keep separate back stacks, so returning to a tab restores
  where the person was. Pushed screens (Listing detail, Chat) hide the
  navigation bar, and every route supports predictive back.
- Deep links: `shopnexus://listing/{id}` and `shopnexus://deal/{id}`.
- Sheets and dialogs are screen-local state (full-width `ModalBottomSheet`,
  M3 dialogs), not back stack entries.
- In stage 1, the Danh mục, Tin nhắn and Tôi tabs show `PlaceholderRoute`
  content, and Search, the category row, the bell, the seller row and the FAB
  menu items push it; the placeholder names the stage that builds the screen.

## The slice

### Home

Search bar, location pill, bell, the hero carousel (four slides; progress
dots and a pause button; no autoplay under reduced motion), the category row,
"Gần bạn" rail, "Gợi ý cho bạn" with interest chips over a two-column grid,
pull to refresh (two new listings enter "Gần bạn" and a snackbar says "2 tin
mới quanh bạn"), the save toggle, and the FAB menu (Tiếp tục nháp, Chụp ảnh,
Quay video). The long-press card menu is stage 2.

### Listing detail

The photo row and full-screen viewer; price with save; sparkle + "Rẻ hơn 13%"
opening the price sheet; title and three icon facts; the seller row with the
Xuất sắc tier chip; question chips; "Tình trạng" with the scale at Như mới,
the declared mark (2 vết xước nhỏ ở viền) opening its close-up, and the
declared-marks sentence; "Thông tin máy" with the clamped description;
"Giao dịch" with Gặp mặt open, COD dimmed (the price is above 5 triệu) and
three money sentences; "Tin tương tự". The docked bar holds "Nhắn tin" and
"Trả giá" in `tertiary`; the offer sheet uses `AmountStepper`. The overflow
menu has "Ẩn tin tương tự" and "Báo cáo tin" (four reasons).

### Chat

The thread (bubbles, price moves, events, milestones, the record card), the
deal console in all eight states, the "Hẹn gặp" sheet (time chips, three
suggested meeting points), the "Danh sách kiểm" sheet (six checks for an
iPhone and the declared mark), the "Chưa kiểm xong" dialog, the scanner, the
rating, and the incident record. The record's photo comes from the Android
Photo Picker, and typing in the composer folds the console to one row.

## State and errors

- Each screen has one ViewModel exposing `StateFlow<XxxUiState>` and taking
  `onEvent(XxxEvent)`. One-off effects (snackbar, navigation) go through a
  `Channel` collected in the composable.
- Repositories return `Result`. A failed read shows the screen's error state
  with "Thử lại". A failed command shows "Chưa gửi được. Thử lại" in a
  snackbar and rolls the state back, including an optimistic price move in the
  thread.
- A step that involves money never shows as done before its command succeeds.

## Accessibility

Touch targets of at least 48 dp; a content description on every icon-only
control; phase labels on the stepper; reduced motion turns off milestone
animations and hero autoplay; every screen and component is checked at font
scale 1.3.

## Testing and acceptance

- JVM unit tests for `:core:domain` and `:core:data`, the simulator on virtual
  time.
- ViewModel tests with Turbine.
- Roborazzi screenshots for components and for each screen state.
- Robolectric Compose UI tests for the slice: Home → Listing detail → offer →
  agree → meeting → checks → scan → rating → record.
- `./gradlew check` runs everything; GitHub Actions in the `app2` repo runs it
  on every pull request.

Stage 1 is done when:

1. The slice walks end to end on an API 36 emulator with no dead control.
2. Every screen state has a screenshot, reviewed side by side with the mockup.
3. Every rule in the deal rules table has unit tests.
4. The deal console state machine has ViewModel tests on virtual time.
5. Every slice screen lays out at font scale 1.3 without clipping.

## Out of scope

A real backend client, real AI, eKYC, MoMo payments, CameraX and ML Kit,
sign-in, push notifications, languages other than Vietnamese, and baseline
profiles. Stages 2–5 each get their own spec.
