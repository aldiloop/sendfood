# Checklist gap MVP backend SendFood

Status per akhir pekerjaan branch `backend-mvp-hardening`. Dasar: prioritas P0/P1/P2 di [PRD](../docs/specs/PRD.md).

**Kesimpulan jujur: MVP/PWA BELUM siap pilot.** Frontend/PWA belum ada di repository ini, migrasi hardening belum diterapkan ke Supabase mana pun, dan enam keputusan bisnis di bawah belum diputuskan. Yang sudah diuji hanya backend pada Postgres lokal sekali pakai (bukan Supabase sungguhan, bukan PostgREST/Auth asli).

Legenda: [x] ada dan teruji lokal, [~] ada tetapi tertutup/sementara, [ ] belum ada.

## P0

- [~] Autentikasi: bergantung pada Supabase Auth (tidak diuji, hanya ditiru shim `auth.uid()`). Role awal `customer`; promosi role hanya lewat `provision_set_user_role`.
- [x] Katalog: RLS publik toko aktif dan produk tersedia; `list_stores`, `search_products` dengan pagination.
- [ ] Keranjang: sepenuhnya sisi client (frontend belum ada).
- [~] Checkout/pembuatan pesanan COD: `create_order` dengan idempotency key, harga dihitung server. Tertutup per toko sampai ongkir/radius/koordinat diisi (`store_delivery_not_configured`).
- [x] Status penjual: accept/reject/preparing/ready_for_pickup oleh seller pemilik toko.
- [~] Tugas/status driver: assignment hanya admin (fallback sementara); driver picked_up/delivered.
- [x] Kontrol akses: RLS, grant kolom, blok tulis langsung, guard role/toko (110 tes negatif akses).
- [ ] Frontend/PWA, deployment, dan integrasi nyata dengan Supabase Auth/PostgREST.

## P1

- [x] Filter/pengurutan katalog (nama, jarak, ongkir, harga).
- [x] Riwayat pesanan: `list_my_orders` (order toko nonaktif tetap tampil; `store_name` null untuk non-admin/non-pemilik).
- [~] Transfer manual: DITOLAK (`manual_transfer_not_configured`). Tidak ada workflow verifikator, bukti, atau rekening; flag `manual_transfer_enabled` pun tidak membukanya.
- [~] Dashboard admin: hanya RPC dasar (`admin_set_store_active`, `admin_set_store_delivery_config`, `admin_set_product_available`, `admin_get_policies`, `assign_order_driver`) dan `admin_audit_log`. Tidak ada UI, laporan, atau manajemen user selain provisioning tepercaya.
- [~] Alamat tersimpan: tabel `customer_addresses` minimal (maks. 10 per customer).

## P2 (ditunda)

- [ ] Rating, notifikasi lanjutan, analitik, promosi. Tidak ada tabel/field rating.

## Keputusan wajib sebelum pilot

Semua kebijakan di bawah dikunci (fail closed) sampai operator mengaturnya lewat `provision_set_policy` atau RPC admin dari lingkungan tepercaya.

| # | Keputusan | Konfigurasi / kunci yang dibutuhkan | Keadaan saat ini |
|---|---|---|---|
| 1 | Wilayah pilot, rumus ongkir, radius, metode jarak | Per toko: `delivery_fee`, `service_radius_km`, koordinat toko via `admin_set_store_delivery_config`. Putuskan juga apakah tarif tetap cukup dan apakah Haversine garis lurus diterima | Tarif tetap per toko + Haversine (asumsi sementara); toko tanpa konfigurasi tidak bisa dipesan |
| 2 | Mekanisme assignment driver | Pilih: admin saja, penjual, atau driver self-claim (butuh RPC baru) | Hanya `assign_order_driver` oleh admin |
| 3 | Verifikator transfer manual, bukti, rekening | Aktor verifikasi, format bukti (tabel/storage), info rekening, `manual_transfer_enabled`, plus pengembangan workflow | Ditolak; workflow belum ada |
| 4 | Pembatalan dan refund | `cancellation_enabled=true`, `cancellation_allowed_statuses` (mis. `pending_seller,accepted`), aturan refund | Ditutup. `payment_status` tidak disentuh saat batal; refund belum ada |
| 5 | Aktor `completed` | `completion_actor` = `customer` / `seller` / `driver` | Default `customer` (konvensi sementara, belum disetujui) |
| 6 | Pencatatan COD | `cod_collection_recording_enabled=true`, `cod_collection_actor` = `driver` / `admin`; prosedur setoran/rekonsiliasi di luar sistem | Ditutup. `delivered`/`completed` tidak pernah menandai lunas; `record_cod_collection` menandai `verified` (arti COD: tunai diterima, bukan verifikasi transfer). Admin selalu boleh mencatat saat flag aktif, apa pun `cod_collection_actor` |

## Gap lain yang diketahui

- Migrasi hardening belum diterapkan ke staging/produksi; langkah ada di `README.md`. Tes belum dijalankan terhadap Supabase sungguhan (staging).
- Uji lintas peran dengan JWT/Auth asli dan PostgREST belum dilakukan; harness meniru lewat `SET ROLE` dan `request.jwt.claims`.
- Docker/Supabase CLI tidak dipakai/dijalankan di sandbox pengembangan.
- Workflow CI `.github/workflows/backend-tests.yml` ditulis tetapi **belum pernah dijalankan** (hanya sintaks YAML yang diperiksa lokal).
- Tidak ada notifikasi, pembayaran online, penugasan otomatis, rate limiting tingkat API, atau pemantauan/backup yang dikonfigurasi dari repo ini.
- Kunci `service_role` tidak pernah disimpan di repo; provisioning admin pertama harus dilakukan manual oleh operator tepercaya.
