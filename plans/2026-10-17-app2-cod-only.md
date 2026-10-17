# app2 COD-only hand-over Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the in-person hand-over from the Android app, make COD the only in-app way with a meeting suggestion above 5 triệu, and bring over the other mockup changes of 2026-10-16.

**Architecture:** Additive first, then subtractive. Tasks 1 to 10 move every screen and fake onto the COD-only behaviour while the old in-person types still compile; Task 11 deletes the in-person contract, code, strings, tests and goldens in one pass; Task 12 rewrites the app walks and checks the result on the emulator and the Pixel. Every task leaves `./gradlew check verifyRoborazziDebug` green.

**Tech Stack:** unchanged from stage 5 (Kotlin 2.4.21, AGP 9.4.1, Compose with material3 1.5.0-beta01, Navigation 3, Hilt, Coil 3, CameraX, Robolectric, Roborazzi, Turbine, Truth). ML Kit barcode scanning is removed in Task 11.

**Spec:** `/home/beanbocchi/shopnexus/specs/2026-10-17-app2-cod-only-design.md`. Mockups: `app2/.superdesign/tools/build_{chat,detail,sell,sell_review,cod_checkout,cod_order,orders,welcome,rep}.py` and `common.py` at app2 main `487af75`. Inventory of the in-person code with line numbers: `app2/.superpowers/sdd/2026-10-17-app2-cod-only/inventory.md` (copied in Task 1).

**Ruling on this plan's form:** as in stages 2 to 5, the plan fixes the contract changes, the rules with their test cases, the UI state and events, and every test by name; code is written during execution. Cost if wrong: screen code is reviewed only at the final review.

## Global Constraints

- Everything in stage 1 to 5's Global Constraints holds (minSdk 31, compileSdk 37, targetSdk 36, JVM 21, features never depend on features, `:core:model` and `:core:domain` are JVM, colours only through the theme, the type scale, corners 4/8/12/16/20/28/32 dp, touch targets ≥ 48 dp, Vietnamese strings in `strings.xml` with one value per name across modules, money as `Vnd`, new symbols through `core/designsystem/symbols.txt` and `tools/gen_symbols.py`).
- A task that changes behaviour fixes every test it breaks in the same task, the app walks included; a screenshot golden is re-recorded only after its compare image shows the intended change.
- Copy comes from the mockups at `487af75` word for word.
- `./gradlew check verifyRoborazziDebug` passes at the end of every task (`app2/tmp/gate.sh <log>`, wrapped in `timeout 1500`).
- Scratch files and logs go under `app2/tmp/`, never `/tmp`.
- Commit messages and code comments go through the humanizing-writing checker; commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Review Focus

1. A deal agreed above 5 triệu and then placed by COD: the hint in the console, the seller's message with its place chip, Giao COD for that deal and price, Đơn COD moving from placed to the door and on to delivered with no buyer action. Pinned in Task 5 (`ChatViewModelTest.anAgreementAboveTheLineSuggestsMeetingAndGoesOnByCod`) and Task 7 (`SimulatorCodTest.theCarrierDeliversAfterTheDoor`).
2. Chat after the handshake with no parcel yet, including process death and the seller's side: no crash (the old `orderLine(PLACED)` read `cod!!`), "Đặt COD" for the buyer, "Chờ … đặt COD" for the seller. Pinned in Task 5 (`DealConsoleTest.anAgreedDealWithoutAParcelAsksForCod`, `SellerConsoleTest.theSellerWaitsForTheBuyersCod`).
3. A debug jump while the simulator still has timers on the deal: jumping d-han or d-nam to any COD state, including refused, is not overwritten by a pending carrier report. Pinned in Task 7 (`OrderJumpsTest.aJumpStopsTheCarrier`).
4. The seller side of COD-only: a simulated buyer always places COD on Khánh Linh's listings, Tin của bạn's order notes have no meeting case, and "Đánh dấu đã bán" still records an off-app sale with its rating invitation. Pinned in Task 5 (`SimulatorTest.aBuyerAlwaysPlacesCod`) and Task 10 (`SellingTest.orderNotesSpeakOnlyOfCod`).
5. Strings, routes and dependencies left behind by the deletion: no unused string, no golden of a deleted screen, no ML Kit class on the classpath, no route that opens a deleted page. Pinned in Task 11 (`StringResourcesTest`, lint's UnusedResources at error, `InstallersTest`).

---

### Task 1: The ledger and the finished-step icons

**Files:** Modify `core/designsystem/.../component/PhaseStepper.kt` (done step: the phase's own symbol in `onPrimary` on a `primary` circle, no `Symbol.Check`), `core/designsystem/.../component/Timeline.kt` (same rule). Tests: `core/designsystem/src/test/.../PhaseStepperTest.kt` (new), `OrderComponentsTest`, `DealComponentsTest`, goldens that show a done step.

- [ ] **Step 1:** Copy the inventory into the workspace and start the ledger.
- [ ] **Step 2: Failing test.** `PhaseStepperTest.aFinishedStepKeepsItsIcon`: a stepper at phase 2 of the COD set draws the Sell and LocalShipping symbols for steps 0 and 1 and no Check symbol (read through the symbol's test tag or semantics, whichever `SymbolIcon` exposes; ruling if neither). `TimelineTest.aFinishedRowKeepsItsIcon` the same for the order timeline.
- [ ] **Step 3: Run, expect FAIL.** **Step 4: Implement. Step 5:** re-record the goldens whose compare image shows only the done steps changing; gate. **Step 6: Commit** `feat(ui): keep each finished step's icon`.

### Task 2: The meeting suggestion in the money sentences

**Files:** Modify `core/model/.../MoneyKey.kt` (add `MEET_HINT`), `core/domain/.../Handover.kt` (add `fun suggestsMeeting(price: Vnd): Boolean = price > COD_LIMIT`, KDoc: the line above which the app suggests meeting first), `core/domain/.../MoneyNotes.kt`, `core/designsystem/.../MoneyNote.kt` (MEET_HINT → `money_meet_hint` "Món trên 5 triệu nên hẹn gặp xem trực tiếp.", icon `Symbol.Group`), `core/ui/.../CodInfoSheet.kt`, `feature/deal/.../Sheets.kt` (`MoneyRulesSheet`).

**Interfaces (Produces):**

```kotlin
enum class MoneyGroup { COD, EVERY_DEAL }
data class MoneyRuleGroup(val group: MoneyGroup, val keys: List<MoneyKey>)
/** "Quy tắc tiền": the COD sentences for [side], the meeting suggestion above the line, then the two for every deal. */
fun moneyRules(price: Vnd, side: Party): List<MoneyRuleGroup>
```

Buyer COD keys: COD_BUYER, REFUSE, HANDOVER, then MEET_HINT when `suggestsMeeting(price)`. Seller COD keys: COD_SELLER, RETURN_LEG, HANDOVER_SELLER, then MEET_HINT when above. EVERY_DEAL: NO_HOLD, DECLARED. `MoneyStep.COD_INFO` becomes COD_BUYER, REFUSE, HANDOVER, MEET_HINT, NO_HOLD. The sheet's group titles: "COD, xem hàng trước", "Mọi giao dịch".

- [ ] **Step 1: Failing tests.** `HandoverTest.theLineIsFiveMillion` (5.000.000 no, 5.000.001 yes). `MoneyRulesTest` rewritten: `aBuyerUnderTheLineSeesCodAndEveryDeal`, `aBuyerAboveTheLineAlsoSeesTheSuggestion`, `aSellerSeesTheSellersCodSentences`. `MoneyStepsTest` COD_INFO. `ChatScreenTest.theMenuOpensTheMoneyRules` expects the two group titles and the suggestion above the line. Home's COD sheet test shows the suggestion.
- [ ] **Step 2–5:** fail, implement, pass, goldens (`chat-money-rules`, Home's COD sheet), gate. **Commit** `feat: suggest meeting above 5 triệu in the money sentences`.

### Task 3: The fair price judgment and the iPhone price

**Files:** Modify `core/model/.../Listing.kt` (`PriceDirection.FAIR`), every insight label (`when` is exhaustive, so the compiler lists them): FAIR reads "Ngang giá thị trường", with the sparkle and no percent; fixtures `listing-p-iphone13.json` (price 5.200.000, `suggestedOffers` 5.100.000, 5.000.000, 4.900.000, 4.800.000, the offer hint "Từ 4,9 tr thường được đồng ý", insight FAIR with range 4.900.000 to 5.600.000, the description's viewing sentence "Muốn xem máy trước thì hẹn quanh Bình Thạnh, buổi tối sau 18h."), `pool.json`, `deals.json` d-kiet (listed 5.200.000, Khánh Linh's offer 4.900.000 SUPERSEDED, Tuấn Kiệt's counter 5.100.000 OPEN, the text "4,9 thì hơi thấp bạn ơi. 5,1 mình bán liền, tặng thêm ốp.", price insight FAIR), `notifications.json` ("Tuấn Kiệt trả giá 5,1 tr cho iPhone 13 Pro"), `Previews.kt`. Tests: every test that names the old figures (about 40 files; `rg "10[_.,]?[469]00[_.]?000|10,[46] tr|10,9 tr"`).

- [ ] **Step 1: Failing tests.** `PriceInsightTest.aFairPriceSaysSo` (label "Ngang giá thị trường"). `ListingDetailViewModelTest.theIphoneIsListedAtFiveTwo` (price 5.200.000, chips 5,1/5/4,9/4,8). `ChatViewModelTest` start state counter 5.100.000.
- [ ] **Step 2–5:** fail; implement; update every test that asserted the old figures (the floor becomes 2.600.000, the stepper starts at 5.000.000 for a counter of 5.100.000); re-record the goldens that show the figures; gate. **Commit** `feat: list the iPhone 13 Pro at 5,2 tr with a fair price judgment`.

### Task 4: COD seeds

**Files:** `core/data/src/main/resources/fixtures/deals.json`, `notifications.json`, `core/data/.../fake/OrderJumps.kt`. Tests: `DealFixturesTest`, `FixturesTest`, `OrderJumpsTest`, `OrdersViewModelTest`, `OrdersScreenTest`, `InboxScreenTest`, `NotificationsViewModelTest`, `MyListingsScreenTest`, `DealPiecesTest`, and the goldens they own.

The data after this task (meeting points stay in the JSON until Task 11, where the model drops them):
- d-kiet and d-24h: `path` null.
- d-han (Ngọc Hân, bike, Khánh Linh buys): COD placed yesterday at 20:15, stage ARRANGE, a `cod` block like d-nam's with status PLACED and the 48-hour deadline (Thứ Bảy 20:15), no `meeting`, the checklist kept; thread texts about meeting become COD talk ("Ok bạn, mình gửi trong hôm nay nhé." last).
- d-bao (Gia Bảo, shelf, Khánh Linh sells): COD, stage DONE, `cod` RECEIVED with pick-up and delivery events, `handedOverAt` kept, rating 5, the AGREED and HANDED_OVER milestones kept, the RATED milestone removed, texts without meetings.
- Notification `meet` becomes `placed-han`: "Bạn đã đặt COD Xe đạp fixed gear. Ngọc Hân gửi trước 20:15 thứ Bảy.", target the order d-han.
- `ORDER_JUMPS` for d-han: PLACED, SHIPPING, AT_DOOR, RECEIVED, REVIEWED, REFUSED, RECORD_OPEN, RECORD_DECLINED (the COD branch of `orderAt`); for d-bao the seller COD set d-huy uses plus REVIEWED and the record states.

- [ ] **Step 1: Failing tests.** `DealFixturesTest.everyOrderGoesByCod` (every deal with a parcel has no `meeting` and no MEET path); `OrderJumpsTest.dHanJumpsThroughTheCodStates`, `dBaoJumpsThroughTheSellerCodStates`; `OrdersViewModelTest` rows for d-han ("Chờ Ngọc Hân gửi hàng" line) and d-bao.
- [ ] **Step 2–5:** fail, implement, pass, goldens (`orders-*`, `inbox-*`, `notifications-*`, `deal-pieces-*`, `my-listings-*` if they change), gate. **Commit** `feat: turn the in-person seeds into COD orders`.

### Task 5: COD after the handshake

**Files:** `core/domain/.../DealConsole.kt`, `core/data/.../fake/FakeDealEngine.kt`, `FakeDealRepository.kt` (`newDeal` sets no path), `Simulator.kt`, `DebugControls.kt`, `core/model/.../Thread.kt` (`Text.place: String? = null`), `core/ui/.../deal/OrderCopy.kt`, `core/ui/.../deal/Maps.kt` (new `openMap(context, place)`), `feature/deal/.../chat/{Console,ChatScreen,ChatViewModel,ChatUiState,Thread,Sheets}.kt`, `feature/deal/src/main/res/values/strings.xml`, `app/src/debug/.../DebugHost.kt` and its strings. Tests: `DealConsoleTest`, `DealConsoleRolesTest`, `SellerConsoleTest`, `FakeDealEngine*Test`, `Simulator*Test`, `DebugControlsTest`, `ChatScreenTest`, `ChatViewModelTest`, `SellerChatTest`, `ChatSidesTest`, `SliceTest`, `DealsWalkTest`, `DebugPanelTest`.

**Interfaces (Produces):**

```kotlin
// ConsoleState, replacing Choosing, Agreed(meeting), Proposing, AtMeeting, SellerArranging, SellerMeeting:
/** Agreed and no parcel yet: the buyer places COD; above the line the console suggests meeting to look first. */
data class Agreed(val price: Vnd, val suggestMeeting: Boolean) : ConsoleState
/** The seller after the handshake, until the buyer places COD. */
data class AwaitingCod(val price: Vnd) : ConsoleState
// ConsoleEvent loses ConfirmMeeting, Propose, Check, Scan. ThreadItem.Text gains `val place: String? = null`.
enum class ConsoleTarget { COUNTERED, WAITING, AGREED, PLACED, AT_DOOR, RECEIVED, DONE }
```

Behaviour:
- `DealConsole.state`: buyer ARRANGE with no `cod` → `Agreed(price, suggestsMeeting(price))`; any stage with a `cod` → the parcel states as today; seller ARRANGE with no `cod` → `AwaitingCod`. The deal's `path` is ignored from here on.
- Engine: `PlaceCod` needs ARRANGE and no parcel, nothing else; the meeting commands throw `IllegalStateException("No in-person hand-over")` until Task 11 removes them; `Rate` adds `ThreadItem.Event("star", "{n} sao cho {person}")` and no RATED milestone.
- Simulator: the seller's agreement reads "Ok bạn, {x} mình chốt. Máy trên 5 triệu, tối nay 19h gặp ở sảnh Landmark 81 xem máy nhé?" with `place = "Sảnh Landmark 81"` above the line and "Ok bạn, {x} mình chốt luôn. Bạn đặt COD đi, mình gửi liền." at or below it; a simulated buyer on Khánh Linh's listings always places COD; no meeting proposals or confirmations; the decline text loses its meeting flavour.
- Chat: the buyer console for `Agreed`: the handshake figure, a line with the LocalShipping icon "Giao COD · xem hàng rồi mới trả", `MoneyNote(MEET_HINT)` when `suggestMeeting`, and a full-width filled "Đặt COD" (LocalShipping) that pushes `CodCheckoutRoute(dealId)`. `AwaitingCod`: the figure and "Chờ {buyer} đặt COD". The stepper always shows the COD phases (`ChatUiState.phaseSet` goes). A text with a `place` shows the chip under its bubble: sparkle, the place, a Map icon; 48 dp target; content description "Mở {place} trên bản đồ"; tapping opens the maps URL with `Intent.ACTION_VIEW`. `Done`: the console hides the stepper row and shows "Đã xong" with "{n} sao cho {person}" under it and the problem button. The schedule, checklist, unchecked, scanner and code sheets leave Chat with their VM events and local state. The AGREED milestone's buyer line reads "Bắt tay rồi! Đặt COD, hoặc hẹn nhau xem máy."; the RATED milestone is no longer drawn.
- `OrderCopy.orderLine` never reads `cod!!` for a deal without a parcel.
- Debug: the chips walk d-kiet by COD (AGREED, PLACED, AT_DOOR, RECEIVED, DONE).

- [ ] **Step 1: Failing tests** (domain): `DealConsoleTest.anAgreedDealWithoutAParcelAsksForCod`, `anAgreementAboveTheLineSuggestsMeeting`, `SellerConsoleTest.theSellerWaitsForTheBuyersCod`. (data): `FakeDealEngineTest.codCanBePlacedRightAfterTheHandshake`, `aRatingAddsALineAndNoMilestone`; `SimulatorTest.theSellerNamesAPlaceAboveTheLine`, `theSellerAsksForCodAtTheLine`, `aBuyerAlwaysPlacesCod`; `DebugControlsTest.theChipsWalkTheDealByCod`. (feature): `ChatViewModelTest.anAgreementAboveTheLineSuggestsMeetingAndGoesOnByCod` (agree 5,1 tr: console `Agreed(5.100.000, true)`, the seller's text has the place, "Đặt COD" pushes `CodCheckoutRoute("d-kiet")`), `anOfferAtTheLineNeedsNoSuggestion` (5 tr), `ChatScreenTest.theAgreedConsoleOffersCod`, `thePlaceChipOpensTheMap`, `theFinishedConsoleIsOneLine`, `SellerChatTest.theSellerWaitsForCod`.
- [ ] **Step 2: Run, expect FAIL.** **Step 3: Implement.** **Step 4:** fix every broken test, rewrite `SliceTest` and `DealsWalkTest.meetWalk` as the COD walk from the counter to Giao COD; goldens (`chat-*`); gate. **Step 5: Commit** `feat: go on by COD after the handshake`.

### Task 6: Orders without in-person pages

**Files:** delete `feature/orders/.../meet/`, `sellmeet/`, `MeetParts.kt`, their tests and goldens; modify `OrderRouter.kt` (`OrderPage { COD, SHIP, CHAT }`), `list/OrdersScreen.kt` (no Group icon or "Gặp mặt" label, the COD phases only), `core/ui/.../deal/OrderCopy.kt` (no ARRANGING, WAITING, MET, CANCELLED lines or actions), `feature/orders/src/main/res/values/strings.xml`. Tests: `OrderRouterTest`, `OrdersScreenTest`, `OrdersViewModelTest`, `DealPiecesTest`, `InstallersTest`.

- [ ] **Step 1: Failing tests.** `OrderRouterTest.everyAgreedOrderOpensACodPage` (d-han → COD, d-bao → SHIP, d-kiet without a parcel → CHAT); `OrdersScreenTest.everyRowShowsTheCodPhases`.
- [ ] **Step 2–5:** fail, implement, delete, pass, goldens, gate. **Commit** `feat: drop the in-person order pages`.

### Task 7: The COD door follows the shipper

**Files:** `core/model/.../Listing.kt` (`Claim`, `Listing.claims`), `Deal.kt` (`CheckTip`, `Deal.tips` replacing `CheckItem` and `checklist`; `SetCheck`, `ReceiveParcel` and `RefuseParcel` leave `DealCommand`), `DealView` (`claims`), fixtures (`claims` for p-iphone13 and the iPhone X listing of d-nam; tips from `account.json` checklists without `checked`), `FakeDealEngine.kt` (internal `carrierDelivered(deal)`, `carrierRefused(deal, reasons)`), `Simulator.kt` (at the door, the carrier reports delivered after 6 s divided by the pace), `OrderJumps.kt` (REFUSED through `carrierRefused`; `jump` stops the deal's timers first), `core/ui/.../deal/CheckList.kt` → `Claims.kt` (`ClaimsRow`, `ClaimsSheet`; `ChecksLeftDialog` and `CheckListBlock` deleted), `feature/orders/.../cod/{CodOrderScreen,CodOrderViewModel}.kt`, `GeneratedDetails.kt` (generated listings get no claims). Tests: `CodOrderScreenTest`, `CodOrderViewModelTest`, `SimulatorStage3Test`, `OrderJumpsTest`, `DealJsonTest`, `ClaimsTest` (new, `core/ui`).

Door page at `AT_DOOR`: no bottom actions; the `COD_DOOR` notes become REFUSE only; one `ClaimsRow` in a `surfaceContainer` group: FactCheck icon, "Tin ghi" over the claims and declared marks joined by " · " (maxLines 2), a chevron; tapping opens `ClaimsSheet`: title "Tin ghi", "Lời của {seller} trong tin, kèm cách tự kiểm", the claims (icon, text, how), the marks (close-up, text, "Ảnh cận chụp trong app · dd/MM"), the DECLARED sentence, then "Mẹo kiểm {noun}" with the sparkle and "Gợi ý chung, không phải điều {seller} cam kết", the tips (icon, text, how). With no claims and no marks the row reads "Mẹo kiểm {noun}". The received and refused pages keep their current layout.

- [ ] **Step 1: Failing tests.** `SimulatorCodTest.theCarrierDeliversAfterTheDoor` (placed → shipping → door → received with no command, `handedOverAt` set, DEAL points); `OrderJumpsTest.aJumpStopsTheCarrier`; `CodOrderViewModelTest.theDoorHasNothingToPress`; `CodOrderScreenTest.theDoorShowsWhatTheListingSays` (row text "Pin 86% · Bản quốc tế, đã mở mạng · Xước nhẹ cạnh phải"), `theClaimsSheetHasNothingToTick` (no `Role.Checkbox` node), `ClaimsTest.withoutClaimsTheRowOffersTips`; `DealJsonTest.aDealReadsItsTips`.
- [ ] **Step 2–5:** fail, implement, pass, goldens (`order-cod-door-*`, the sheet), gate. **Commit** `feat: let the shipper's report settle the COD door`.

### Task 8: Listing detail opens Chat and shows COD only

**Files:** `feature/discover/.../detail/{DetailSections,ListingDetailViewModel,ListingDetailScreen}.kt`, strings. Tests: `ListingDetailScreenTest`, `ListingDetailViewModelTest`, goldens `detail-*`.

DealSection: one row in a `surfaceContainer` group with LocalShipping, "COD, xem hàng trước", "Gửi từ {district} · trả tiền khi đã xem"; under it `MoneyNote(MEET_HINT)` when `suggestsMeeting(price)` and `MoneyNote(NO_HOLD)`. `Ask` and `SendOffer`, once the command succeeds, push `ChatRoute(dealId)`; a failed command keeps today's error snackbar.

- [ ] **Step 1: Failing tests.** `ListingDetailViewModelTest.aQuestionOpensTheChat`, `anOfferOpensTheChat` (route pushed, no "Đã gửi" snackbar); `ListingDetailScreenTest.theDealSectionShowsCodOnly` (no "Gặp mặt"; the suggestion at 5,2 tr), `underTheLineThereIsNoSuggestion` (the iPhone X at 3,9 tr).
- [ ] **Step 2–5.** **Commit** `feat: open Chat from an offer or a question, and show COD only on a listing`.

### Task 9: Selling with COD only

**Files:** `feature/sell/.../parts/DeliveryBlock.kt` (one row: LocalShipping, "COD, xem hàng trước", "Người mua xem hàng rồi mới trả"; the COD_SELLER and RETURN_LEG sentences; MEET_HINT when the price is above the line), `form/{SellForm,SellScreen,SellViewModel}.kt` (no `FormEdit.Path`, no `Block.DELIVERY` error), `review/{ReviewScreen,ReviewViewModel}.kt` (the row reads "COD, xem hàng trước", no sheet; the hint above the line), `core/domain/.../Posting.kt` (`PostProblem.NO_PATH` and `pathsFor` go), strings. Tests: `SellFormTest`, `SellPartsTest`, `ReviewScreenTest`, `ReviewViewModelTest`, `PostingTest`, `PostingAndMoneyTest`, `SellWalkTest`.

- [ ] **Step 1: Failing tests.** `PostingTest.anyPriceCanBePosted` (6.000.000 has no problem); `SellPartsTest.theDeliveryBlockHasOneWay`, `aboveTheLineItSuggestsMeeting`; `ReviewScreenTest.theDeliveryRowIsCod`.
- [ ] **Step 2–5.** `SellWalkTest.meetSaleWalk` becomes the walk where a simulated buyer places COD on a listing above the line. **Commit** `feat: post with COD as the one way to hand over`.

### Task 10: Account copy without meetings

**Files:** `feature/auth/.../welcome/WelcomeScreen.kt` + strings ("Giao tận nơi, xem hàng rồi mới trả", LocalShipping), `feature/me/.../rep/RulesSheet.kt` + strings (the two cancellation rules go), `feature/me` `me_bio_hint` ("Bạn bán gì, ở khu nào"), `core/domain/.../Standing.kt` (`dueOrder` without the meeting case), `core/domain/.../Selling.kt` (`askerLine` and `orderNote` without meeting cases), `AccountFakes.kt` event words. Tests: `WelcomeScreenTest`, the rules sheet test, `StandingTest`, `SellingTest`, `TasksScreenTest`, goldens `welcome-*`, `rep-rules-*`, `tasks-bio-*`.

- [ ] **Step 1: Failing tests.** `WelcomeScreenTest.thePromisesSpeakOfDelivery`; `StandingTest.theDueOrderIsAParcel`; `SellingTest.orderNotesSpeakOnlyOfCod`; the rules sheet has no "Hủy" rule.
- [ ] **Step 2–5.** **Commit** `feat: drop meetings from the account copy`.

### Task 11: Delete the in-person contract

**Files:** `core/model` (`HandoverPath`, `Listing.paths`, `meetNote`, `ListingDraft.paths`, `Deal.path`, `meeting`, `meetPoints`, `Meeting`, `MeetPoint`, the commands `ProposeMeeting`, `ConfirmMeeting`, `RecordHandover`, `CancelMeeting`, `DealEnd.CANCELLED`, `MilestoneKind.RATED`, `MoneyKey.MEET`, `OVER_LIMIT`), `core/domain` (`codAllowed`, `availablePaths`, `OrderStatus` ARRANGING/WAITING/MET/CANCELLED, `ReputationEvent` CANCEL_AFTER_AGREE/CANCEL_MEETING_LATE, `cancelPenalty`, `LATE_CANCEL`, `meetingLabel`, the meeting `MoneyStep`s, `needsCheckWarning`), `core/data` (`handoverCode`, `WorldState.codes`, `onCodeIssued`, `AccountSeed.meetPoints`, the engine's meeting branches, the simulator's meeting helpers), fixtures (every `meetPoints`, `path`, `paths`, `meetNote`, `meeting`), `core/designsystem` (`PhaseSet`, `meetPhases`, `phase_arrange`, `phase_meet`, `money_meet`, `money_over_limit`), `core/ui` (`MeetingSheet.kt`, `CodeSheet.kt`, `Scanner.kt` except what eKYC or video uses, the time options in `Drafts.kt`, meeting strings), `core/ui/build.gradle.kts` and `gradle/libs.versions.toml` (ML Kit), every string, test and golden left only for these, `README.md` line 49, the debug strings. Tests: whatever still names them; `StringResourcesTest`; lint.

- [ ] **Step 1:** Delete in dependency order, compiling after each module; rewrite the fixture tests (`SerializationTest`, `SellingJsonTest`, `FixturesTest`) to the new JSON.
- [ ] **Step 2:** `rg -n "MEET|Meeting|MeetPoint|meetNote|HandoverPath|handoverCode|mlkit|gặp mặt|Gặp mặt|hẹn" --glob '!**/build/**'` and justify every remaining hit in the ledger (the meeting suggestion and the place chip are expected).
- [ ] **Step 3:** gate; delete goldens nothing records any more. **Commit** `refactor: delete the in-person hand-over`.

### Task 12: Walks and devices

**Files:** `app/src/test/.../{SliceTest,DealsWalkTest,SellWalkTest}.kt` (final pass), `app2/tmp/` APK.

- [ ] **Step 1:** The app walks cover: d-kiet countered → offer 5 tr → agreed without the suggestion → Đặt COD → Giao COD → Đơn COD → door → delivered → rated; d-kiet agreed at 5,1 tr with the suggestion and the place chip; Listing detail's offer and question opening Chat.
- [ ] **Step 2:** Emulator walk of the same, with screenshots in `app2/tmp/work/walk/`; fix what the device shows and Robolectric did not.
- [ ] **Step 3:** gate; ledger. Final review (code reviewer and mockup comparison, both opus), one fix pass, merge, APK `app2/tmp/shopnexus-cod-<hash>-debug.apk`, install on the emulator and the Pixel.
