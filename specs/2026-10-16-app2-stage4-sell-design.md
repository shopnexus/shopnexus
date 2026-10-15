# Design: app2 stage 4, Bán

Date: 2026-10-16
Status: draft. The user's standing instruction is to keep building, so this
spec goes straight to a plan; the decisions marked as rulings are the ones to
review.

## Goal

Stage 4 builds the seller's side of the app on stages 1 to 3: Đăng tin from
photos, Quay video and Kiểm tra tin for a listing drafted from a video, Tin
của bạn with its sheets, Gói người bán, and the seller's half of a deal that
stage 3 left out (answering an offer, agreeing a meeting, showing the
hand-over code, answering a record on an in-person order). The screens are
designed in `app2/.superdesign/` (`design-system.md`, `tools/build_sell.py`,
`build_sell_video.py`, `build_sell_review.py`, `build_listings.py`,
`build_plans.py`, `common.py`); `app2/.superdesign/stage4-digest.md` lists
their data, strings and interactions with source lines. The deal model is
`app2/mohinh.md`.

Earlier decisions hold: Android only, Kotlin, Compose with material3
1.5.0-beta01, Navigation 3, Hilt, ViewModel + `StateFlow`, fake repositories
over one `FakeWorld`, the simulator playing the other side, CameraX for the
camera, JVM tests with Robolectric and Roborazzi at a zero-pixel threshold.
The repository interfaces stay the API contract for the Go server.

## Rulings on the mockups

The mockups fill every form from fixed values and store nothing. The app
follows the deal model and `design-system.md`:

1. Drafts are stored. "Lưu nháp", the gate's "Để sau" and "Xác minh ngay",
   and "Lưu nháp" in the close dialog save the draft in the fake; Tin của
   bạn's Nháp lists every draft, newest first, and "Tiếp tục" opens it where
   it was made (Đăng tin for photos, Kiểm tra tin for a video). The world
   starts with the mockup's draft: the iPhone 11 from photos, three photos,
   no price, the AI mark not answered. A form with changes since its last
   save asks before closing (rulings 13 and 14); the mockups close without
   asking.
2. The posted listing is the one the seller made. Tin của bạn shows its own
   title, price, photos and counts, where `#posted` and `#posted-video`
   always add the fixture at 4.500.000 ₫. It leads Đang bán with "Vừa đăng"
   and its draft leaves Nháp.
3. The two flows read two inputs. A photo cannot show the battery or the
   seller's words, so the photo read fills "iPhone 11 64GB Trắng, máy zin"
   with an empty battery and the photo description ("… Kèm cáp sạc."), and
   the video read fills "iPhone 11 64GB Trắng, pin 81%", battery 81 and the
   spoken description ("… Có thương lượng."). Both forms offer the same
   categories (ruling 9). The mark reads "Xước nhẹ ở mặt lưng" on both forms
   and "Xước nhẹ ở lưng" on Quay video's chip and Kiểm tra tin's finding,
   where space is short.
4. Kiểm tra tin runs Đăng tin's checks (`design-system.md` says the two post
   the same way): a title of 1 to 70 characters with its counter in the
   sheet, a price of at least 10.000 ₫, every mark the model saw declared or
   dismissed, and at least one way to hand over. The mark the seller spoke
   about counts as declared, and its row gets "Bỏ vết này" as on Đăng tin;
   removing a mark the model saw dismisses it with the "Đã bỏ qua …"
   snackbar.
5. "Thông số" on Kiểm tra tin opens a sheet with Đăng tin's fields
   (Dung lượng, Màu, Pin (%)) where the mockup edits one line of text, so
   both forms keep the same values. "Cách giao" opens a sheet with Đăng
   tin's two checkboxes; the mockup's row has no control.
6. Photos follow `design-system.md`: "Chụp ảnh" is tonal
   (`secondaryContainer`) and "Chọn ảnh" primary. "Chụp ảnh" takes a photo
   with the camera app, as stage 3's "Chụp hàng" does, and the photo counts
   as taken in the app with its capture time; "Chọn ảnh" uses the Photo
   Picker. Library photos are allowed and counted ("2/3 ảnh chụp trong
   app"), as in the mockup. The "Thêm ảnh" tile opens a menu with both;
   "Dùng ảnh mẫu" is a prototype aid and is not built. Picked photos are
   named "Ảnh {n}" in their remove labels ("Xóa ảnh Ảnh 2").
7. Identity. Khánh Linh starts unverified, as Tôi and Hoàn thiện hồ sơ show
   in stage 5. Posting a new listing needs a verified identity; editing her
   listings does not. Until stage 5 builds eKYC, the banner's "Xác minh"
   and the gate's "Xác minh ngay" open the placeholder "Xác minh danh tính"
   (stage 5), and the debug panel has a switch "Đã xác minh danh tính". When
   the person becomes verified while a form is open, the banner goes and
   the snackbar "Đã xác minh. Bạn có thể đăng tin" shows. The gate sheet's
   title is "Xác minh để đăng tin", which the mockup leaves out of the
   sheet's accessible name.
8. Quay video uses the camera. CameraX shows the feed full-bleed and grabs a
   frame every 1.5 s; stopping keeps eight frames spread over the take,
   which become Kiểm tra tin's frames and the listing's photos. The model's
   cues (prompts, captions, chips) follow the mockup's timeline over the
   first 10.6 s; no speech is recorded and no video file is kept. A take
   runs until the seller stops it or reaches 30 s, the length the ring
   measures; the mockup's stop at 12.5 s is a prototype aid. "Đèn flash"
   turns the torch on and shows only on a camera with one; the mockup's
   inert flip icon becomes "Đổi camera". "Chọn video có sẵn" picks a video
   with the Photo Picker, and the frames come from it at eight even times;
   those photos count as library photos and the source line reads "Ảnh lấy
   từ video trong thư viện" (new). The simulated mode (tests, devices
   without a camera, the debug switch) shows the mockup's five crops and
   yields its eight frames.
9. Categories come from the catalog. "Danh mục" opens a sheet grouped by the
   eight categories, each listing its subcategories and "Khác", and a last
   group "Khác". The model suggests "Điện thoại › iPhone". The mockup's
   "Điện thoại › Samsung", "Hãng khác", "Máy tính bảng" and "Phụ kiện điện
   thoại" become the catalog's "Điện thoại › Android", "Điện thoại ›
   Máy tính bảng" and "Điện thoại › Phụ kiện". Dung lượng and Pin (%) show
   for iPhone, Android and Máy tính bảng; Màu shows for every category.
   Dung lượng offers 32, 64, 128, 256 and 512 GB.
10. Askers come from the deals. "Bán cho ai?" lists the people with a deal on
    the listing, newest first, each with what they did: "Trả giá 1,8 tr"
    with an open offer, "Đặt COD hôm qua" with a placed parcel, "Hẹn gặp thứ
    Năm" with a meeting, else "Hỏi hôm nay" from their first message. The
    guitar lists Minh Quang ("Hỏi hôm nay"), whose conversation is in Tin
    nhắn; the mockup's Minh Anh and Đức Huy appear in no conversation. The
    "Người hỏi" count is the number of those deals.
11. "7 ngày qua" sums the last seven days of the listings on sale: views and
    saves are kept per listing for the week and in total, askers are the
    deals started in the week. The world starts at 55 views, 2 askers and 3
    saves, where the mockup's 214, 9 and 17 exceed what its cards hold.
12. A sale follows the deal. A listing whose deal is handed over (a parcel
    received or a meeting recorded) moves to Đã bán by itself, with the buyer
    and, once given, their stars; the shelf is Gia Bảo's 5 stars from
    Monday. "Đánh dấu đã bán" records a sale made elsewhere: a ShopNexus
    buyer is invited to rate and the simulator's buyer rates 5 stars after 4
    s; "Người ngoài ShopNexus" gets no rating line. The sold card shows the
    buyer's avatar and stars, as `design-system.md` asks. A listing with an
    order under way (the stool) is reserved: it shows the order row, and its
    menu holds "Sửa tin" and "Ẩn tin" only, so it cannot be marked sold,
    boosted or deleted while its buyer waits.
13. "Sửa tin" opens Đăng tin filled from that listing; the mockup opens the
    iPhone 11 for every listing. The app bar reads "Sửa tin" (new), the
    docked buttons are "Xem trước" and "Lưu" (new), there is no "Lưu nháp",
    banner, gate or AI read, and saving closes the screen with the card
    changed. Closing with changes asks "Bỏ thay đổi?" with "Tin giữ như
    trước khi sửa.", "Ở lại" and "Bỏ" (new). Changes reach the listing only;
    an order already placed keeps what it was agreed on.
14. Closing a new or resumed form, by "Đóng" or by back, with changes since
    its last save asks "Lưu nháp tin này?" with "Nháp nằm trong Tin của bạn,
    đăng tiếp lúc nào cũng được.", "Bỏ" and "Lưu nháp" (new); a form with no
    photo and no text closes at once.
15. "Đăng lại" opens Đăng tin as a new listing copied from the sold one
    (photos, title, category, condition, marks as declared, specs,
    description, price, offers and ways); posting it passes the checks and
    the gate, and the sold card stays.
16. A draft's delete dialog reads "Xóa nháp này?" with "Ảnh và nội dung nháp
    sẽ mất." (new), matching its menu item "Xóa nháp". Every overflow button
    names its listing, the posted one included.
17. A plan's boosts are used first. With boosts left this month, the boost
    sheet's payment row reads "Gói Plus · còn 4 lượt đẩy tháng này" (new),
    each day counts one boost ("1 lượt", "3 lượt", new), and the button
    reads "Đẩy tin · 1 lượt" (new); with none left the sheet charges MoMo
    as designed. A boost runs for its days; while it runs the card reads
    "Đẩy {n} ngày" and leads Đang bán.
18. Gói người bán's back returns to the screen that opened it, Tôi or the
    boost sheet's Tin của bạn. Going back to Cơ bản asks "Xác nhận gói" with
    "Gói Cơ bản · Miễn phí" and "Gói đang dùng chạy hết tháng đã trả." (new),
    without the payment row and the renewal sentence. "2 người cùng quản lý
    tin" uses `manage_accounts`, since `design-system.md` keeps the two
    people icon for meeting in person.
19. The previews put the seller's district where buyers see a distance: "Đã
    dùng · Bình Thạnh". The preview card's image is named by its title.
20. Empty panes name what is missing and offer one action, as
    `design-system.md` asks: Đang bán and Nháp offer "Đăng tin", Đã bán
    offers "Xem tin đang bán".
21. A take under 3 s resets the record button's label to "Bắt đầu quay" and
    clears the chips it showed.
22. "Đổi" on the area opens the placeholder "Khu vực", as Home's area row
    does. "Bản thiết kế …" footers and "Bản mẫu …" snackbars are not built.
23. The seller's half of a deal, which stage 3 moved here (stage 3 ruling
    8), is built from the buyer's pieces: the seller answers an offer in
    Chat ("Đồng ý" or "Trả giá"), agrees or moves a meeting the buyer
    proposed, shows the hand-over code for the buyer to scan, and answers a
    record on an in-person order. A seller's in-person order opens "Đơn bán"
    for that path (new) where stage 3 opened its Chat.
24. Someone asks about a new listing. Eight seconds after a listing is
    posted, Thảo Vy (new) writes "Món này còn không bạn?" and, when offers
    are on, offers 90 % of the price rounded down to 100.000 ₫ four seconds
    later with "Bớt chút được không bạn?". Her deal then goes on with the
    simulator (Fake data), so a posted listing can be sold end to end.

## Scope

| Built in stage 4 | Opens a placeholder |
|---|---|
| Đăng tin: the three states, photos from the camera and the Photo Picker, the AI read, every field, marks, prices, ways to hand over, preview, draft, checks, gate, posting, done | "Xác minh", "Xác minh ngay" (stage 5), area "Đổi" |
| Sửa tin and Đăng lại on the Đăng tin form | |
| Quay video: camera feed, torch, camera switch, take, cues, frames, gallery video, the exit dialog | |
| Kiểm tra tin: reading, the draft rows and their sheets, frames, added photos, preview, draft, checks, gate, posting, done | "Xác minh ngay" (stage 5) |
| Tin của bạn: stats, panes, cards, price cut, order row, boost, edit, mark sold, hide, delete, repost, posted arrival | |
| Gói người bán: plans, confirmation, the current plan | |
| The seller's half of a deal: offers, meetings, the hand-over code, records on in-person orders, Đơn bán for in-person orders | |
| Home's FAB, Tôi placeholder links "Tin của bạn" and "Gói người bán", my listings' item rows | |

## Modules

| Module | Holds | May depend on |
|---|---|---|
| `:feature:sell` (new) | Đăng tin, Quay video, Kiểm tra tin, and their parts: the photo row, the AI line, mark rows, the price block, the delivery block, the category sheet, the spec fields, the edit sheets, the preview sheet, the gate sheet, the done screen, the close dialogs | `:core:*` |
| `:feature:listings` (new) | Tin của bạn and its sheets, Gói người bán | `:core:*` |
| `:feature:orders` | grows Đơn bán for in-person orders and the code sheet | `:core:*` |
| `:feature:deal` | Chat's seller console states and the counter sheet | `:core:*` |
| `:core:ui` | the camera package grows a frame grabber, a torch and a lens switch | `:core:designsystem`, `:core:data`, `:core:navigation` |
| `:core:designsystem` | grows the filled field with label, counter and error, the switch row, the checkbox row, the empty pane and the step pill; the listing card takes a meta line for previews | |

New Material Symbols join `symbols.txt` and the generated font.

## Domain model and API contract (`:core:model`)

Changed and new types, all `@Serializable`.

- `ListingDraft` replaces stage 1's: `id` (`DraftId`), `origin` (PHOTOS,
  VIDEO), `photos` (`Photo`), `video` (`VideoTake`: the frames, the picked
  frame indexes, seconds, from the library or not), `title`, `category`
  (`CategoryRef`: the category key and subcategory name, or "Khác"),
  `condition`, `aiMarks` (`AiMark`: text, close-up, decision), `marks` (the
  seller's own `DeclaredMark`s), `storage`, `color`, `battery`,
  `description`, `price`, `priceSource` (SPOKEN, TYPED), `allowOffers`,
  `paths`, `aiFields` (the fields still carrying the sparkle), `editing`
  (the listing "Sửa tin" changes), `updatedAt`.
- `PhotoReading`: the draft values the model read, the mark it saw, the
  estimate (`PriceRange` low and high) and the two `PriceSuggestion`s (kind
  FAST or MARKET, price, "~2 ngày").
- `VideoReading`: how many frames are read, the kept frame indexes, the
  `Finding`s (icon, text) so far, and the draft once the reading ends.
- `TakeCue`: milliseconds into the take, kind (PROMPT, CAPTION, CHIP), text.
- `SellContext`: verified, the area ("Bình Thạnh, TP.HCM") and district
  ("Bình Thạnh"), listings on sale and the cap, the categories.
- `OwnListing`: the `Listing`, hidden, views and saves (total and this
  week), `boostedUntil` and its days, the model's `PriceInsight` and
  suggested price, and a `Sale` made elsewhere.
- `Sale`: the buyer (`UserId`, or null for "Người ngoài ShopNexus"), when,
  their stars, and the deal when it came from one.
- `MyListings`: the week's views, askers and saves, and the three panes as
  cards: `LiveCard` (summary, counts, age or boost, hidden, the price-cut
  suggestion, the order row, the askers), `DraftCard` (photo, title, photo
  count, price, whether it needs verification) and `SoldCard` (summary,
  buyer, when, stars, pending).
- `SellerPlan`: key (BASIC, PLUS, SHOP), name, monthly price, features (icon,
  text), boosts a month. `PlanPage`: the plans, the current one, the
  payment method. `BoostSheet`: the two offers (days, fee), the payment
  method, the plan and its boosts left.
- `DealCommand`: `SendOffer` from the seller is a counter, `AcceptCounter`
  from the seller accepts the buyer's open offer, `ProposeMeeting` and
  `ConfirmMeeting` work from either side on the other side's proposal.
- `NotificationTarget` gains `MyListings`.

Repository interfaces in `:core:data`:

| Interface | Reads | Commands |
|---|---|---|
| `SellRepository` (new) | `context()`, `draft(id)`, `takeScript()` | `readPhotos(photos)` returning a `PhotoReading`, `readVideo(take)` as a flow of `VideoReading`, `saveDraft(draft)` returning the id, `post(draft)` returning the listing id, `saveListing(id, draft)` |
| `MyListingsRepository` (new) | `listings()`, `boostSheet(id)` | `setPrice(id, price)` returning the old price, `setHidden(id, on)`, `boost(id, days)`, `markSold(id, buyer)`, `unmarkSold(id)`, `delete(id)`, `deleteDraft(id)` |
| `PlanRepository` (new) | `plans()` | `choose(key)` |
| `DealRepository` (grows) | | `handoverCode(id)` returning the text the seller's QR code shows |

`post` refuses a draft that fails the checks, an unverified person and a
person at the listing cap. `handoverCode` issues a one-time code; the fake
lets the simulator's buyer scan it.

## Selling rules (`:core:domain`)

| Function | Rule |
|---|---|
| `postProblems(draft, context)` | the problems in the order the form shows them: TITLE_EMPTY, PRICE_EMPTY, PRICE_LOW (under 10.000 ₫), MARK_PENDING, NO_PATH; then CAP when the listings on sale reach the cap, UNVERIFIED for a new listing |
| `codAllowed(price)` | at most 5.000.000 ₫ (`COD_LIMIT`); above it a draft's paths drop COD |
| `priceFromInput(text)` | the digits as `Vnd`, or null; "4.500.000 ₫" back for display |
| `estimateLabel(range)` | "Giá tham khảo", then the low and high in short millions joined by an en dash with a space each side, then "tr ₫" (the mockup's 4,4 and 5,1) |
| `photoSourceLine(photos)` | "Cả 3 ảnh chụp trong app", "Ảnh chụp trong app" for one, "{app}/{total} ảnh chụp trong app" with library photos |
| `ageLabel(postedAt, now)` | "Vừa đăng" under an hour, "{n} giờ" under a day, else "{n} ngày" |
| `askerLine(deal, now, zone)` | ruling 10; the day is `dayLabel` with a lower-case first letter |
| `openOrder(views, listing)` | the deal on the listing that is an order and not handed over or ended |
| `orderNote(status, view, now, zone)` | the order row on a card: TO_SHIP "Đơn COD · gửi trước 18:00 thứ Sáu", SHIPPING "Đơn COD · đang giao", ARRANGING "Đơn gặp mặt · chờ bạn đồng ý hẹn" or "… chờ {người} đồng ý", WAITING "Đơn gặp mặt · 18:00 thứ Năm", RECORD_OPEN "Ghi nhận sự cố · trả lời trong 3 ngày" (all new except the first) |
| `soldBy(listing, deals)` | the handed-over deal on the listing, else its `Sale` (ruling 12) |
| `weekStats(listings, deals, now)` | ruling 11 |
| `boostOffers(plan, used)` | 1 ngày 15.000 ₫ and 3 ngày 35.000 ₫, or boosts while the plan has them (ruling 17) |
| `planButton(selected, current)` | "Đang dùng Cơ bản" (disabled), "Dùng Plus · 49.000 ₫/tháng", "Về gói Cơ bản" |
| `counterRange(offer, listed)` | a seller's counter is above the buyer's offer and below the listed price |
| `DealConsole.state` | the seller states in Chat below |

The engine refuses a counter outside its range, an accept with no open
offer, a seller's meeting step on a COD deal, and a confirmation of one's
own proposal.

## Seller order states

Đơn bán for an in-person order (new; Đơn bán's layout with the in-person
parts of Chi tiết đơn):

| Status | Hero (shape, fill, icon, title) | Facts and feeling | Bar |
|---|---|---|---|
| ARRANGING | Cookie9Sided, `tertiaryFixed`, handshake, "Đã chốt giá" | event · the meeting and "chờ bạn đồng ý" or "chờ Thảo Vy đồng ý", or "Chưa hẹn gặp" | "Đổi giờ" (tonal), "Đồng ý hẹn" (primary) when the buyer proposed |
| WAITING | Cookie9Sided, `primaryContainer`, event, "Hẹn 18:00 thứ Năm" | location · the place | "Hủy hẹn" (tonal icon), "Hiện mã giao dịch" (primary) |
| MET | SoftBurst, `primaryContainer`, QR, "Giao dịch đã ghi nhận" | payments · Đã nhận 4.000.000 ₫ tại chỗ; "Món đồ cũ đã có chủ mới." | none |
| REVIEWED | Flower, `secondaryContainer`, star, "Gia Bảo đánh giá 5 sao" | payments · Đã nhận 650.000 ₫ tại chỗ; "Cảm ơn bạn đã giữ chợ tử tế." | none |
| CANCELLED | Circle, `surfaceContainerHighest`, event busy, "Đã hủy hẹn" | trending down · −20 điểm uy tín (or −30) when the seller cancelled | none |
| RECORD_* | as Đơn bán by COD | | as Đơn bán by COD |

On Đơn hàng's Bán side, ARRANGING has chat and "Đồng ý hẹn" (new) when the
buyer proposed, WAITING chat and "Hiện mã" (new), and RECORD_OPEN chat and
"Trả lời"; each opens the order.

Chat's seller console, with the stage 1 layout:

| State | Body | Actions |
|---|---|---|
| Selling, the buyer's offer open | sell in `tertiaryFixed`, the offer; "Giá bạn đăng 1.900.000 ₫" | "Trả giá" (tonal, the counter sheet), "Đồng ý" (primary) |
| Selling, my counter open | sell, the counter; "Chờ Thảo Vy trả lời" | none |
| Seller arranging | event, the meeting; "chờ bạn đồng ý" or "chờ Thảo Vy đồng ý" | "Đổi giờ" (tonal, the "Hẹn gặp" sheet), "Đồng ý hẹn" (primary) when the buyer proposed |
| Seller meeting | event, the meeting; the place | "Hiện mã giao dịch" (primary) |

The counter sheet is the stage 1 offer sheet titled "Trả giá" with the
seller's range and two presets from it, a third and two thirds of the way
from the offer to the listed price, rounded to 50.000 ₫.

The code sheet "Mã giao dịch": the QR code of `handoverCode` (200 dp, as
stage 3 draws it), "Đưa mã cho Thảo Vy quét sau khi bạn ấy kiểm hàng và trả
tiền." (new) and the order number. When the buyer scans, a check in
`primaryContainer` shows for 700 ms, the sheet closes and the snackbar says
"Giao dịch đã ghi nhận".

## Fake data (`:core:data`)

- `my-listings.json` (new) holds Khánh Linh's listings with full data, the
  same ids the deals use:

  | Id | Listing | State |
  |---|---|---|
  | `my-guitar` | Đàn guitar Yamaha F310, 1.900.000 ₫, Khác, Đã dùng, both ways, offers on | on sale 12 days; 86 views (31 this week), 5 saves (2); Cao hơn 12 %, suggested 1.700.000 ₫ |
  | `my-stool` | Ghế đôn gỗ cao, 350.000 ₫, Nội thất › Khác, Đã dùng, both ways | on sale 5 days; 24 views (24), 1 save (1); Đức Huy's COD order |
  | `my-shelf` | Kệ gỗ nhỏ 3 tầng, 650.000 ₫, Nội thất › Tủ, kệ | sold through `d-bao` |
  | `my-books` | Combo 9 sách khởi nghiệp, 450.000 ₫, Khác | sold elsewhere to Thu Trang on 28/9, 5 stars |

  and the iPhone 11 draft of ruling 1 (updated yesterday 21:40). Each
  listing gets a short description and the mockups' photo; the declared
  marks and specs are new.
- `account.json` gains `verified` (false), `plan` (BASIC), the boosts used
  this month (0), the area, the three plans and the two boost offers.
  `people.json` gains Thu Trang and Thảo Vy (Phú Nhuận, no photo).
- The photo read returns the photo-flow values after 1.8 s; the video read
  emits the mockup's timeline (a frame every 300 ms, the kept frames 0, 2,
  3 and 4 after the last, findings at 0.5, 1.05, 1.6 and 2.15 s, the draft
  at 3.3 s); the take script is the mockup's table.
- The simulator gains:
  - after `post`: views of 5 at 4 s and 12 at 8 s, then ruling 24's
    question at 8 s (unread, and a Thông báo row "Thảo Vy hỏi về iPhone 11"
    that opens the Chat) and her offer at 12 s;
  - a buyer answers a counter by accepting it after 2.4 s;
  - once a price is agreed, the buyer goes on after 2.4 s: COD when the
    listing offers it and the price allows it (she places it with Giao
    nhanh, and the stage 3 carrier takes over after the seller ships),
    otherwise a meeting proposal for tomorrow 18:00 at the first meeting
    point;
  - a buyer scans the hand-over code 3 s after it is issued;
  - a buyer rates 5 stars 4 s after a hand-over or a received parcel, on
    deals where Khánh Linh sells, and 4 s after a sale is marked to them;
  - a buyer whose meeting the seller moves accepts it after 2.4 s.
- The debug panel gains the identity switch, `d-bao`'s jumps through the
  in-person seller states (ARRANGING, WAITING, MET, REVIEWED, CANCELLED,
  RECORD_OPEN, RECORD_REFUNDED, RECORD_DECLINED), and the scanner switch
  becomes "Camera giả lập" for the scanner and Quay video.

## Navigation

| Route | Opened from |
|---|---|
| `SellRoute(draftId: String? = null, editId: String? = null, repostId: String? = null)` | Home's FAB "Chụp ảnh" and "Tiếp tục nháp", Tin của bạn's add menu "Chụp ảnh", a photo draft's "Tiếp tục", "Sửa tin", "Đăng lại" |
| `SellVideoRoute` | Home's FAB "Quay video", Tin của bạn's add menu |
| `SellReviewRoute(frames: List<String> = emptyList(), seconds: Int = 0, fromLibrary: Boolean = false, draftId: String? = null)` | Quay video (replacing itself), a video draft's "Tiếp tục" |
| `MyListingsRoute(pane: String = "LIVE", posted: String? = null)` | Tôi's placeholder, "Xem tin của bạn" (replacing the form), the snackbar's "Xem" (Nháp), my listings' item rows in Chat, Đơn hàng and the order pages, Thông báo |
| `PlansRoute` | Tôi's placeholder, the boost sheet's link |

Home's FAB: "Tiếp tục nháp" opens the newest draft and shows only while a
draft exists; "Chụp ảnh" opens an empty Đăng tin; "Quay video" opens Quay
video. Tôi's placeholder gains "Tin của bạn" and "Gói người bán". The order
router opens Đơn bán for a seller's in-person order.

## Shared pieces

### Photo row and AI line

104 dp tiles with 16 dp corners in one scrolling row: the camera or library
badge ("Chụp trong app", "Từ thư viện"), "Ảnh bìa" on the first, a 48 dp
remove target "Xóa ảnh {tên}", and the add tile "Thêm ảnh" while there are
fewer than 10. The count reads "3/10". Under the row, the source line, then
sparkle + "AI đã điền từ 3 ảnh" (the photos read). Removing the cover moves
"Ảnh bìa" to the next photo; removing the last photo empties the form.

### Fields and the sparkle

Fields are filled tiles (`surfaceContainerHigh`, 16 dp corners, a 2 dp
`primary` ring on focus and `error` with an error line). A field the model
filled carries sparkle 14 dp ("AI đã điền") until the seller edits it; an
edit removes it for good and a new read brings them all back. On Kiểm tra
tin, saving a text row removes its sparkle even with the same value, a
choice row only when the choice changes, and the switch on its first
toggle. Counters read "29/70" and "146/1500" and stop input at the limit.

### Marks

"Vết đã khai" opens on the model's mark ("AI thấy trong ảnh" over the text,
the 56 dp crop) with "Bỏ qua" and "Khai vết này", and ends with the
declared-marks sentence. A declared mark is a row
with its 48 dp close-up, the text, camera + "Ảnh cận chụp trong app · 16/10"
(the date `design-system.md` asks for) and "Bỏ vết này". "Thêm vết, chụp
cận" takes a photo with the camera app and adds a row with "Mô tả vết" to
fill ("Mô tả vết, ví dụ: móp góc dưới"); an empty seller mark is dropped on
posting. "Bỏ qua" says "Đã bỏ qua. Vết có thật mà không khai thì lỗi thuộc
bạn".

### Price and ways to hand over

"Giá bán": sparkle + the estimate in `tertiary`, the two suggestions as
selectable panels (bolt "Bán nhanh" 4.500.000 ₫ "~2 ngày", balance "Giá thị
trường" 4.800.000 ₫ "~1 tuần"; the panel whose amount equals the field shows
its check), "Giá của bạn" ("Nhập giá"), which keeps digits and reads
"4.500.000 ₫", and the "Cho phép trả giá" switch row. "Giao dịch": checkbox
rows Gặp mặt ("Bình Thạnh") and COD, xem hàng trước ("Người mua xem hàng rồi
mới trả"); with COD on, the payout and return-leg sentences; above 5.000.000
₫, COD unchecks and dims with "Chỉ cho món đến 5 triệu" and the over-limit
sentence shows; back at or under the limit COD can be checked again. The area
row: location, "Bình Thạnh, TP.HCM", eye + "Chỉ hiện quận", "Đổi".

### Posting overlays

"Xem trước" opens a sheet with the listing as a card (ruling 19): the cover,
the price or "Chưa có giá", the title or "Chưa có tiêu đề". The gate sheet
(ruling 7): 80 dp Cookie9Sided in `primaryContainer` around a shield, "Xác
minh để đăng tin", timer · 2 phút and draft · "Tin được lưu nháp", the three
steps (CCCD, Chip, Khuôn mặt), "Xác minh ngay" and "Để sau". The done screen
replaces the form, and back from it closes the screen: 128 dp SoftBurst in `primaryContainer` around a check,
"Đã đăng tin" (polite live region), "Người quanh Bình Thạnh sẽ thấy tin của
bạn trước.", "Xem tin của bạn", and "Đăng món khác" (Đăng tin) or "Về Khám
phá" (Kiểm tra tin).

### Step pill and camera

The step pill is the mockups' row of three dots, the current one 24 dp wide
and the others 8 dp, read as an image: "Bước 1 trên 3: Quay" on Quay video
(on black), "Bước 2 trên 3: Kiểm tra" on Kiểm tra tin. The camera
package keeps stage 3's binding and permission view and adds the frame
grabber (an analyzer that saves one JPEG every 1.5 s to the cache), the torch
and the lens switch.

## The screens

### Đăng tin

No navigation bar. App bar: "Đóng", "Đăng tin" (or "Sửa tin"), "Lưu nháp".
Unverified, a `surfaceContainer` row above the form: shield, "Cần xác minh
để đăng", "Xác minh". The docked bar holds "Xem trước" (tonal) and "Đăng
tin" (primary, or "Lưu"), both disabled while empty or reading.

Empty: the upload area (`surfaceContainer`, 28 dp corners): 96 dp
Cookie9Sided in `secondaryContainer` around add-a-photo, "Bắt đầu bằng ảnh",
sparkle + "AI điền giúp tên, tình trạng và giá", "Chụp ảnh" and "Chọn ảnh".
Reading: the photo row and a panel with the 48 dp loading indicator and
"Đang đọc ảnh…" (status). Filled: the photo row, the AI line, and the form
blocks arriving one after another on the spatial spring (none with reduced
motion): Tiêu đề, Danh mục, Tình trạng (connected group Mới, Như mới, Đã
dùng with the meaning under it), Vết đã khai, Dung lượng and Màu side by
side, Pin (%) with "Cài đặt › Pin", Mô tả; Giá bán; Giao dịch.

The first photos start the read; photos added later are not read. A failed
read shows "Chưa đọc được ảnh." with "Thử lại" (new) in the panel and leaves
the fields empty and editable. "Đăng tin" checks in order: "Nhập tiêu đề cho
tin.", "Chọn hoặc nhập giá bán." or "Giá tối thiểu là 10.000 ₫.", "Khai hoặc
bỏ qua vết AI thấy.", "Chọn ít nhất một cách giao dịch."; the first problem
scrolls to a third of the screen's height and takes focus. At the cap the
snackbar says "Bạn đang có 20/20 tin đang bán. Ẩn hoặc bán bớt để đăng
thêm." (new). Unverified, the gate opens; "Để sau" saves the draft and says
"Đã lưu nháp"; "Xác minh ngay" saves it and opens the placeholder. "Lưu nháp"
saves and says "Đã lưu nháp" with "Xem". Verified, the button shows progress
and the done screen follows, where "Đăng món khác" starts an empty form.

### Quay video

No navigation bar, black, the feed full-bleed under top and bottom scrims,
white status bar icons. App bar: "Đóng", the step pill, "Đèn flash" (pressed
state). Ready: "Quay món đồ bạn muốn bán" and the tips (Xoay quanh, Cận chỗ
trầy, Nói giá). The bottom row: "Chọn video có sẵn", the record button (an
84 dp ring around a 64 dp `error` circle, "Bắt đầu quay" or "Dừng quay"),
"Đổi camera". Recording: the circle becomes a 28 dp rounded square and the
ring fills over 30 s, a timer pill with a red dot ("0:07") sits under the
bar, the prompt follows the cues, the caption's words fade in 90 ms apart in
a `black/50` panel (polite live region), and the chips ("AI nhận ra", polite
live region) each lead with a sparkle.

A take under 3 s is dropped with "Quay ít nhất 3 giây nhé" (ruling 21).
Stopping, or 30 s, replaces the screen with Kiểm tra tin. "Đóng" while ready
closes; during a take it pauses the clock and asks "Bỏ video này?" ("Video
chưa được lưu.", "Ở lại", "Bỏ"); "Ở lại" resumes with the time kept. Back
does the same. A gallery video that cannot be read says "Không đọc được video
này." (new). Without the camera permission, the stage 3 permission view says
"Cần quyền camera để quay video." (new).

### Kiểm tra tin

No navigation bar. App bar: "Đóng", the step pill, "Lưu nháp". Reading: a
square frame with 28 dp corners shows the frame being read under a scan
line, with the loading indicator in its corner; the eight frames sit in a
row ("Khung hình") and light up as they are read (scale 1.1, a `primary`
ring); the kept frames keep the ring, the rest dim to 40 %; the four findings
arrive with a check each. Reduced motion drops the scan line and the
scaling; the draft shows when the reading ends. A resumed draft opens on the
draft.

The draft: the photo row starts with the video tile ("Phát video 0:12";
it plays the frames in place and a second tap stops it), then the kept
frames ("Đổi khung hình" opens "Khung hình": the eight in four columns with
checks, sparkle + "AI chọn 4 khung rõ nhất" until the pick changes, then "Đã
chọn {n} khung"; "Xong" needs one frame and replaces the frame photos in
order), then added photos, then the add tile; the source line ("Ảnh lấy từ
video quay trong app", " · 2 ảnh từ thư viện" with added library photos).
The title in `titleLarge` with its sparkle; the price in `displaySmall`
with "₫" in `titleLarge` ("Sửa giá"), over mic + "Bạn nói trong video" or
pencil + "Bạn đã sửa giá", and the estimate. A grouped list of 72 dp rows:
Danh mục, Tình trạng (with the meaning), Thông số ("64 GB · Pin 81% ·
Trắng"), "Mô tả · từ lời bạn nói". "Vết đã khai": the spoken mark with the
frame at 0:07 and "Khung hình 0:07 · bạn nói trong video", "Thêm vết, chụp
cận", the sentence. "Giao dịch": Cách giao ("Gặp mặt · COD, xem hàng trước",
or "Gặp mặt" above the limit), "Cho phép trả giá", Khu vực, then the COD
sentences or the over-limit one.

Rows open sheets: choices are radio rows that save 180 ms after a different
pick; text is a filled tile with "Lưu", and an empty value is not saved;
the price sheet "Giá bán (₫)" keeps digits. The docked bar ("Xem trước",
"Đăng tin"), the checks, the gate, posting and the done screen work as on
Đăng tin.

### Tin của bạn

No navigation bar. App bar: back, "Tin của bạn", and "Đăng tin" (add), whose
menu holds "Quay video" and "Chụp ảnh". "7 ngày qua" (`titleSmall`,
`primary`) over three tiles in one rounded row: eye 55 Lượt xem, chat 2
Người hỏi, heart 3 Lượt lưu. A connected toggle group: Đang bán 2, Nháp 1,
Đã bán 2; `MyListingsRoute`'s pane picks the first.

Each listing is a `surfaceContainer` card with 28 dp corners: the 64 dp
photo, the title, the price with "₫" one size down, a line of icon counts
("Lượt xem", "Người hỏi", "Lượt lưu", "Đã đăng" with the age, or rocket +
"Đẩy 3 ngày" in `primary`), and "Tùy chọn cho {title}". At most one
suggestion: the price cut (sparkle + "Cao hơn 12%" in `tertiary`, "Giảm còn
1,7 tr"), or the order row (`primaryContainer`: its icon, `orderNote`,
chevron; opens the order). A hidden card dims to 50 % and says eye-off "Đã
ẩn · người mua không thấy tin này". Tapping a card opens "Sửa tin"; a draft
card opens its form.

Draft cards: photo, title or "Chưa có tiêu đề", photo-library + "3 ảnh ·
chưa có giá" (or the price), shield + "Cần xác minh để đăng" while
unverified, "Tiếp tục". Sold cards: photo, title, price, the buyer's 20 dp
avatar with "Gia Bảo · Thứ Hai", and star + "5" in `primary`, hourglass +
"Chờ đánh giá", or nothing for "Người ngoài ShopNexus".

| Pane | Menu |
|---|---|
| Đang bán | Đẩy tin, Sửa tin, Đánh dấu đã bán, Ẩn tin or Hiện tin, Xóa tin (reserved: Sửa tin, Ẩn tin or Hiện tin) |
| Nháp | Sửa tin, Xóa nháp |
| Đã bán | Đăng lại, Xóa tin |

"Giảm còn 1,7 tr" sets the price and says "Đã giảm còn 1.700.000 ₫" with
"Hoàn tác", which restores the price and the suggestion. "Ẩn tin" and "Hiện
tin" say "Đã ẩn tin" and "Tin hiện lại cho người mua". "Đẩy tin" opens the
boost sheet: trending-up + "Lên đầu mục Gần bạn quanh Bình Thạnh", the radios
1 ngày 15.000 ₫ (selected) and 3 ngày 35.000 ₫, "MoMo •• 0912" with "Đổi"
(placeholder, stage 5), the service-fee sentence, "Gói Plus có 4 lượt đẩy mỗi
tháng" (Gói người bán), and "Đẩy tin · 15.000 ₫"; paying shows progress,
closes the sheet, leads the card with "Đẩy 1 ngày" and says "Đã đẩy tin 1
ngày · 15.000 ₫" (ruling 17 with a plan). "Đánh dấu đã bán" opens "Bán cho
ai?": 40 dp avatars, names and `askerLine`s as radios, then "Người ngoài
ShopNexus"; a ShopNexus buyer shows star + "Minh Quang sẽ được mời đánh giá
bạn"; "Xác nhận đã bán" is enabled once one is picked, collapses the card,
leads Đã bán with "{who} · Hôm nay" and says "Đã chuyển sang Đã bán" with
"Hoàn tác". "Xóa tin" and "Xóa nháp" ask first (ruling 16; "Lượt lưu và câu
hỏi của người mua cũng mất.", "Hủy", "Xóa") and say "Đã xóa tin" or "Đã xóa
nháp". Arriving with `posted`, the new card leads Đang bán and the snackbar
says "Đã đăng tin". Empty panes: an 80 dp Cookie9Sided with storefront, edit
note or sell, the line ("Chưa có tin đang bán", "Không có bản nháp", "Chưa
bán món nào") and the action of ruling 20.

### Gói người bán

No navigation bar. Back and "Gói người bán". A radio group "Gói" of three
`surfaceContainer` cards, the chosen one with a 2 dp `primary` ring and a
check: the name, "Đang dùng" on the current plan, the price as a light
`headlineMedium` figure with "₫/tháng" in `bodyMedium` (or "Miễn phí"), and
three feature rows. Under them, verified + "Gói không mua được quyền COD hay
bậc uy tín. Những thứ đó chỉ đến từ lịch sử giao dịch của bạn." and the
service-fee sentence. The docked button reads `planButton`; it opens "Xác
nhận gói" with "Gói Plus · 49.000 ₫/tháng", "MoMo •• 0912", autorenew + "Gia
hạn mỗi tháng. Hủy lúc nào cũng được, gói chạy hết tháng đã trả." and
"Xác nhận" (ruling 18 for Cơ bản). Confirming shows progress, moves "Đang
dùng" and says "Đã chuyển sang gói Plus".

### Đơn bán gặp mặt

No navigation bar. Back and "Đơn bán". The hero of Seller order states; the
timeline with "Chốt giá 4.000.000 ₫", "Hẹn 18:00 thứ Năm · Sảnh Landmark
81", "Gặp, đưa mã cho Thảo Vy quét", "Thảo Vy đánh giá"; with a record, the
incident card; the item row (opens Tin của bạn); the buyer row ("Thảo Vy /
Phú Nhuận · gặp mặt", "Nhắn Thảo Vy"); "Gặp mặt" with the place, "Chỉ
đường" and the time with "Đổi"; "Tiền" with "Giá đã chốt", "Nhận trực tiếp
từ Thảo Vy / Tiền mặt hoặc chuyển khoản khi gặp" (new) and the in-person and
no-holding sentences; "Mã đơn". "Hủy hẹn", "Tự hoàn" and "Từ chối" work as
on Chi tiết đơn and Đơn bán.

## State and errors

As in stages 1 to 3: one ViewModel per screen with `StateFlow` and
`onEvent`, one-off effects through a `Channel`, a failed read with "Thử lại",
a failed command with "Chưa gửi được. Thử lại" and its optimistic change
rolled back. Saving a draft that fails says "Chưa lưu được nháp. Thử lại"
(new); posting that fails says "Chưa đăng được. Thử lại" (new) and keeps the
form. Paying for a boost or a plan never shows as done before it succeeds.
The form, the open sheet, the picked frames, the selected plan and the pane
survive recreation through `SavedStateHandle`; photos the camera takes live
in the app's cache under `sell/`. Drafts, listings, sales, boosts and the
plan persist in the fake for the session.

## Accessibility

Touch targets of at least 48 dp; content descriptions on every icon-only
control ("Đóng", "Xóa ảnh {tên}", "Đèn flash", "Đổi camera", "Bắt đầu quay",
"Dừng quay", "Chọn video có sẵn", "Phát video 0:12", "Đổi khung hình", "Sửa
giá", "Bỏ vết này", "Tùy chọn cho {title}", "Đăng tin"); the reading panel
as a status; the chips and captions as polite live regions; the done heading
as a polite live region; the toggle groups, radios, checkboxes, switches and
frame checks with their state; section titles as headings; the step pill as
an image with its label. Reduced motion turns off the form's arrival, the
scan line and frame scaling, the record button's morph, the caption fade and
the card collapse. Every screen and new component is checked at font scale
1.3 with `assertNoClippedText`, and every field label and button with
`isLineEllipsized`.

## Testing and acceptance

- JVM unit tests for every rule in the rules table, the engine's two-sided
  commands and refusals, the fakes (drafts, posting, the cap, sales, boosts,
  plans) and the simulator's new timings on virtual time.
- ViewModel tests with Turbine for each new screen and the seller console.
- Roborazzi screenshots of every new component and every state of every
  new screen (Đăng tin empty, reading, filled, errors, gate, preview, done;
  Quay video ready, recording, dialog; Kiểm tra tin reading, draft, each
  sheet, frames; every pane and sheet of Tin của bạn; Gói người bán and its
  sheet; every state of Đơn bán gặp mặt; the seller console states), with
  light, dark, Material You and font scale 1.3 for each screen's main state.
- Robolectric Compose UI tests for each screen's controls and four walks:
  Home → "Chụp ảnh" → Đăng tin → a photo (the camera stubbed) → the read →
  "Khai vết này" → "Bán nhanh" → "Đăng tin" → gate → "Để sau" → Tin của
  bạn's Nháp shows it → the debug switch → "Tiếp tục" → "Đăng tin" → done →
  "Xem tin của bạn"; Quay video (simulated) → a 12 s take → Kiểm tra tin →
  the price sheet → "Đăng tin" → done; after posting, Thảo Vy's offer → Tin
  nhắn → Chat → "Đồng ý" → her COD → "Gửi hàng" → Đơn bán → "Chụp hàng" →
  "Xác nhận gửi" → received → Tin của bạn's Đã bán shows 5 stars; a listing
  at 6.000.000 ₫ (meeting only) → her offer → "Trả giá" → she accepts → her
  meeting → "Đồng ý hẹn" → "Hiện mã giao dịch" → she scans → Đã bán.
- Stage 3 tests that rulings 12 and 23 change (the order router for `d-bao`,
  my listings' item routes, the simulated buyer's rating after receipt) are
  updated with those rulings named in the commit. A test scans `src/main`
  for `PlaceholderRoute(4,` and `stage = 4`.
- `./gradlew check verifyRoborazziDebug` runs everything.

Stage 4 is done when:

1. Every screen walks on the API 36 emulator with no dead control; controls
   for later stages open their placeholder; Quay video records frames from
   a real camera on a device.
2. Every screen state has a screenshot, reviewed side by side with its
   mockup, and every difference is one of the rulings above.
3. Every rule in the rules table has unit tests.
4. Every screen lays out at font scale 1.3 without clipping.
5. The mockup checker still passes for all 31 screens.

## Out of scope

Real AI (photo and video reading, price estimates, recognition cues), speech
recognition, a stored or uploaded video file, eKYC and Tôi (stage 5),
changing the area, a shop page with its own name, managers, 30-day
statistics, saved replies, real payments for boosts and plans, push
notifications, closing other conversations when a listing sells, and
changing an order when its listing is edited.
