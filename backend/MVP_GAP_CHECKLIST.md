# Checklist gap MVP backend SendFood

Status per 2026-11-08, branch `backend-mvp-hardening`. Dasar: prioritas P0/P1/P2 di [PRD](../docs/specs/PRD.md). Bukti tes: [TEST_EVIDENCE.md](TEST_EVIDENCE.md).

**Kesimpulan jujur: MVP/PWA BELUM siap pilot atau produksi.** Frontend/PWA belum ada, migrasi hardening belum diterapkan ke Supabase mana pun, audit NaN live untuk kolom baru belum dilakukan, Supabase Storage belum tersedia/teruji, dan enam keputusan bisnis belum diputuskan. Backend lulus tes **secara lokal** (Postgres lokal dan tumpukan Supabase Auth/GoTrue + PostgREST nyata); itu bukan Supabase cloud, bukan staging, dan bukan kesiapan pilot.

Legenda: [x] ada dan teruji lokal (Postgres lokal; bila disebut, juga GoTrue/PostgREST nyata), [~] ada tetapi tertutup/sementara/sebagian, [ ] belum ada atau belum terbukti.

## P0

- [x] Autentikasi: diverifikasi lokal dengan GoTrue v2.197.0 + PostgREST v16.5 nyata (signup, login, JWT, refresh rotation, logout, penolakan token palsu/kedaluwarsa); BUKAN Supabase cloud. Role awal `customer` walau metadata meminta admin; promosi role hanya lewat `provision_set_user_role`. Risiko: access token tetap valid sampai `exp` setelah logout.
- [x] Katalog: RLS publik toko aktif dan produk tersedia; `list_stores`, `search_products` dengan pagination.
- [ ] Keranjang: sepenuhnya sisi client (frontend belum ada).
- [~] Checkout/pembuatan pesanan COD: `create_order` dengan idempotency key, harga dihitung server; alur COD dan konkurensi teruji lewat HTTP nyata lokal. Tertutup per toko sampai ongkir/radius/koordinat diisi (`store_delivery_not_configured`); nilai di tes sintetis, bukan keputusan bisnis.
- [x] Status penjual: accept/reject/preparing/ready_for_pickup oleh seller pemilik toko.
- [~] Tugas/status driver: assignment hanya admin (fallback sementara); driver picked_up/delivered.
- [x] Kontrol akses: RLS, grant kolom, blok tulis langsung, guard role/toko; matriks RLS empat peran + anon teruji via HTTP dengan JWT asli (lokal).
- [ ] Frontend/PWA dan deployment: belum ada. Integrasi dengan Supabase cloud (bukan tumpukan lokal) belum dilakukan.
- [ ] Supabase Storage / unggah foto: tidak tersedia. Storage v1.90.0 butuh Node >= 26 (hanya Node 18/20/22/24 ada) sehingga tidak dijalankan; bukan P0; kontrak hanya `image_url` text; tidak ada bucket/policy. Perlu migrasi policy Storage yang diuji pada tumpukan ber-Storage.

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
| 5 | Aktor `completed` | `completion_actor` = `customer` / `seller` / `driver` | Ditutup: tanpa baris kebijakan `completed` ditolak `completion_policy_not_configured` untuk semua peran termasuk admin |
| 6 | Pencatatan COD | `cod_collection_recording_enabled=true`, `cod_collection_actor` = `driver` / `admin`; prosedur setoran/rekonsiliasi di luar sistem | Ditutup. `delivered`/`completed` tidak pernah menandai lunas; `record_cod_collection` menandai `verified` (arti COD: tunai diterima, bukan verifikasi transfer). Admin selalu boleh mencatat saat flag aktif, apa pun `cod_collection_actor` |

## Gap lain yang diketahui

- **Migrasi hardening belum diterapkan live.** Fondasi live; ledger live mencatatnya sebagai `20261107042649` (nama berkas `20261107000000`): ketidakcocokan yang diketahui. JANGAN memutar ulang atau mengedit fondasi di remote. Runbook di `README.md`; tidak ada staging.
- **Audit NaN live untuk kolom baru BELUM dilakukan** (`stores.delivery_fee`, `stores.service_radius_km`, `orders.subtotal/delivery_fee/total`, `order_items.unit_price_snapshot/line_total`). Audit sebelumnya hanya `products.price` (dilaporkan 0 oleh pengguna). Jangan asumsikan bersih; migrasi akan gagal tertutup (`23514`, rollback penuh) bila ada baris NaN. Preflight lengkap ada di `README.md`.
- Temuan NaN (statis, dikonfirmasi fixture lokal sebelum perbaikan): ongkir NaN menghasilkan total NaN, radius NaN menerima alamat ~60 km; diperbaiki di hardening maju (lihat `API_CONTRACT.md` dan `TEST_EVIDENCE.md`).
- Atomisitas hardening terbukti pada `psql` lokal (satu transaksi eksplisit; kegagalan terkunci 55P03 dalam ~5 detik). `psql -f` tanpa `ON_ERROR_STOP` keluar 0 saat gagal: wajib `ON_ERROR_STOP=1`. Perilaku SQL editor/`supabase db push` Supabase sungguhan belum diuji.
- Hasil lokal: lihat angka bertanggal di `TEST_EVIDENCE.md` (akan diperbarui setelah run final). CI dua-job (`runtime-tests`, `http-stack-tests`) belum pernah dijalankan di GitHub untuk commit terbaru; riwayat run lama (hanya job SQL): `41eb679` ([42342259072](https://github.com/aldiloop/sendfood/actions/runs/42342259072), [42342249122](https://github.com/aldiloop/sendfood/actions/runs/42342249122)) dan `22e5133` ([42342881893](https://github.com/aldiloop/sendfood/actions/runs/42342881893), [42342878043](https://github.com/aldiloop/sendfood/actions/runs/42342878043)).
- Docker/Supabase CLI tidak dipakai. Seluruh tes memakai biner lokal tanpa kontak ke Supabase cloud.
- Tidak ada notifikasi, pembayaran online, penugasan otomatis, rate limiting tingkat API, atau pemantauan/backup yang dikonfigurasi dari repo ini.
- Kunci `service_role` tidak pernah disimpan di repo; provisioning admin pertama dilakukan manual oleh operator tepercaya.
