# Design: app2 stage 3, Giao dịch

Date: 2026-10-15
Status: draft. The user's standing instruction is to keep building, so this
spec goes straight to a plan; the decisions marked as rulings are the ones to
review.

## Goal

Stage 3 builds the deal side of the app on the stage 1 and 2 foundation: Tin
nhắn, Đơn hàng, Chi tiết đơn, Giao COD, Đơn COD and Đơn bán, Chat for every
conversation and both roles, new deals from Listing detail, and the QR
scanner on CameraX and ML Kit. The screens are designed in
`app2/.superdesign/` (`design-system.md`, `tools/build_inbox.py`,
`build_orders.py`, `build_order.py`, `build_cod_checkout.py`,
`build_cod_order.py`, `build_ship_order.py`, `order_kit.py`, `common.py`);
`app2/.superdesign/stage3-digest.md` lists their data, strings and
interactions with source lines. The deal model is `app2/mohinh.md`.

Stage 1 and 2 decisions hold: Android only, Kotlin, Compose with material3
1.5.0-beta01, Navigation 3, Hilt, ViewModel + `StateFlow`, fake repositories
over one `FakeWorld`, the simulator playing the other side, JVM tests with
Robolectric and Roborazzi at a zero-pixel threshold. The repository
interfaces stay the API contract for the Go server.

## Rulings on the mockups

The mockups are prototypes with one working conversation and hard-wired page
states. The app follows the deal model and `design-system.md`:

1. Every conversation opens Chat. The mockup sends Hoàng Nam's row to Giao
   COD, Đức Huy's to Đơn bán and the others to "Bản mẫu chỉ mở được cuộc trò
   chuyện với Tuấn Kiệt". In the app each row opens its Chat, and Chat's deal
   console leads to the order: "Đặt COD" to Giao COD, "Gửi hàng" or "Xem
   đơn" to the order page. Thanh Lý 24h's row opens the scam sheet first.
2. One deal is at one moment. The mockups show the iPhone X agreed (Tin
   nhắn), at the door (Đơn hàng, Thông báo) and just placed (Giao COD). The
   world starts at the earliest moment, agreed and not placed, so Giao COD
   and Đơn COD are walked in order: placing the order starts the carrier
   fake, which reports pickup after 3.5 s and the door 3.5 s later (the
   `#placed` timings) and posts the notification "Shipper đang giao iPhone
   X. Xem máy rồi mới trả." at the door. The seeded copy of that
   notification goes, so Thông báo starts with 3 unread.
3. A deal becomes an order once its price is agreed and its way to hand
   over is set. Above 5.000.000 ₫, or when the listing offers one way only,
   the way is set at agreement. Otherwise the buyer sets it after agreeing:
   "Hẹn gặp" in Chat sets in person, "Đặt COD" sets COD. Đơn hàng starts
   with "Mua · 2" (the bike, the headphones) and shows the iPhone X once
   its COD is placed. Before the way is set, the stepper shows the in-person
   phases.
4. The phase stepper follows the deal the same way for both sides and both
   pages: Thương lượng until agreement; Hẹn gặp or Gửi hàng until the meeting
   is confirmed or the carrier picks the parcel up; Gặp và kiểm or Xem và
   nhận until the hand-over is recorded or the parcel is received; Đánh giá
   until the buyer rates; then all four are done. Opening a record leaves
   the step where it is; the mockups put the buyer's parcel in transit on
   step 2 and a recorded order on "done".
5. The 48-hour window is `handoverDeadline`. Đức Huy's order was placed
   yesterday at 18:00, which keeps "Gửi trước 18:00 thứ Sáu" on Đơn hàng,
   Đơn bán and Thông báo; its timeline reads "Hôm qua · 18:00" where the
   mockup says "Hôm nay · 09:12", and the countdown is live ("còn 26 giờ"
   at 15:10 where the mockup says 31).
6. Each listing keeps one id, one title and one seller (stage 2 ruling 3).
   The bike is `p-fixed` from Ngọc Hân and the iPhone X is `p-iphonex` from
   Hoàng Nam, with the pool's longer titles. The headphones are `p-xm4`,
   which moves from Đức Trí to Quốc Bảo, the seller the order names, and is
   sold, so it leaves Home and Đức Trí's page. Khánh Linh's own listings
   (Đàn guitar Yamaha F310 1.900.000 ₫, Ghế đôn gỗ cao 350.000 ₫, Kệ gỗ
   nhỏ 3 tầng 650.000 ₫, from `build_listings.py`) are not in the pool;
   tapping one opens the stage 4 placeholder "Tin của bạn". Thanh Lý 24h's
   Galaxy S23 Ultra (8.700.000 ₫, the photo of `p-s23`) was removed after
   reports, so its Listing detail shows the missing-listing state.
7. Quốc Bảo's conversation is archived. The inbox shows the mockup's seven
   rows; the headphones order's chat opens from Đơn hàng. An archived
   conversation comes back to the inbox when the other person writes.
8. A seller's in-person order opens its Chat. No mockup designs that page;
   Gia Bảo's shelf order is finished, and the seller's code screen and the
   seller's replies to in-person records move to stage 4 with Tin của bạn.
   Seller bargaining (accepting or countering a buyer's offer) is stage 4 as
   well: a seller's console during negotiation shows the listed price and no
   action.
9. Copy for order states the mockups do not draw is written from the
   designed states' words and marked "new" in the tables below. Where a
   designed sentence names the item, it uses the item's noun: "máy" for
   phones, computers, watches, audio, cameras and appliances, "xe" for bikes
   and motorbikes, "hàng" for the rest ("Kiểm xe 0/4", "Máy có vấn đề?").
   Dates in Đơn hàng lines take one form, `dayLabel`, so the headphones read
   "Thứ Hai" where the mockup says "12/10".
10. Receiving a parcel with checks left opens "Chưa kiểm xong" with "Vẫn
    nhận" and "Kiểm tiếp"; the mockup reuses the scanner's "Vẫn quét".
11. The record replies are per person. Tuấn Kiệt refunds 300.000 ₫ 2.2 s
    after a record (stage 1), Ngọc Hân declines 2.4 s after one, Hoàng Nam
    does not answer. Records and the other mockup hashes (`#expired`,
    `#refused`, `#record`) are reached on Đức Huy's and Hoàng Nam's orders
    through the debug panel, which jumps any seeded order to any of its
    states.
12. Controls the mockups answer with a "Bản mẫu …" snackbar work:
    "Chỉ đường" opens a maps app on the meeting place, "Sao chép mã đơn"
    copies, "Đổi" on the meeting opens the "Hẹn gặp" sheet, chat buttons
    open the order's Chat, item rows open Listing detail. Address and
    payment "Đổi", "Trợ giúp", "Tìm trong tin nhắn" and "Xem quyền của
    bạn" open placeholders. The "Bản thiết kế …" footers are not built.
13. "Chụp hàng" on Đơn bán takes a real photo with the camera app, as Photo
    search does; "Hiện mã QR" draws a real QR code of the shipping code; the
    scanner reads real QR codes. The fake accepts any code, since stage 3
    has no seller's code screen to scan.
14. "COD của bạn" counts the buyer's open COD orders from the deals: "1/5
    đơn đang mở sau đơn này", where the mockup's fixed count says 2/5.
    Khánh Linh is Tin cậy (386 points, `build_rep.py`), so her cap is 5.
15. Empty Đơn hàng sides say what is missing ("Chưa có đơn mua nào.", "Chưa
    có đơn bán nào.") above "Khám phá tin quanh bạn", as `design-system.md`
    asks of empty states; the mockup shows the button alone.
16. Thông báo's "Ngọc Hân đồng ý hẹn 18:00 hôm nay …", sent yesterday, reads
    "… 18:00 thứ Năm …", so it stays true the day after it was sent.

## Scope

| Built in stage 3 | Opens a placeholder |
|---|---|
| Tin nhắn: chips, rows with tags, swipe to read and archive with undo, scam sheet with block and report, empty states, the navigation badge | "Tìm trong tin nhắn" |
| Chat for every deal and both roles, the new console states, photos in the composer | |
| New deals from Listing detail ("Nhắn tin", "Trả giá", question chips) and from Người bán and the compare sheet | |
| Giao COD: carriers, money rows, COD right, placing, the milestone | address and payment "Đổi", "Xem quyền của bạn" |
| Đơn hàng: Mua and Bán, rows with stepper, line and one action, rating in place | |
| Chi tiết đơn: every in-person buyer state, checks, scanner, cancel, rating, record, withdraw, meeting change, directions, copy | "Trợ giúp" |
| Đơn COD: every buyer COD state, door inspection, receive, refuse with reasons, rating, record | |
| Đơn bán: every seller COD state, packing photo, shipping-code QR, pickup or drop-off, refund and decline | |
| QR scanner on CameraX and ML Kit, with a simulated mode | the seller's code screen (stage 4) |
| Home's COD slide: a sheet with the COD sentences | |
| Tôi placeholder links "Đơn mua" and "Đơn bán"; Thông báo rows open their orders | |

## Modules

| Module | Holds | May depend on |
|---|---|---|
| `:feature:inbox` (new) | Tin nhắn, the scam sheet | `:core:*` |
| `:feature:orders` (new) | Đơn hàng, Chi tiết đơn, Giao COD, Đơn COD, Đơn bán, the order router | `:core:*` |
| `:feature:deal` | Chat | `:core:*` |
| `:core:ui` | grows a `deal` package shared by Chat and the order pages: the record sheet, the scanner, the check dialog, the "Hẹn gặp" sheet, the rating row, the order lines and actions, the item and person rows, the QR code drawing | `:core:designsystem`, `:core:data`, `:core:navigation` |
| `:core:designsystem` | grows the status hero, the timeline, the swipe row, the connected toggle group, the status tag and a neutral milestone tone | |

CameraX (`camera-camera2`, `camera-lifecycle`, `camera-compose`), ML Kit
barcode scanning (bundled model) and ZXing core (encoding only) join the
version catalog; only `:core:ui` uses them.

## Domain model and API contract (`:core:model`)

Changed and new types, all `@Serializable`.

- `ChatView` is renamed `DealView`: the deal, the listing summary, the other
  person, `me` and the declared marks, read by Chat and the three order
  pages.
  People who only buy (Minh Quang, Đức Huy) have a `SellerSummary` too.
- `Deal.path` becomes nullable: null while both ways are open and the buyer
  has not chosen. `DealStage` gains ENDED, with `Deal.end: DealEnd`
  (CANCELLED, REFUSED). New fields: `code` (the order number, "SN-24817"),
  `agreedAt`, `ratedAt`.
- `Meeting` gains `confirmedAt`; `MeetPoint` gains `area` and `distanceKm`
  ("Phú Nhuận · cách bạn 2,1 km").
- `CodShipment` holds: `carrier` (`Carrier`: id, name, days, fee),
  `placedAt`, `deadline`, `paidWith` ("MoMo •• 0912"), `to`
  (`DeliveryAddress`: name, masked phone, address line), `status`
  (`CodStatus`: PLACED, SHIPPING, AT_DOOR, RECEIVED, REFUSED), `events`,
  `eta` (`TimeWindow`), `code` ("SNX 8841 2207"), `method` (`ShipMethod`:
  PICKUP, DROP_OFF), `pickupWindow`, `postOfficeKm`, `packPhotoUrl`,
  `payoutTo` ("Vietcombank •• 4821"), `returnFee`, `pickedUpAt`,
  `receivedAt`, `refusedAt`, `refusalReasons` (`RefusalReason`:
  UNDECLARED_MARK, NOT_AS_DESCRIBED, CHANGED_MIND).
- `IncidentRecord` gains `openedAt` and `answeredAt`.
- `DealCommand` is what the signed-in person can do; the engine reads their
  role from `me`. New commands: `SendPhotos(urls)`, `PlaceCod(carrierId)`,
  `ReceiveParcel`, `RefuseParcel(reasons)`, `CancelMeeting`,
  `WithdrawRecord(recordId)`, `ShipParcel(photoUrl, method)`,
  `RefundRecord(recordId, amount)`, `DeclineRecord(recordId)`.
- `InboxRow`: deal id, my role, the other person, the listing, the last
  message (text, mine, time), unread count, the tag (`InboxTag`: Counter,
  Agreed, AwaitingShipment, Sold, Scam), and the scam warning
  (`ScamWarning`: signals with icon and text). `Inbox`: the rows and the
  unread total.
- `CodCheckout`: the `DealView`, the carriers, the delivery address, the
  payment method, my open COD orders, my cap and any COD block.
- `NotificationTarget` gains `Order(dealId)`.

Repository interfaces in `:core:data`:

| Interface | Reads | Commands |
|---|---|---|
| `DealRepository` (grows) | `deal(id)` (was `chat`), `orders()`, `checkout(id)`, `counterpartTyping(id)` | `start(listingId)` returning the deal id, `send(id, command)` |
| `InboxRepository` (new) | `inbox()`, `unreadCount()` | `setRead(id, read)`, `setArchived(id, on)`, `blockAndReport(id)` returning what it changed, `restore(changed)` |

`start` returns the person's open deal on that listing, or creates one in
Thương lượng with the listing's open ways (one way sets `path`). A blocked
person's conversations leave the inbox; their listings leave every feed as
in stage 2.

## Deal and order rules (`:core:domain`)

| Function | Rule |
|---|---|
| `orderStatus(deal, me, now)` | the order's state for that side; the table in Order states; a record that is not withdrawn decides over the base state; a placed parcel not picked up by its deadline is EXPIRED |
| `isOrder(deal)` | an agreed price and a set way |
| `phaseOf(deal)` | the step of ruling 4: 0 to 3, or 4 when all are done; an ended deal stays on the step it ended on |
| `inboxTag(deal, me, warning)` | Scam when there is a warning; an open counter: Counter with its amount; a COD order I must ship: AwaitingShipment; agreed and not finished: Agreed with the price; finished as the seller: Sold with the price; otherwise none |
| `inboxTime(at, now, zone)` | "14:10" today, "Hôm qua", the weekday within the week, else "12/10" |
| `dayLabel(at, now, zone)` | "Hôm nay", "Hôm qua", the weekday within the week, else "12/10" |
| `momentLabel(at, now, zone)` | "Vừa xong" within a minute, "Hôm nay · 09:40", "Hôm qua · 20:15", else "12/10 · 14:20" |
| `deadlineLabel(at, now, zone)` | "Trước 20:15 hôm nay", "Trước 18:00 thứ Sáu" within six days, else "Trước 18:00 · 22/10" |
| `timeLeft(deadline, now)` | "còn 26 giờ" in whole hours, "còn 40 phút" under an hour |
| `recordDaysLeft(openedAt, now)` | days left of the seller's three-day reply window, rounded up |
| `itemNoun(kind)` | "máy", "xe" or "hàng" (ruling 9) |
| `shortTitle(title)` | the text before the first comma, without a trailing storage size: "iPhone X 64GB, pin 86%, máy zin chưa sửa" → "iPhone X" |
| `refundOptions(price)` | 15 % and 30 % of the price rounded down to 50.000 ₫, and the whole price; zeros and repeats dropped: 350.000 ₫ → 50.000, 100.000, 350.000 |
| `cancelPenalty(meetingAt, now)` | CANCEL_MEETING_LATE (−30) from two hours before the meeting, else CANCEL_AFTER_AGREE (−20) |
| `codSlots(rights, openCod)` | the open count after this order, the cap, and whether it fits and COD is not blocked |
| `orderRows(views, me, side)` | the orders on that side, newest activity first |
| `DealConsole.state(deal, me, draft, now)` | the console states in Chat below, for both roles |

The engine (`FakeDealEngine`) refuses a command out of order or from the
wrong side, as it does in stage 1: a buyer cannot ship, a seller cannot
rate, a parcel is received or refused only at the door, a refund is between
1 ₫ and the price, COD is placed only when `codAllowed` and `codSlots`
allow it.

## Order states

`orderStatus` returns one of ARRANGING, WAITING, MET, PLACED, TO_SHIP,
SHIPPING, AT_DOOR, RECEIVED, REVIEWED, REFUSED, EXPIRED, CANCELLED,
RECORD_OPEN, RECORD_REFUNDED, RECORD_SETTLED and RECORD_DECLINED. Each page
heads with the status hero: a 96 dp MaterialShape around the icon, the title
in `headlineSmall`, one row of icon facts, the feeling line when the state
has one; `liveRegion` polite.

Chi tiết đơn, the buyer in person (`build_order.py`):

| Status | Hero (shape, fill, icon, title) | Facts and feeling | Bar |
|---|---|---|---|
| ARRANGING (new) | Cookie9Sided, `tertiaryFixed`, handshake, "Đã chốt giá" | event · the proposed meeting and "chờ bạn đồng ý" or "chờ Tuấn Kiệt đồng ý", or "Chưa hẹn gặp" | "Đồng ý hẹn" (primary) when the seller proposed |
| WAITING | Cookie9Sided, `primaryContainer`, event, "Hẹn 18:00 hôm nay" | location · Công viên Gia Định | "Hủy hẹn" (tonal icon), "Quét mã của Ngọc Hân" (primary) |
| MET | SoftBurst, `primaryContainer`, QR, "Giao dịch đã ghi nhận" | payments · Đã trả 2.300.000 ₫ tại chỗ; "Chúc bạn đạp xe thật vui!"; the stars | "Xe có vấn đề?" (tonal) |
| REVIEWED | Flower, `secondaryContainer`, star, "Hoàn tất" | star · 5 sao cho Ngọc Hân; "Đánh giá thật giúp chợ thêm tử tế." | "Xe có vấn đề?" |
| RECORD_OPEN | Gem, `surfaceContainerHighest`, report, "Đã ghi nhận sự cố" | hourglass · Chờ Ngọc Hân trả lời | "Rút ghi nhận" (tonal) |
| RECORD_DECLINED | as RECORD_OPEN | block · Ngọc Hân từ chối · hiện trên hồ sơ của họ | "Rút ghi nhận" |
| RECORD_REFUNDED (new) | Flower, `secondaryContainer`, undo, "Tuấn Kiệt tự hoàn 300.000 ₫" | account balance · Chuyển khoản trực tiếp cho bạn | "Đã nhận tiền hoàn" (primary) |
| RECORD_SETTLED (new) | Flower, `secondaryContainer`, check, "Đã nhận tiền hoàn" | undo · 300.000 ₫ từ Tuấn Kiệt | none |
| CANCELLED | Circle, `surfaceContainerHighest`, event busy, "Đã hủy hẹn" | trending down · −20 điểm uy tín (or −30) | none |

Đơn COD, the buyer by COD (`build_cod_order.py`):

| Status | Hero | Facts and feeling | Bar |
|---|---|---|---|
| PLACED | Cookie9Sided, `primaryContainer`, schedule send, "Chờ Hoàng Nam gửi hàng" | timer · Còn 47 giờ; the "Hạn gửi hàng" block with the handover sentence | none |
| SHIPPING | Cookie9Sided, `primaryContainer`, truck, "Đang giao" | schedule · Dự kiến 14:00–16:00 hôm nay | none |
| AT_DOOR | SoftBurst, `primaryContainer`, door, "Shipper đang ở cửa" | eye · Xem hàng trước khi trả | "Từ chối nhận" (tonal), "Nhận · trả 3,8 tr" (primary) |
| RECEIVED | SoftBurst, `primaryContainer`, check, "Đã nhận iPhone X" | payments · Đã trả 3.800.000 ₫ cho shipper; "Chúc bạn dùng máy thật vui!"; the stars | "Máy có vấn đề?" (tonal) |
| REVIEWED | Flower, `secondaryContainer`, star, "Hoàn tất" | star · 5 sao cho Hoàng Nam; "Đánh giá thật giúp chợ thêm tử tế." | "Máy có vấn đề?" |
| REFUSED | Gem, `surfaceContainerHighest`, undo, "Đã từ chối nhận" | truck · Máy quay về Hoàng Nam; payments · Bạn mất 22.000 ₫ phí ship; the refused-stat sentence | none |
| EXPIRED | Circle, `surfaceContainerHighest`, event busy, "Hoàng Nam chưa gửi hàng" | undo · Đã hoàn 22.000 ₫ phí ship về MoMo | none |
| RECORD_* | as Chi tiết đơn, with Hoàng Nam and "Máy" | | as Chi tiết đơn |

Đơn bán, the seller by COD (`build_ship_order.py`):

| Status | Hero | Facts and feeling | Bar |
|---|---|---|---|
| TO_SHIP | Cookie9Sided, `primaryContainer`, schedule send, "Gửi trước 18:00 thứ Sáu" | timer · Còn 26 giờ | "Xác nhận gửi" (primary), enabled once the packing photo exists |
| SHIPPING | Cookie9Sided, `primaryContainer`, truck, "Đang giao cho Đức Huy" | schedule · Dự kiến ngày mai | none |
| RECEIVED, REVIEWED | SoftBurst, `primaryContainer`, check, "Đức Huy đã nhận hàng" | account balance · Tiền về tài khoản trong 1–2 ngày; "Món đồ cũ đã có chủ mới." | none |
| REFUSED | Gem, `surfaceContainerHighest`, undo, "Đức Huy từ chối nhận" | truck · Hàng đang quay về; payments · Phí chiều về 22.000 ₫ | none |
| EXPIRED (new) | Circle, `surfaceContainerHighest`, event busy, "Đơn đã tự hủy" | undo · Đức Huy được hoàn phí ship | none |
| RECORD_OPEN | Gem, `surfaceContainerHighest`, report, "Đức Huy mở ghi nhận sự cố" | hourglass · Bạn trả lời trong 3 ngày | "Từ chối" (tonal), "Tự hoàn" (primary) |
| RECORD_REFUNDED, RECORD_SETTLED | Flower, `secondaryContainer`, undo, "Bạn đã tự hoàn" | undo · Hoàn 100.000 ₫; trending up · +15 điểm uy tín; "Cảm ơn bạn đã giữ chợ tử tế." | none |
| RECORD_DECLINED | Gem, `surfaceContainerHighest`, block, "Bạn đã từ chối" | eye · Ghi nhận hiện trên hồ sơ của bạn | none |

On Đơn hàng, each order's line and action:

| Status | Line | Action |
|---|---|---|
| ARRANGING | handshake · Đã chốt · đang hẹn gặp (new) | chat, "Hẹn gặp" to Chat |
| WAITING | location · 18:00 hôm nay · Công viên Gia Định | chat, "Kiểm xe và quét mã" |
| MET (buyer) | payments · Đã gặp và trả tiền · Thứ Hai (new) | the stars |
| MET, REVIEWED (seller, in person) | payments · Đã gặp và nhận tiền · Thứ Hai | none |
| PLACED | schedule send · Chờ Hoàng Nam gửi hàng · còn 47 giờ (new) | chat, "Xem đơn" |
| TO_SHIP | timer · Gửi trước 18:00 thứ Sáu · còn 26 giờ | chat, "Gửi hàng" |
| SHIPPING | truck · Đang giao · dự kiến 14:00–16:00 hôm nay (new) | chat, "Xem đơn" |
| AT_DOOR | door · Shipper đang ở cửa · xem máy rồi mới trả | chat, "Xem hàng" |
| RECEIVED (buyer) | package · Đã xem và trả shipper · 12/10 | the stars |
| RECEIVED (seller) | check · Đức Huy đã nhận hàng (new) | none |
| REVIEWED | star · 5 sao cho Quốc Bảo | none |
| REFUSED | undo · Đã từ chối nhận, or Đức Huy từ chối nhận (new) | chat, "Xem đơn" |
| EXPIRED | event busy · Hoàng Nam chưa gửi hàng, or Đơn đã tự hủy (new) | chat, "Xem đơn" |
| CANCELLED | event busy · Đã hủy hẹn (new) | none |
| RECORD_OPEN | report · Chờ Ngọc Hân trả lời, or Bạn trả lời trong 3 ngày (new) | chat, "Xem đơn" or "Trả lời" |
| RECORD_REFUNDED, RECORD_SETTLED, RECORD_DECLINED | the hero's first fact (new) | chat, "Xem đơn" |

## Fake data (`:core:data`)

- `deals.json` replaces `chat-d-kiet.json` with eight deals, each with a
  short thread ending on the mockups' previews and times:

  | Deal | People and listing | Moment |
  |---|---|---|
  | `d-kiet` | Tuấn Kiệt, iPhone 13 Pro | the stage 1 counter, 1 unread |
  | `d-24h` | Thanh Lý 24h, Galaxy S23 Ultra 8.700.000 ₫ | negotiating, the deposit message at 13:41, 1 unread, the three scam signals |
  | `d-quang` | Minh Quang asks about my guitar | negotiating as seller, 13:22, 1 unread |
  | `d-huy` | Đức Huy, my stool | COD placed yesterday at 18:00, Giao nhanh 22.000 ₫, SNX 8841 2207, his message at 09:12 |
  | `d-nam` | Hoàng Nam, iPhone X | agreed 3.800.000 ₫ yesterday, way not chosen, his "Bạn đặt COD đi" |
  | `d-han` | Ngọc Hân, the bike | agreed 12/10 14:20, meeting confirmed 14/10 14:32 for 18:00 today at Công viên Gia Định, four checks, the declared mark, SN-24817, my message yesterday |
  | `d-bao` | Gia Bảo buys my shelf | in person, handed over and rated 5 on Monday, his thanks |
  | `d-xm4` | Quốc Bảo, the headphones | COD received 12/10, waiting for my rating, archived |

- `account.json`: Khánh Linh's phone "09•• ••• 812", address "12 Nguyễn
  Gia Trí, Phường 25, Bình Thạnh", payment "MoMo •• 0912", payout
  "Vietcombank •• 4821", score 386 and 90-day COD figures; the carriers Giao
  nhanh (1–2 ngày, 22.000 ₫) and Tiết kiệm (2–4 ngày, 16.000 ₫); the
  three standard meeting points for new deals (stage 1's Sảnh Landmark 81,
  Highlands Phan Xích Long, Trụ sở Công an phường 22) and the check-lists
  per kind (stage 1's six for a phone, with the listing's battery in "Pin
  từ …%" and that row dropped when the pool has no battery; Chi tiết đơn's
  four for a bike; four general ones for the rest: "Hàng đúng như ảnh trong
  tin", "Vết đã khai đúng như tin", "Dùng thử được", "Đủ phụ kiện như tin
  ghi"). Seeded deals keep the mockups' lists (the iPhone X has four).
- `sellers.json` gains Thanh Lý 24h (Mới, unverified, from 2026) and Quốc
  Bảo; `people.json` holds Minh Quang and Đức Huy. `p-xm4` moves to Quốc
  Bảo and is sold; `p-fixed` declares "Tróc sơn nhẹ ở gióng ngang" and
  `p-iphonex` "Xước nhẹ cạnh phải", so Listing detail shows the marks the
  orders show.
- `FakeWorld` gains the deals, each conversation's unread count, archive
  flag and warning, the account, the people, reports and my reputation
  events.
- The simulator gains the carrier and the people of the new deals:
  - after `PlaceCod`, the seller ships at 3.5 s (events "Đã lấy hàng tại
    Phú Nhuận", "Đến kho Bình Thạnh"; ETA the hour before to the hour after
    now) and the parcel reaches the door at 7 s ("Shipper đang giao"; the
    notification of ruling 2);
  - after `ShipParcel`, pickup at once ("Đã lấy hàng tại Bình Thạnh"; ETA
    tomorrow), the warehouse at 1.6 s ("Đến kho Phú Nhuận"), and the buyer
    receives at 3.2 s;
  - on a new deal, the seller accepts an offer after 2.4 s; with one way
    open it goes on as stage 1 (a meeting proposal at the first point),
    with both it says "Ok bạn, {giá} mình chốt. Bạn hẹn gặp hay đặt COD
    đều được nhé.";
  - the record replies of ruling 11;
  - a new message from the other side unarchives the conversation and adds
    to its unread count.
- The debug panel's jump gains every seeded order and status (ruling 11),
  and a switch for the simulated scanner.

## Navigation

| Route | Opened from |
|---|---|
| `InboxRoute` | the Tin nhắn tab (no longer a placeholder) |
| `OrdersRoute(side: String = "BUY")` | the Tôi placeholder's "Đơn mua" and "Đơn bán" |
| `OrderRoute(dealId: String)` | Đơn hàng, Chat's console, Thông báo, `shopnexus://order/{id}` |
| `CodCheckoutRoute(dealId: String)` | Chat's "Đặt COD" |

`OrderRoute`'s entry reads the deal and shows Chi tiết đơn, Đơn COD or Đơn
bán by path and side; for a seller's in-person order it replaces itself with
the Chat (ruling 8). `Navigator` gains `replace(route)`, which closes the top
screen and opens `route` with the push transition; Giao COD's "Xem đơn" and
the order router use it, so back from Đơn COD returns to Chat.

Stage 3 placeholders go to their screens: Listing detail's "Nhắn tin",
"Trả giá" and question chips start a deal; Người bán's chat button opens the
open deal with that seller, or a sheet "Nhắn về tin nào?" listing the
seller's listings on sale (64 dp photo, title, price), where a choice starts
a deal; the compare sheet's "Nhắn người bán" starts a deal on the picked
listing; Chat's attach button opens the Photo Picker; Home's COD slide
"Tìm hiểu" opens a sheet titled "COD xem hàng" with the COD buyer, refusal,
48-hour, over-limit and no-holding sentences; Thông báo's three stage 3 rows
open `OrderRoute` (the door row is posted by the simulator).

## Shared pieces

### Phase stepper and timeline

`PhaseStepper` (stage 1) takes the path and `phaseOf`: 40 dp in Chat, 32 dp
on Đơn hàng; its label is "Bước 3 trên 4: Xem và nhận", or "Đã xong cả 4
bước". The order pages' timeline is a `surfaceContainer` block with 28 dp
corners: the four phases as 40 dp icons joined by 2 dp vertical lines, each
with its label and time:

| Path and side | Labels |
|---|---|
| in person | "Chốt giá 2.300.000 ₫" · agreed; "Hẹn 18:00 · Công viên Gia Định" · confirmed; "Gặp, kiểm xe, quét mã" · the hand-over, or the meeting ("18:00 hôm nay"); "Đánh giá" · rated |
| COD, buyer | "Chốt 3.800.000 ₫, đặt COD" · placed; "Hoàng Nam gửi hàng" · pickup, or the deadline ("Trước 15:20 thứ Bảy"); "Xem và nhận" · received, "Đang giao", "Đang ở cửa" or "Đã từ chối"; "Đánh giá" · rated |
| COD, seller | "Đức Huy đặt COD 350.000 ₫" · placed; "Gửi cho bên vận chuyển" · pickup or the deadline; "Đức Huy xem và nhận" · received or "Đã từ chối"; "Đánh giá" · rated |

Past times use `momentLabel`. "Bên vận chuyển báo" lists the carrier events
newest first, each with its time ("09:40", or "12/10 09:40" on another day).

### Check-list and "Chưa kiểm xong"

Sparkle + "Kiểm tra khi gặp" (in person) or "Xem hàng" (COD) with the count
("0/4"), the check rows, "Đã khai trong tin" with each mark's close-up and
"Ảnh cận chụp trong app · 11/10", and the declared-marks sentence. Acting
with checks left opens "Chưa kiểm xong": "Còn {n} mục chưa kiểm. Đã trả tiền
thì ShopNexus không đòi lại được.", "Kiểm tiếp", which closes the dialog
and scrolls to the list, and "Vẫn quét" or "Vẫn nhận".

### Scanner

"Quét mã trên máy {người bán}", "Quét khi đã kiểm hàng và trả tiền. Mã ghi
nhận giao dịch đã diễn ra.", the 240 dp frame of white corners with its line,
and a check in `primaryContainer` for 700 ms on a read. The camera preview
fills the screen where the mockup draws the seller's photo at 40 %. CameraX
binds a preview and an analyzer; ML Kit reads QR codes only. The first open
asks for the camera permission; refused, the view says "Cần quyền camera để
quét mã." (new) with "Cho phép", which asks again, or "Mở cài đặt" once Android
stops asking. The simulated mode (tests, devices without a camera, the debug
switch) shows the seller's photo at 40 % and reads after 1.6 s, as stage 1.
Reduced motion stops the line.

### Record sheet and record card

"Ghi nhận sự cố": "Thêm ảnh" (the Photo Picker), "Chuyện gì xảy ra", sparkle
+ the neutral note, gavel + "ShopNexus không phân xử. {người bán} chọn tự
hoàn tiền hoặc từ chối; từ chối thì ghi nhận hiện trên hồ sơ của họ.", and
"Gửi ghi nhận", enabled with a photo and text. The note is stage 1's
sentence built from the declared marks, for every deal: the fake cannot read
what the person wrote, and the mockups' notes about brakes and the speaker
answer their prefilled text. Records the debug panel seeds carry the
mockups' text and note ("Một chân ghế bị lung lay, ngồi kêu cót két."). The
seller sees a record as the incident card on Đơn bán: "Ghi nhận của Đức
Huy", the text, the note and the declared-marks sentence.

### Rating

Five 48 dp stars, a radio group named "Đánh giá {người bán}", each "{n}
sao". Choosing one sends `Rate`; the money of the order is untouched.

## The screens

### Tin nhắn

The Tin nhắn tab, with the navigation bar and its badge (the unread total).
"Tin nhắn" in `headlineSmall` and "Tìm trong tin nhắn" (placeholder); chips
Tất cả, Mua, Bán, Chưa đọc ({n}); the rows, newest first: the 56 dp listing
photo (16 dp corners) with the person's 24 dp avatar ringed in `surface`, the
name and `inboxTime`, the title (with storefront and "Tin của bạn" for my
listings), the last message ("Bạn: …" when mine), the unread count in a
`primary` circle, and the tag (`surfaceContainerHigh`, 8 dp corners,
`labelMedium`): sell "10,6 tr", handshake "3,8 tr", schedule send "Chờ gửi",
check "650.000 ₫", sparkle "Nghi lừa đảo".

Rows swipe: past 10 dp the row moves over a backdrop, `secondaryContainer`
with a read icon to the right and `primaryContainer` with archive to the
left; past 96 dp the icon grows and letting go commits. Right toggles read
("Đã đánh dấu đã đọc", "Đã đánh dấu chưa đọc") and springs back; left slides
the row out, collapses it, and offers "Hoàn tác" with "Đã lưu trữ". Shorter
drags spring back; vertical drags scroll. TalkBack gets both as custom
actions.

A row opens its Chat and marks it read. Thanh Lý 24h's row opens the scam
sheet: "Có thể là lừa đảo", sparkle + "3 dấu hiệu", the signals ("Đòi chuyển
cọc ngoài app", "Tài khoản 2 ngày tuổi, chưa xác minh", "Giá thấp hơn 40% so
với tin tương tự"), "Chặn và báo cáo" (primary) and "Vẫn mở cuộc trò
chuyện" (text button, opens the Chat). Blocking reports the person for a
scam and removes the row with "Đã
chặn và báo cáo Thanh Lý 24h" and "Hoàn tác", which unblocks, withdraws the
report and puts the row back. Empty chips: "Chưa có tin nhắn nào.", "Bạn
chưa hỏi mua món nào.", "Chưa ai hỏi về tin của bạn.", "Bạn đã đọc hết tin
nhắn.", each with "Khám phá tin quanh bạn" (to Home).

### Chat

The stage 1 screen for any deal. The thread draws my messages on my side
whichever role I have; the app bar shows the other person; "Trang người bán"
in the menu shows only when the other person sells. The attach button sends
up to four photos from the Photo Picker as a photo item. Opening the screen
marks the conversation read, and so does a new message while it is open.

New console states, with the stage 1 layout (32 dp lead, the figure in
`displaySmall`, one icon line, 56 dp actions):

| State | Body | Actions |
|---|---|---|
| Choosing (buyer, both ways open) | handshake in `tertiaryFixed`, the price; the in-person and COD buyer sentences | "Hẹn gặp" (tonal, the "Hẹn gặp" sheet), "Đặt COD" (primary, Giao COD) |
| Order step (COD before receipt, either side; a seller's open record) | truck, or report for a record, the price; the order's Đơn hàng line | its Đơn hàng action ("Xem hàng", "Gửi hàng", "Trả lời", "Xem đơn") as primary |
| Selling (seller, negotiating) | storefront, the listed price; "Giá bạn đăng" | none |
| Seller meeting (seller, in person, before the hand-over) | event · the meeting | none |
| Ended | event busy or undo, the price; the order's line | "Xem đơn" (tonal) |

The stage 1 labels take the noun: "Kiểm xe 0/4", "Xe có vấn đề?". A
received COD parcel goes to the stage 1 Received state; the seller's console
after the hand-over is stage 1's Done without "… có vấn đề?". On a deal
with no counter, the first state shows the listed price and "Đồng ý" agrees
to it. Each order step adds
an event to the thread (truck "Đã đặt giao COD · Giao nhanh 22.000 ₫", truck
"Hoàng Nam đã gửi hàng", door "Shipper đang ở cửa", undo "Bạn đã từ chối
nhận", event busy "Đã hủy hẹn", truck "Bạn đã gửi hàng").

### Giao COD

No navigation bar. Back and "Giao COD". The item with the seller and the
agreed price (handshake · "Đã chốt" in `tertiary`); "Giao đến" with the
address, "Khánh Linh · 09•• ••• 812" and "Đổi"; "Vận chuyển" as two radio
rows (Giao nhanh 1–2 ngày 22.000 ₫, selected; Tiết kiệm 2–4 ngày 16.000 ₫);
"Tiền" with "Trả bây giờ / Phí ship, trả cho bên vận chuyển" and the fee,
"Trả khi nhận / Cho shipper, sau khi xem hàng" and the price, "MoMo •• 0912"
with "Đổi", and the COD buyer, refusal and 48-hour sentences; "COD của bạn:
1/5 đơn đang mở sau đơn này" with its bar and "Xem quyền của bạn". The
docked bar: "Trả bây giờ" with the fee, and "Đặt COD". When `codSlots` does
not fit, the line reads "COD của bạn: đã đủ 5/5 đơn đang mở" (new) and "Đặt
COD" is disabled. Placing it shows the milestone (Cookie9Sided, trust, truck,
112 dp): "Đã đặt giao COD", "Hoàng Nam có 48 giờ để gửi hàng. Bạn xem máy
rồi mới trả.", and "Xem đơn", which replaces the screen with Đơn COD. Back
returns to Chat.

### Đơn hàng

No navigation bar. Back and "Đơn hàng"; a connected toggle group "Mua · 2"
(shopping bag) and "Bán · 2" (storefront); `OrdersRoute("SELL")` opens on
Bán. Each order is a `surfaceContainer` block with 28 dp corners: the 56 dp
photo, the title in `titleSmall`, the person's 20 dp avatar and name with the
way (two people · Gặp mặt, or truck · COD), the price with its unit one size
down; the 32 dp stepper; the line; the action from the table. The photo and
title open the order ("Chi tiết đơn {title}"); the chat button is "Nhắn
{người}". Rating in place sends `Rate` and the line turns to "{n} sao cho
{người}". Empty: ruling 15.

### Chi tiết đơn

No navigation bar. Back, "Chi tiết đơn", the menu with "Trợ giúp". The hero;
the timeline; while the meeting is ahead, the check-list block; the item row
(64 dp photo, title, price; opens Listing detail) and the seller row (avatar,
name with the verified icon, rating, "· 9 đã bán", "Nhắn Ngọc Hân"); "Gặp
mặt": the place with "Phú Nhuận · cách bạn 2,1 km" and "Chỉ đường", the time
with "Đổi" (the "Hẹn gặp" sheet; the change goes to the seller as in Chat),
or "Chưa hẹn gặp" with "Hẹn gặp" (new) before there is a meeting;
"Tiền": "Giá đã chốt", "Trả trực tiếp cho Ngọc Hân / Tiền mặt hoặc chuyển
khoản khi gặp", the in-person, after-paying and no-holding sentences; "Mã
đơn" SN-24817 with "Sao chép mã đơn" and "Chốt lúc 12/10, 14:20". The bar
follows the status table.

"Hủy hẹn" asks "Hủy hẹn?" with "Hủy sau khi đã chốt giá bị trừ 20 điểm uy
tín." (or "Hủy trong 2 giờ trước giờ hẹn bị trừ 30 điểm uy tín.", new),
"Giữ hẹn" and "Hủy hẹn"; then "Đã hủy hẹn với Ngọc Hân". "Quét mã của Ngọc
Hân" checks the list first, then opens the scanner. "Gửi ghi nhận" shows
"Đã gửi ghi nhận cho Ngọc Hân"; "Rút ghi nhận" withdraws it with "Đã rút ghi
nhận" and returns to the state before the record. "Sao chép mã đơn" copies
and, on Android 12, says "Đã sao chép mã đơn SN-24817" (Android 13 and later
show their own confirmation). "Chỉ đường" opens `geo:0,0?q=` the place and
area, or says "Chưa có ứng dụng bản đồ" (new).

### Đơn COD

No navigation bar. Back and "Đơn COD". The hero; at the door, the check-list
block ("Xem hàng", the four checks for the phone, "Xước nhẹ cạnh phải") with
the refusal and after-paying sentences; the timeline; "Bên vận chuyển báo";
the item and seller rows; "Tiền": "Đã trả phí ship 22.000 ₫ / MoMo · hôm qua
20:16 · không hoàn" (the placement time), "Trả khi nhận 3.800.000 ₫ / Cho
shipper, sau khi xem hàng", the pay-the-shipper and no-holding sentences.

"Nhận · trả 3,8 tr" checks the list first, then receives. "Từ chối nhận"
asks "Từ chối nhận?": "Máy quay về Hoàng Nam. Bạn mất 22.000 ₫ phí ship,
không mất gì khác. Từ chối nhận được tính vào chỉ số 90 ngày của bạn.", the
optional reason chips "Có vết không khai", "Khác mô tả", "Không muốn nữa",
"Quay lại" and "Từ chối nhận"; then "Đã báo shipper trả máy về Hoàng Nam".
While the page is open, the seller's and carrier's steps show as snackbars:
"Hoàng Nam đã gửi hàng", "Shipper đang ở cửa".

### Đơn bán

No navigation bar. Back and "Đơn bán". The hero; while it is to ship, "Gửi
hàng" with three numbered steps: "Chụp hàng trước khi đóng gói" / "Ảnh có dấu
thời gian, dùng khi người mua mở ghi nhận" and "Chụp hàng" (the camera; the
step turns to a check and a thumbnail with "Chụp trong app · vừa xong"),
"Ghi mã lên gói hàng" with SNX 8841 2207 and "Hiện mã QR" (the sheet "Mã gửi
hàng", "Shipper quét mã này khi lấy hàng", the code drawn by ZXing),
"Cách gửi" with "Shipper tới lấy · 14:00–18:00 hôm nay" (selected) and "Mang
ra bưu cục · cách 0,4 km"; the seller's 48-hour sentence. With a record, the
incident card. Then the timeline, "Bên vận chuyển báo", "Tiền" ("Tiền hàng
COD 350.000 ₫", "Phí ship người mua đã trả 22.000 ₫", "Vietcombank •• 4821 /
Tài khoản nhận tiền COD", the payout, return-leg and no-holding sentences),
the buyer row ("Đức Huy / Phú Nhuận · giao COD", "Nhắn Đức Huy") and "Mã gửi
hàng".

"Xác nhận gửi" says "Đã báo bên vận chuyển. Shipper tới lấy 14:00–18:00" (or
"… Mang ra bưu cục trước 18:00 thứ Sáu", new, for drop-off). "Tự hoàn" opens
"Tự hoàn cho Đức Huy" with the `refundOptions` radios (the middle one
selected, the last labelled "Hoàn toàn bộ"), "Bạn chuyển khoản trực tiếp cho
Đức Huy; ShopNexus không giữ tiền. Tự hoàn được cộng 15 điểm uy tín." and
"Đã chuyển khoản hoàn"; then "Đã báo Đức Huy bạn hoàn 100.000 ₫". "Từ chối"
asks "Từ chối ghi nhận?" with "ShopNexus không phân xử. Ghi nhận và câu trả
lời của bạn sẽ hiện trên hồ sơ của bạn.", "Quay lại" and "Từ chối".

## State and errors

As in stages 1 and 2: one ViewModel per screen with `StateFlow` and
`onEvent`, one-off effects through a `Channel`, a failed read with "Thử lại",
a failed command with "Chưa gửi được. Thử lại" and its optimistic change
rolled back. A step that moves money (placing COD, receiving, refusing, a
refund) never shows as done before its command succeeds; its button shows
progress meanwhile. Countdowns and "Vừa xong" follow a clock that ticks each
minute. The chosen carrier, ship method, packing photo, record draft, open
sheet and inbox chip survive recreation through `SavedStateHandle`. Read
marks, archives, blocks and every order step persist in the fake for the
session.

## Accessibility

Touch targets of at least 48 dp; content descriptions on every icon-only
control ("Hủy hẹn", "Sao chép mã đơn", "Chỉ đường", "Hiện mã QR", "Nhắn
{người}"); inbox rows with custom actions for read and archive; the hero as a
polite live region; the stepper's step label; the stars as radios; the toggle
group, chips and radios with their state; section titles as headings.
Reduced motion turns off the swipe icon's growth, the row collapse, the
milestone spring and the scan line. Every screen and new component is
checked at font scale 1.3 with `assertNoClippedText`.

## Testing and acceptance

- JVM unit tests for every rule in the rules table, the engine's new
  commands and refusals, the fakes, and the simulator's new timings on
  virtual time.
- ViewModel tests with Turbine for each new screen and Chat's new states.
- Roborazzi screenshots of every new component and every state of every
  order page, Tin nhắn's chips and empty states, the scam sheet and Giao
  COD's two moments, with light, dark, Material You and font scale 1.3 for
  each screen's main state.
- Robolectric Compose UI tests for each screen's controls and three walks:
  Tin nhắn → Hoàng Nam → Đặt COD → Giao COD → Đặt COD → Xem đơn → (virtual
  time) the door → Nhận → rating → Đơn hàng shows it reviewed; Tôi → Đơn bán
  → the stool → Chụp hàng → Xác nhận gửi → Đức Huy đã nhận hàng; Thông báo
  → Ngọc Hân's meeting → Chi tiết đơn → the checks → scan (simulated) →
  rating → "Xe có vấn đề?" → record → declined.
- Stage 2 tests and screenshots that rulings 2, 6 and 16 change (the unread
  count, Home's grid without the sold headphones, Đức Trí's listings, the
  meeting notification) are updated with those rulings named in the commit.
- `./gradlew check verifyRoborazziDebug` runs everything.

Stage 3 is done when:

1. Every screen walks on the API 36 emulator with no dead control; controls
   for later stages open their placeholder; the scanner reads a real QR code
   on a device.
2. Every screen state has a screenshot, reviewed side by side with its
   mockup, and every difference is one of the rulings above.
3. Every rule in the rules table has unit tests.
4. Every screen lays out at font scale 1.3 without clipping.
5. The mockup checker still passes for all 31 screens.

## Out of scope

Real payments (MoMo), a real carrier, real AI (the scam signals, record notes
and check-lists are fixture data), the seller's code screen and seller
bargaining and record replies for in-person orders (stage 4), an address
book, payment methods, help, inbox search, an archive view, push
notifications, and the Điểm uy tín screen (stage 5).
