# Design: app2, COD as the only hand-over

Date: 2026-10-17
Status: decided in conversation on 2026-10-16 and 2026-10-17; the mockups
in `app2/.superdesign/` (main `487af75`) show every screen. The user asked
to bring the Android app in line ("update app android đi").

## Goal

The app stops offering an in-person hand-over. The user's reasons: the app
holds no money, cannot check the item and cannot tell when a meeting ended,
and people who meet do not press anything in an app. A deal in the app goes
by COD with a look at the door. Above 5 triệu COD stays open and the app
suggests meeting to look at the item first, which the two arrange in their
messages. `app2/mohinh.md` item 2 says the same.

The same pass brings over the other mockup changes of 2026-10-16: finished
steps keep their icons, the rating milestone goes, Listing detail opens Chat
on an offer or a question, and the iPhone 13 Pro fixture moves to 5,2 tr so
one listing tests both sides of the 5 triệu line.

## Decisions

1. COD is the only way to hand over. The app has no meeting slot, schedule
   sheet, meeting points, hand-over QR code or scanner, hand-over checklist,
   buyer or seller in-person order page, or meeting cancellation. The
   contract loses `HandoverPath`, `Listing.paths`, `Listing.meetNote`,
   `ListingDraft.paths`, `Deal.path`, `Deal.meeting`, `Deal.meetPoints`,
   `Meeting`, `MeetPoint`, the commands `ProposeMeeting`, `ConfirmMeeting`,
   `RecordHandover`, `CancelMeeting` and `SetCheck`, `DealEnd.CANCELLED`, the
   order states `ARRANGING`, `WAITING`, `MET` and `CANCELLED`, and the
   reputation events for cancelling.
2. 5 triệu becomes the line above which the app suggests meeting first.
   `MoneyKey.MEET_HINT` reads "Món trên 5 triệu nên hẹn gặp xem trực tiếp."
   It shows on Listing detail under the COD row, on Đăng tin and Kiểm tra tin
   under the delivery row, in Chat's console after the handshake, in "Quy tắc
   tiền" and in Home's COD sheet. `MoneyKey.MEET` and `MoneyKey.OVER_LIMIT`
   go. Posting has no "no way to hand over" problem.
3. Chat after the handshake: the agreed price, "Giao COD · xem hàng rồi mới
   trả", the hint above 5 triệu, and "Đặt COD", which opens Giao COD for the
   deal. The seller sees "Chờ {buyer} đặt COD". The stepper shows the COD
   phases: Thương lượng, Gửi hàng, Xem và nhận, Đánh giá.
4. A message that names a place carries it (`ThreadItem.Text.place`), and
   Chat shows the model's chip under the message: sparkle, the place, a map
   icon. Tapping it opens Google Maps
   (`https://www.google.com/maps/search/?api=1&query=<place>`). The simulated
   seller names a place when agreeing above 5 triệu ("Máy trên 5 triệu, tối
   nay 19h gặp ở sảnh Landmark 81 xem máy nhé?") and asks for COD at or below
   it ("Bạn đặt COD đi, mình gửi liền.").
5. At the COD door the buyer presses nothing. The shipper reports the parcel
   taken or refused, and the order follows. The simulator reports it taken
   a few seconds after the door; the debug order jumps reach the refused
   state. The buyer commands `ReceiveParcel` and `RefuseParcel` become carrier
   reports inside the fakes. The door page keeps the refusal sentence ("Không
   ưng thì từ chối nhận: …") and shows one "Tin ghi" row: the listing's claims
   and declared marks in one line, which opens a read-only sheet with each
   claim and how to check it, the marks with their close-ups, the
   declared-marks sentence, and the model's general tips under "Gợi ý chung,
   không phải điều {seller} cam kết", with no boxes to tick and no count.
6. The contract for checking: `Listing.claims: List<Claim>` with `Claim(icon,
   text, how)`, written by the seller's listing (fixtures for now), and the
   deal's general tips `Deal.tips: List<CheckTip>` with `CheckTip(id, text,
   icon, how?)`, which replace `CheckItem` and `Deal.checklist`.
7. Finished steps keep their own icon on primary, in `PhaseStepper` and in
   the order `Timeline`; a check would hide which step it was.
8. A rating adds an event line ("5 sao cho {person}") instead of the "Cảm ơn
   bạn" milestone; `MilestoneKind.RATED` goes. Once rated, Chat's console
   hides the stepper and reads "Đã xong" with the rating and "Máy có vấn
   đề?".
9. Listing detail's quick questions and "Gửi" in the offer sheet send as
   before and then open Chat for the deal; the "Đã gửi · Xem" snackbars go.
   The deal section shows one COD row ("COD, xem hàng trước", "Gửi từ
   {district} · trả tiền khi đã xem"), the hint above 5 triệu and "ShopNexus
   không giữ tiền và không nhận cọc."
10. Đăng tin and Kiểm tra tin show COD as the only delivery (no choice and no
    sheet), with the seller's two COD sentences and the hint above 5 triệu.
11. Fixtures: the iPhone 13 Pro is listed at 5.200.000 ₫; Tuấn Kiệt's counter
    is 5.100.000 ₫ after Khánh Linh's 4.900.000 ₫; the offer chips are 5,1,
    5, 4,9 and 4,8 tr; its price judgment is the new
    `PriceDirection.FAIR` ("Ngang giá thị trường", range 4,9 to 5,6 tr). The
    in-person deals become COD orders: Ngọc Hân's bike is placed and waits
    to be shipped; Gia Bảo's shelf is done. Every deal drops its meeting
    points; the notification "Ngọc Hân đồng ý hẹn …" and the meeting talk in
    the threads change to COD.
12. Smaller copy: Chào mừng promises "Giao tận nơi, xem hàng rồi mới trả";
    Điểm uy tín's rules drop the two cancellation rules; Tôi's due row has no
    meeting case; the bio hint reads "Bạn bán gì, ở khu nào".
13. Off-app sales still count: Tin của bạn's "Đánh dấu đã bán" stays.
14. Removed code goes with its strings, tests and screenshot goldens. ML Kit
    barcode scanning leaves the build; the QR drawing stays for the COD
    shipping code, and the camera's simulated mode stays for eKYC and video.

## Not in scope

The Go server, payments, a buyer's cancellation before the parcel leaves,
and the mockups (already done).
