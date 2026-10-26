# Decisions for module order (server2)

Date: 2026-10-26. The user's answers, recorded before the order spec is
written. Later the same day the user dropped carrier integration from the
first version: every order is self-shipped and reported by the seller, so
the lines below about GHTK and GHN orders, webhooks and polling wait for a
later integration. `2026-10-26-server2-order-design.md` holds what is
built. Sources for the current app2 design: `app2/mohinh.md` and
`app2/docs/superpowers/specs/2026-10-26-seller-creates-cod-design.md`.

- A listing is reserved from the moment the seller creates the waybill
  (through GHTK/GHN, or by recording a self-shipped parcel). An agreed offer
  reserves nothing.
- A parcel the buyer refuses at the door releases the reservation at once;
  the listing is on sale again while the parcel travels back.
- Other buyers do not see a reserved listing in search, the feed or the
  seller's shop. Its detail page, opened from a link, a saved list or a
  chat, shows "Đang giao cho người mua" and offers only "Lưu tin" with "Báo
  bạn nếu tin mở bán lại". A saved card dims with "Đang giao". Other buyers'
  chats about it get the line "Món này đang được giao cho người mua khác"
  and a locked console. The seller still sees it under Đang bán with its
  order row.
- When a reservation ends with the listing back on sale, the people who
  saved it and the people who chatted about it are told "{title} đã mở bán
  lại".
- Until a waybill exists the listing stays on sale and several buyers may
  ask for COD. Creating the waybill for one cancels the others' requests
  with "Người bán đã gửi cho người khác".
- No buyer confirms receipt: ShopNexus offers no after-sales (no refunds, no
  product claims; only reports about users). A GHTK or GHN order follows the
  carrier. A self-shipped order (SPX, J&T, Viettel Post, any carrier
  ShopNexus does not integrate) follows the seller: recording the shipment
  reserves the listing, "Đã giao xong" sells it to the buyer, "Hàng bị hoàn"
  puts it back on sale. There is no deadline and no "not received" report;
  a seller who lies is reported as a user.
- The buyer's rating stands in for a receipt. It opens once the waybill
  exists.
- GHTK and GHN orders follow the carrier's webhooks, and a poll of each open
  order checks the same status in case a webhook is lost or late. The poll
  also reads the COD remittance status.
