# Design: app2 stage 5, Tài khoản và tin cậy

Date: 2026-10-16
Status: draft. The user's standing instruction is to keep building, so this
spec goes straight to a plan; the decisions marked as rulings are the ones to
review.

## Goal

Stage 5 builds the person's own side of the app on stages 1 to 4: Tôi,
Hoàn thiện hồ sơ, Điểm uy tín, the five steps of eKYC (Bắt đầu, Chụp CCCD,
Đọc chip, Khuôn mặt, Kiểm tra thông tin), Chào mừng and Đăng nhập. With it
the app has no stage placeholders left: the last ones (identity checks from
Đăng tin and Kiểm tra tin, the account rows of Giao COD, the two account
notifications) open real screens. The screens are designed in
`app2/.superdesign/` (`design-system.md`, `tools/build_me.py`,
`build_tasks.py`, `build_rep.py`, `build_kyc.py`, `build_welcome.py`,
`build_login.py`, `common.py`); `app2/.superdesign/stage5-digest.md` lists
their data, strings and interactions with source lines. The trust model is
`app2/mohinh.md`.

Earlier decisions hold: Android only, Kotlin, Compose with material3
1.5.0-beta01, Navigation 3, Hilt, ViewModel + `StateFlow`, fake repositories
over one `FakeWorld`, the simulator playing the other side, CameraX for the
camera, JVM tests with Robolectric and Roborazzi at a zero-pixel threshold.
The repository interfaces stay the API contract for the Go server.

## Rulings on the mockups

The mockups store nothing and fake every check with timers. The app follows
the trust model, `design-system.md` and the data stages 1 to 4 already hold:

1. The session. The app starts signed in as Khánh Linh, as stages 1 to 4
   assume. "Đăng xuất" on Tôi asks first ("Đăng xuất?", "Tin nháp và đơn
   vẫn còn khi bạn đăng nhập lại.", "Đăng xuất", "Ở lại") and then shows
   Chào mừng in place of the app, with the back stack cleared. Đăng nhập
   signs back in as Khánh Linh whatever number is typed; the fake keeps one
   account.
2. "Xem trước, đăng nhập sau" opens the app as a guest. A guest browses
   Khám phá, Danh mục, search, listings and seller pages. Everything tied
   to an account opens Đăng nhập on top instead: the Tin nhắn and Tôi tabs,
   Home's FAB, "Nhắn" and every deal action, Đã lưu, Thông báo, Đơn hàng,
   Tin của bạn and the order pages. The navigator holds this rule in one
   place (`requiresAccount(route)`). A guest's heart saves on the device and
   the saves join the account at sign-in. Once signed in from such a
   detour, Đăng nhập closes and the person is where they were.
3. Đăng nhập's resend works: "Gửi lại mã" starts a new 45 s countdown each
   time (the builder stops after the first). The code `000000` is refused,
   any other six digits pass after 700 ms. "Dùng vị trí hiện tại" asks for
   the coarse location permission and, granted or not, the fake answers
   Bình Thạnh (no geocoder runs). The district chosen on the last step
   becomes the account's district and Home's location pill.
4. Data first. Khánh Linh's COD payout account (`Vietcombank •• 4821`) and
   delivery address (`12 Nguyễn Gia Trí, Phường 25, Bình Thạnh`) already
   exist and stage 3 shows them, so Hoàn thiện hồ sơ counts them done: the
   check-list starts at 4/6 with identity and the bio open, not the
   mockup's 2/6. Tôi's ring reads 4/6 and the account notification reads
   "Hoàn thiện hồ sơ: còn 2 việc". The phone row shows the account's
   `09•• ••• 812`.
5. Done rows that hold a value open their sheet to change it: the payout
   account, the address and the bio. The phone and the photo stay without an
   action, as in the mockup.
6. The score. Điểm uy tín shows the account's score: the seeded 386 plus
   every event the person earned in the app (a hand-over, a five-star
   rating, a self-refund, a cancellation, identity), so it moves as stages
   3 and 4 are played. The tier follows `tierFor()`. The history lists the
   app's events, newest first, above the six seeded rows of the mockup.
7. The 90-day figures come from the app: "Từ chối nhận COD" reads "0 trên 3
   đơn" from `account.json` (the mockup says 4). "Ghi nhận bạn từ chối"
   counts the records the person declined as a seller in 90 days and "Ghi
   nhận chưa trả lời" the open records waiting for their answer.
8. The ladder of `mohinh.md` (Hạ hiển thị, Giới hạn COD, Mất COD, Khóa) is
   shown as the mockup has it, as a description; the app enforces only the
   COD steps of `rightsFor()`, as before. "Quyền của bạn" reads the open COD
   orders and the listings on sale against `rightsFor()`.
9. The history section shows the six newest rows, and "Xem toàn bộ lịch
   sử" opens a sheet with every row (the mockup shows a snackbar).
10. eKYC runs on real hardware where it can and simulates the rest. Chụp
    CCCD shows the back camera behind the frame; the shutter captures, and
    the hold-and-capture timers of the mockup (hold after 1,1 s, capture
    after 2,1 s) run as an auto-capture. The capture checks ("Rõ nét",
    "Không lóa", "Đủ 4 góc") come from the fake and pass. Khuôn mặt shows
    the front camera in the oval with the mockup's three timed prompts; no
    liveness model runs and the fake's check passes. With the debug camera
    switch on, or without a camera, both steps show the mockup's drawing
    and still photo.
11. Đọc chip is simulated on every phone: reading a CCCD chip needs keys
    from the card's printed data, which the app does not have. A phone
    without NFC opens the "Không có NFC?" sheet at once; the manual path
    stays one tap away for every phone.
12. Sending. "Gửi xác minh" takes 2 s. On the chip path the fake verifies
    at once: the account becomes verified and earns IDENTITY (+100). On the
    manual path eKYC ends on "Đang chờ duyệt"; the simulator approves it
    10 s later and posts the notification "Đã xác minh danh tính" that opens
    Hoàn thiện hồ sơ. Until then the check-list shows "Đang chờ duyệt ·
    1–2 ngày" and Đăng tin still asks for verification.
13. The way back. eKYC remembers where it was opened from: Đăng tin, Kiểm
    tra tin, Hoàn thiện hồ sơ, Điểm uy tín or Tôi. "Đăng tin ngay" goes
    back to the form it came from, now verified; from elsewhere it opens an
    empty Đăng tin. "Về hồ sơ" opens Hoàn thiện hồ sơ. "Thoát" in the exit
    dialog goes back to where eKYC was opened. The exit dialog's body "Tin
    nháp của bạn vẫn được lưu." shows only when a form is waiting below it.
14. Entry points. Đăng tin's banner "Xác minh" opens Bắt đầu; the gate's
    "Xác minh ngay" opens Chụp CCCD at once (as the mockup skips the
    intro). Tôi's "Bảo mật và xác minh" opens Bắt đầu while unverified and a
    placeholder ("Bảo mật", later) once verified.
15. Tôi's links. "Trang của bạn" opens Khánh Linh's public seller page (her
    seller record joins `sellers.json`); the share button sends that page's
    link through the Android share sheet. "Khu vực" and "Trợ giúp và an
    toàn" open placeholders for later stages (stage 0). The due row shows
    the most urgent selling order (the stool's "Gửi Ghế đôn gỗ cao cho Đức
    Huy" while it waits) and is absent when nothing is due. "Tin của bạn"
    shows up to three rows: the newest draft, the live listing with a price
    suggestion (or the newest), and the newest sale. "Giảm còn 1,7 tr" cuts
    the price through Tin của bạn's command with the same undo.
16. Tôi's tier chip shows the score after the name ("Tin cậy · 386"):
    `TierChip` gains an optional trailing text.
17. Giao COD's "Đổi" on the address opens Hoàn thiện hồ sơ's address sheet
    over the order; "Xem quyền của bạn" opens Điểm uy tín. "Đổi" on the
    payment method (Giao COD and the boost sheet) and Thông báo's settings
    icon open placeholders for later (stage 0): no payment-method or
    notification-settings screen is designed.
18. Copy. The wordmark and tagline follow `design-system.md`: "Giá tốt, gần
    bạn, chốt nhanh!" with its exclamation mark. "Bản thiết kế …" footers
    and "Bản mẫu …" snackbars are not built. Disabled buttons use the M3
    12 % and 38 % on every screen, and money keeps the app's no-break space
    before ₫.
19. Touch targets below 48 dp in the mockups (the tier chip, the track
    markers, "Đổi số", "Viết giúp") keep their drawn size and get a 48 dp
    touch area.
20. Tôi applies the theme on start as well as on a change (the builder's
    page opened light on a dark phone). "Màu theo hình nền" uses Android's
    wallpaper colours through the existing theme setting; turning it on
    shows "Đã lấy màu từ hình nền" with "Hoàn tác".
21. The debug panel gains "Đăng xuất ngay" (no dialog) and keeps its
    identity switch, which now also clears or sets the pending review.

## Scope

| Built in stage 5 | Opens a placeholder for later |
|---|---|
| Tôi: header, tier chip, public page and share, the profile card, the due row, the tiles, Tin của bạn rows with the price cut, theme settings, account rows, sign-out | "Khu vực", "Trợ giúp và an toàn", "Bảo mật" once verified |
| Hoàn thiện hồ sơ: ring, open and done lists, the payout, address and bio sheets with their checks, "Viết giúp", the complete state | |
| Điểm uy tín: hero, score card and track, tier perks, raise rows, rights, 90-day figures, ladder, history and its sheet, rules sheet | |
| eKYC: Bắt đầu, Chụp CCCD (front and back), Đọc chip and the no-NFC sheet, Khuôn mặt, Kiểm tra thông tin with sending, done and pending, the exit dialog | "Chính sách bảo mật" (stage 0) |
| Chào mừng, Đăng nhập (phone, code, area), sign-out, guest browsing | |
| The stage placeholders left by stages 3 and 4: identity from Đăng tin and Kiểm tra tin, Giao COD's address and rights, the account notifications | payment methods, notification settings (stage 0) |

## Modules

| Module | Holds | May depend on |
|---|---|---|
| `:feature:me` (new) | Tôi, Hoàn thiện hồ sơ and its sheets, Điểm uy tín and its sheets | `:core:*` |
| `:feature:kyc` (new) | the five eKYC steps, the no-NFC sheet, the exit dialog | `:core:*` |
| `:feature:auth` (new) | Chào mừng, Đăng nhập | `:core:*` |
| `:feature:placeholder` | loses the Tôi placeholder; keeps the generic placeholder screen for stage 0 | |
| `:core:ui` | the camera package grows a still capture for the CCCD and a front-camera feed | `:core:designsystem`, `:core:data`, `:core:navigation` |
| `:core:designsystem` | `TierChip` with a trailing text, the progress ring, the OTP boxes, the district chips row | |
| `:app` | the session: Chào mừng in place of the app when signed out, the guest rule in the navigator | |

New Material Symbols join `symbols.txt` and the generated font.

## Domain model and API contract (`:core:model`)

Changed and new types, all `@Serializable`.

- `Session`: SIGNED_IN, GUEST, SIGNED_OUT.
- `Account` grows `bio` (text or null), `kyc` (`KycState`: NONE, PENDING,
  VERIFIED; `verified` reads VERIFIED), and the phone it already has.
- `ProfileTask`: key (IDENTITY, PAYOUT, ADDRESS, BIO, PHONE, AVATAR), done,
  and the value a done row shows ("CCCD gắn chip", "Vietcombank •• 4821",
  "Phường 25, Bình Thạnh", the bio, "09•• ••• 812", "Đã thêm"), pending
  for identity under review. `ProfileTasks`: the six in their order.
- `PayoutForm` (bank, account number), `AddressForm` (street, ward), and the
  banks and wards the sheets offer.
- `Reputation`: score, tier, the next tier and the points to it, the raise
  rows (identity done or not, the reply rate "tháng này 9/10 tin"), the
  rights in use against their caps, the three 90-day figures, and the
  history (`HistoryRow`: icon, text, day, points).
- `KycStep`: INTRO, CARD_FRONT, CARD_BACK, CHIP, FACE, REVIEW, SENDING,
  DONE, PENDING. `CardCheck` (the three checks), `ChipRead` (progress 0 to
  100, then the fields: full name, the masked CCCD number, date of birth,
  residence, valid until, and the chip photo), `KycOrigin` (SELL, REVIEW,
  TASKS, REP, ME).
- `MeSummary`: name, photo, rating and reviews, district, tier and score,
  verified, the profile count (done of six) and the next open task, the due
  order (deal id, line, deadline line) or none, the tile counts (saved,
  buying orders, selling orders), up to three listing rows, the plan line.
- `NotificationTarget` gains `ProfileTasks` and `Reputation`; the seeded
  account notifications use them.

Repository interfaces in `:core:data`:

| Interface | Reads | Commands |
|---|---|---|
| `SessionRepository` (new) | `session()` | `sendCode(phone)`, `verifyCode(phone, code)`, `chooseDistrict(name)`, `locate()` returning the district, `browseAsGuest()`, `signOut()` |
| `ProfileRepository` (new) | `me()` as `MeSummary`, `tasks()` | `savePayout(form)`, `saveAddress(form)`, `saveBio(text)`, `draftBio()` returning the model's sentence |
| `ReputationRepository` (new) | `reputation()` | |
| `KycRepository` (new) | `state()` | `checkCard(side, photo)` returning the checks, `readChip()` as a flow of `ChipRead`, `checkFace(photo)`, `submit(manual)` |

`verifyCode` refuses `000000`. `submit` refuses a review without consent
(the screen never sends one) and returns VERIFIED or PENDING.

## Account rules (`:core:domain`)

| Function | Rule |
|---|---|
| `phoneDigits(text)` | the digits typed, a leading 0 dropped, at most 9; `phoneValid` when they match 3, 5, 7, 8 or 9 then eight digits |
| `phoneLabel(digits)` | "912 345 812" while typing; "0912 345 812" on the code step |
| `resendLeft(sentAt, now)` | seconds left of 45; "Gửi lại sau 0:45" then "Gửi lại mã" |
| `accountValid(text)` | 6 to 16 digits; the sheet keeps only digits |
| `streetValid(text)` | at least 3 characters after trimming |
| `bioValid(text)` | 10 to 150 characters after trimming |
| `payoutLabel(form)` | "{bank} •• {last four}" |
| `profileProgress(tasks)` | done of six, "Còn {n} bước" or "Hồ sơ đầy đủ", the next open task in order |
| `nextTier(score)` | the tier above and the points left ("Còn 114 điểm lên Uy tín"), or "Bậc cao nhất" |
| `trackFill(score)` | the score over 1000, the four markers at 0, 20, 50 and 80 % |
| `tierPerks(tier)` | the perks of `design-system.md` and the digest's table |
| `historyRow(event, at, now)` | the icon, the words, the day ("Hôm nay", "12/10") and the signed points (+ or U+2212) |
| `stats90(deals, account, now)` | COD refused of COD orders, records declined, records unanswered |
| `dueOrder(views, now)` | the selling order whose deadline is nearest: a parcel to send, a meeting to confirm, a record to answer |
| `requiresAccount(route)` | the routes a guest cannot open (ruling 2) |
| `kycAfterSubmit(manual)` | VERIFIED on the chip path, PENDING on the manual path |

## Fake data (`:core:data`)

- `account.json` gains `bio: null`, `kyc: "NONE"`, and the history rows of
  the mockup (text, icon, day, points) as `history`.
- `sellers.json` gains Khánh Linh's public seller record, with her two live
  listings and the reviews of her sales.
- `kyc.json` (new): the three card checks, the chip fields (`Nguyễn Khánh
  Linh`, `079 ••• ••• 218`, `14/03/1999`, `Bình Thạnh, TP.HCM`,
  `14/03/2039`), the chip photo and the face photo IDs, the bio draft, the
  banks and wards.
- The session starts SIGNED_IN; `FakeWorld.reset()` restores it.
- The simulator gains the manual review: 10 s after a PENDING submit, the
  account becomes VERIFIED, earns IDENTITY, and the notification "Đã xác
  minh danh tính" arrives.
- The chip read emits progress every 90 ms after 1,6 s, as the mockup, at
  the simulator's pace.

## Navigation

| Route | Opened from |
|---|---|
| `MeRoute` (tab, now Tôi) | the navigation bar |
| `ProfileTasksRoute(sheet: String? = null)` | Tôi's profile card, eKYC "Về hồ sơ", the notifications, Giao COD's address "Đổi" (`sheet = "ADDRESS"`) |
| `ReputationRoute` | Tôi's tier chip, Giao COD's "Xem quyền của bạn", the notification |
| `KycRoute(origin: String, start: String = "INTRO")` | Đăng tin and Kiểm tra tin (banner: INTRO, gate: CARD), Hoàn thiện hồ sơ, Điểm uy tín, Tôi |
| `WelcomeRoute`, `LoginRoute` | the session: Chào mừng when signed out; Đăng nhập from Chào mừng and from every guest detour |

eKYC's steps live in one route and one ViewModel; system back moves to the
step before within the card step (back side to front side) and otherwise
opens the exit dialog. Đăng nhập's back goes to the step before, and from
the phone step leaves.

## The screens

### Tôi

The navigation bar; no top bar. The header: 72 dp photo, "Khánh Linh",
"4,8 · 21 đánh giá · Bình Thạnh" with a star, the tier chip "Tin cậy · 386"
(Điểm uy tín), "Đã xác minh" with its check once verified, "Trang của bạn"
(outlined, the public page) and the share icon button. The profile card: a
40 dp ring with "4/6", "Hoàn thiện hồ sơ", the next open task in `primary`
with its icon. "Đơn hàng": the due row (a `primaryContainer` circle with
the order's icon, the order line, the deadline in `primary`), then three
tiles (Đã lưu, Đơn mua, Đơn bán with their counts). "Tin của bạn" with the
arrow to Tin của bạn and up to three rows (64 dp photos with 16 dp corners):
the draft with "Bản nháp" and "Tiếp tục", the live listing with its asker
and view counts and the price suggestion ("Cao hơn 12%" in `tertiary`,
"Giảm còn 1,7 tr"; after the cut "Đã giảm giá"), the sale with "Đã bán ·
Thứ Hai". "Giao diện": "Màu theo hình nền" (switch), "Giao diện tối" with
the mode, opening the theme sheet (three radios, closing 220 ms after a
pick). "Tài khoản": Thông báo, Gói người bán ("Cơ bản · miễn phí"), Khu vực
("Bình Thạnh, TP.HCM"), Bảo mật và xác minh ("Chưa xác minh danh tính",
"Đang chờ duyệt" or "CCCD gắn chip"), Trợ giúp và an toàn. "Đăng xuất" in
`error`. Rows with a value are at least 72 dp, the others 56 dp.

A guest sees the Tôi tab only after signing in (ruling 2).

### Hoàn thiện hồ sơ

Back and no title in the bar. A 128 dp ring with the count ("4" and "/6")
animating to its value over 900 ms, "Hoàn thiện hồ sơ", "Còn 2 bước" (polite
live region), "Cần làm" with the open rows (the icon in a 40 dp
`surfaceContainerHighest` circle, the title, the line, a chevron), "Đã xong
· 4" with the done rows (a check on `primary`, the title, the value). The
identity line is "Cần để đăng tin · +100 điểm uy tín" in `primary`, or
"Đang chờ duyệt · 1–2 ngày" with a schedule icon on `secondaryContainer`.
All six done: "Hồ sơ đầy đủ", "Cần làm" hidden, the badge "Người bán tin
cậy" coming in.

The sheets (Lưu disabled until valid only after a first try; errors as the
digest lists them; typing clears the error): "Tài khoản nhận tiền COD"
(Ngân hàng picker with the six banks, Số tài khoản digits only with "6–16
chữ số", the note on the holder's name, the COD money sentence);
"Địa chỉ nhận hàng" (Số nhà, đường, the Phường, quận picker with the four
wards, "Chỉ người giao hàng thấy"); "Giới thiệu bản thân" (three lines, the
counter "0/150", "Viết giúp" filling the model's sentence with a sparkle).
A save closes the sheet, moves the row to the top of "Đã xong" with a 520 ms
entrance and shows "Đã lưu".

### Điểm uy tín

Back, "Điểm uy tín" and the info button ("Cách tính điểm"). The hero: the
tier's 112 dp shape with its icon, the tier name (polite live region). The
score card: "Điểm uy tín", the score counting up over 900 ms (set at once
with reduced motion) with "/1000", "Còn 114 điểm lên Uy tín", the track
filling to the score with four 28 dp markers that select a tier's perks
("Quyền theo bậc · Uy tín" with a lock and "từ 500" for a tier not reached).
"Tăng điểm": identity (+100 · một lần, to eKYC; "Đã xong · +100" once
verified), "Trả lời trong 1 giờ" (+20 mỗi tháng · tháng này 9/10 tin),
"Hoàn tất giao dịch" (+10 mỗi lần). "Quyền của bạn": "Đơn COD đang mở" and
"Tin đang đăng" with bars. "Chỉ số 90 ngày": the three figures. The ladder
and its sentence. "Lịch sử" with the arrow (the sheet) and the six newest
rows. The rules sheet: "Cộng", "Trừ" (`error`), "Bậc" with the four tiers
and their thresholds, and the two notes.

### eKYC

Every step has the close button ("Thoát xác minh") but the results; the
step pill shows on CCCD, Chip, Khuôn mặt and the review.

- Bắt đầu: a 112 dp Cookie9Sided around the card icon, "Xác minh danh
  tính", "2 phút" and "Mã hóa", the three steps, "Cần CCCD gắn chip và điện
  thoại có NFC", "Bắt đầu", "Chính sách bảo mật".
- Chụp CCCD (dark): the camera full-bleed, dimmed, behind a 348 × 220 dp
  frame with four corner brackets; "Mặt trước CCCD" / "Mặt sau CCCD", "Đặt
  thẻ vừa khung", the tips (Đủ sáng, Không che, Đủ 4 góc), "Giữ yên" with
  its bar in the hold state, the torch, the shutter. The capture flashes and
  raises the review panel with the three checks staggered 70 ms, "Chụp lại"
  and "Dùng ảnh". The camera permission view stands in for the feed when
  refused.
- Đọc chip: the 152 dp SoftBurst with NFC and two pulsing rings, "Áp CCCD
  vào lưng máy", "Giữ yên đến khi xong"; the percentage and the bar while
  reading; Sunny with a check, "Đã đọc chip", the three read rows and
  "Tiếp tục". "Máy không có NFC?" opens the sheet ("Duyệt thủ công trong
  1–2 ngày", "Tiếp tục không NFC", "Để sau"); the read pauses while the
  sheet is open.
- Khuôn mặt (dark): the front camera in a 248 × 312 dp oval with the ring
  filling a third per prompt, the prompt as the title ("Nhìn thẳng", "Quay
  sang trái", "Chớp mắt", then "Xong"), the three prompt dots, the tips
  (Bỏ kính, Đủ sáng), then the 56 dp Sunny and "Tiếp tục".
- Kiểm tra thông tin: "Kiểm tra thông tin", "Đọc từ chip, không sửa được",
  the chip photo and the scan linked with "Khớp", the five fields, the
  consent checkbox and "Gửi xác minh". Sending: the 72 dp loading indicator
  and "Đang xác minh…". Done: 128 dp Sunny, "Đã xác minh", the two checks,
  "Đăng tin ngay" and "Về hồ sơ". Pending: 128 dp Cookie9Sided, "Đang chờ
  duyệt", "1–2 ngày · ShopNexus báo bạn", "Về hồ sơ". On the manual path the
  review shows the card photos instead of the chip rows and the pill skips
  the chip step (the mockup keeps the chip data).

### Chào mừng

No bars. The 412 × 370 dp collage of four pool photos clipped to
Cookie9Sided, Clover4Leaf, Arch and Gem, the price tag "2,1 tr" and the
check, all skipped by TalkBack; the wordmark with the 36 dp SoftBurst mark,
"Giá tốt, gần bạn, chốt nhanh!", the three promises, "Bắt đầu với số điện
thoại", "Xem trước, đăng nhập sau".

### Đăng nhập

Back and the step pill (Số điện thoại, Mã xác nhận, Khu vực). Phone: "Số
điện thoại của bạn", "+84" and the field ("912 345 812"), the privacy note,
"Gửi mã". Code: "Nhập mã 6 số", "Gửi tới 0912 345 812" and "Đổi số", six
48 × 56 dp boxes over one field (one-time-code autofill), verifying at the
sixth digit or on "Xác nhận", the loading indicator, the error, the resend
countdown. Area: "Bạn ở khu vực nào?", the line, "Dùng vị trí hiện tại",
"Hoặc chọn quận", the six district chips (single choice), "Xong". One filled
button per step, disabled until the step is complete.

## State and errors

Every new screen has loading and failure states from the fakes'
`FailurePolicy`, as the earlier stages. A failed save keeps its sheet open
with a snackbar. A failed code send or check shows a snackbar and keeps the
step. A failed eKYC submit returns to the review with a snackbar; the
consent stays ticked. Process death keeps: the sheet open and its fields on
Hoàn thiện hồ sơ, the tier shown on Điểm uy tín, the eKYC step and the
captured photos (as files in the cache), the login step, the number and the
district; the camera steps bind the camera again on return.

## Accessibility

Rings and tracks are images with labels ("4 trên 6 bước", "Điểm uy tín 386
trên 1000"); the markers are toggle buttons ("Quyền lợi bậc Uy tín"). The
score, the step titles of eKYC and the login errors are polite live regions.
The OTP boxes are one field to TalkBack ("Mã 6 số"). Decorative photos have
no description. Every control has a 48 dp touch area (ruling 19). Every
screen lays out at font scale 1.3 without clipping.

## Testing and acceptance

- JVM unit tests for every rule in the rules table, the fakes (session,
  profile saves, reputation from events, eKYC states, the manual review on
  virtual time) and the guest rule.
- ViewModel tests with Turbine for each new screen.
- Roborazzi screenshots of every new component and every state of every
  new screen (Tôi default, verified, pending, the theme sheet; Hoàn thiện
  hồ sơ at 4/6, pending, each sheet and its error, complete; Điểm uy tín
  and each tier's perks, the rules and history sheets; each eKYC step and
  state; Chào mừng; Đăng nhập's three steps, the error and the countdown),
  with light, dark, Material You and font scale 1.3 for each screen's main
  state.
- Robolectric Compose UI tests for each screen's controls and four walks:
  Tôi → Đăng xuất → Chào mừng → Bắt đầu với số điện thoại → Đăng nhập (a
  number, a wrong code, the right code, a district) → Home signed in; Chào
  mừng → Xem trước → Tin nhắn opens Đăng nhập → signed in, back on Tin
  nhắn; Đăng tin → the gate → Xác minh ngay → the two card sides → chip →
  face → review → done → Đăng tin ngay → posted; Hoàn thiện hồ sơ →
  identity → the no-NFC path → pending → the simulator approves → the
  notification → Hoàn thiện hồ sơ at 5/6, then the bio sheet → 6/6.
- A test scans `src/main` for `PlaceholderRoute(5,` and `stage = 5`.
- `./gradlew check verifyRoborazziDebug` runs everything.

Stage 5 is done when:

1. Every screen walks on the API 36 emulator with no dead control; Chụp
   CCCD and Khuôn mặt show the real cameras on a device.
2. Every screen state has a screenshot, reviewed side by side with its
   mockup, and every difference is one of the rulings above.
3. Every rule in the rules table has unit tests.
4. Every screen lays out at font scale 1.3 without clipping.
5. No stage placeholder is left in `src/main`.

## Out of scope

A real SMS gateway, a real CCCD chip read (BAC/PACE keys), a liveness model,
payment-method management, notification settings, the area picker beyond
Đăng nhập's districts, the help pages, the privacy policy, account deletion,
more than one account.
