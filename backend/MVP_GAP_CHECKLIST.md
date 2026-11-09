# Checklist gap MVP backend SendFood

Status per 2026-11-09, branch `backend-mvp-hardening`. Dasar: prioritas P0/P1/P2 di [PRD](../docs/specs/PRD.md). Bukti tes: [TEST_EVIDENCE.md](TEST_EVIDENCE.md).

**Kesimpulan jujur: MVP/PWA BELUM siap pilot atau produksi, dan backend belum final.** Frontend/PWA belum ada, migrasi hardening tidak diterapkan oleh PR ini ke Supabase mana pun, audit NaN produksi untuk kolom baru belum dilakukan, gate hosted masih diblokir (lihat [Gate hosted](#gate-hosted-yang-masih-diblokir)), Supabase Storage belum diimplementasi (lihat [Storage](#storage-unggah-foto-belum-diimplementasi)), dan enam keputusan bisnis belum diputuskan. Backend lulus tes **secara lokal** (Postgres lokal dan tumpukan Supabase Auth/GoTrue + PostgREST nyata); itu bukan Supabase cloud, bukan staging, dan bukan kesiapan pilot.

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

## P1

- [ ] Unggah foto produk (IPD §5 P1 butir 4; TRD §1 "Supabase Storage bila diperlukan"). Bukan P0. Belum diimplementasi; lihat [Storage](#storage-unggah-foto-belum-diimplementasi).
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

- **Migrasi hardening tidak diterapkan oleh PR ini ke Supabase mana pun.** Fondasi live di produksi; ledger live mencatatnya sebagai `20261107042649` (nama berkas `20261107000000`): ketidakcocokan yang diketahui. JANGAN memutar ulang atau mengedit fondasi di remote. Runbook di `README.md`. Proyek staging terpisah kini ada; keadaan schema dan ledger-nya belum diverifikasi.
- **Audit NaN produksi untuk kolom baru BELUM dilakukan** (`stores.delivery_fee`, `stores.service_radius_km`, `orders.subtotal/delivery_fee/total`, `order_items.unit_price_snapshot/line_total`). Audit produksi sebelumnya hanya `products.price` (dilaporkan 0 oleh pengguna). Di staging, preflight lengkap dari `README.md` mengembalikan 0 untuk delapan kolom, tetapi visibilitas semua baris belum terbukti (lihat gate di bawah). Jangan asumsikan bersih; migrasi akan gagal tertutup (`23514`, rollback penuh) bila ada baris NaN.
- Temuan NaN (statis, dikonfirmasi fixture lokal sebelum perbaikan): ongkir NaN menghasilkan total NaN, radius NaN menerima alamat ~60 km; diperbaiki di hardening maju (lihat `API_CONTRACT.md` dan `TEST_EVIDENCE.md`).
- Atomisitas hardening terbukti pada `psql` lokal (satu transaksi eksplisit; kegagalan terkunci 55P03 dalam ~5 detik). `psql -f` tanpa `ON_ERROR_STOP` keluar 0 saat gagal: wajib `ON_ERROR_STOP=1`. Perilaku SQL editor/`supabase db push` Supabase sungguhan belum diuji.
- Hasil lokal: lihat angka bertanggal di `TEST_EVIDENCE.md`. CI dua-job (`runtime-tests`, `http-stack-tests`) lulus di GitHub pada `e798fab` (empat check-run sukses dari run [42491401976](https://github.com/aldiloop/sendfood/actions/runs/42491401976) dan [42491398283](https://github.com/aldiloop/sendfood/actions/runs/42491398283)); commit dokumen sesudahnya akan menjalankan CI lagi. Riwayat run lama (hanya job SQL): `41eb679` ([42342259072](https://github.com/aldiloop/sendfood/actions/runs/42342259072), [42342249122](https://github.com/aldiloop/sendfood/actions/runs/42342249122)) dan `22e5133` ([42342881893](https://github.com/aldiloop/sendfood/actions/runs/42342881893), [42342878043](https://github.com/aldiloop/sendfood/actions/runs/42342878043)).
- Docker/Supabase CLI tidak dipakai. Seluruh tes memakai biner lokal tanpa kontak ke Supabase cloud.
- Tidak ada notifikasi, pembayaran online, penugasan otomatis, rate limiting tingkat API, atau pemantauan/backup yang dikonfigurasi dari repo ini.
- Kunci `service_role` tidak pernah disimpan di repo; provisioning admin pertama dilakukan manual oleh operator tepercaya.

## Gate hosted yang masih diblokir

Status per 2026-11-09. Fakta di bawah berasal dari dua koneksi MCP Supabase tersimpan (satu ke produksi, satu ke staging). Project ref dan endpoint sengaja tidak ditulis di repo. Selain dua query yang disebut, tidak ada query hosted lain, dan tidak ada tulis atau migrasi.

| Gate | Bukti yang ada | Yang belum terbukti | Syarat menutup |
|---|---|---|---|
| Pencabutan token lama yang luas (koneksi lama `supabase-sendfood-readonly`) | Tidak ada | Token lama belum dikonfirmasi dicabut | Pemilik akun Supabase mengonfirmasi pencabutan di dashboard. Sampai itu terjadi, **semua tulis ke staging dilarang** |
| Produksi read-only | `get_project_url` lewat koneksi produksi menunjuk proyek yang diharapkan; `select current_setting('transaction_read_only');` mengembalikan `on`. Koneksi itu tidak menyediakan `apply_migration`, `deploy_edge_function`, atau operasi branch; `execute_sql` tetap tersedia | Hasil `on` hanya berlaku untuk transaksi query itu dan dapat diubah oleh sesi (`set transaction read write`) bila role-nya punya hak tulis. Penegakan di tingkat role/privilege koneksi belum diperiksa | Operator memastikan koneksi produksi memakai role read-only. Pemeriksaan ini butuh query hosted baru, jadi perlu persetujuan |
| Preflight NaN staging dengan visibilitas semua baris | Query persis dari `README.md` (bagian Preflight NaN) dijalankan sekali di staging: 0 untuk kedelapan kolom | Role sesi MCP tidak diperiksa. Bila sesi tunduk RLS, angka 0 bisa menyesatkan (lihat peringatan di `README.md`) | Jalankan ulang sebagai role yang terbukti melihat semua baris (`postgres`/`service_role`), atau buktikan role sesi itu, dengan persetujuan |
| Preflight NaN produksi kolom baru | Hanya `products.price` (dilaporkan 0 oleh pengguna, sebelum sesi ini) | Tujuh kolom lainnya | Jalankan preflight sebagai role yang melihat semua baris, dengan persetujuan |
| Koneksi staging bukan read-only | Koneksi staging menyediakan tool tulis (`apply_migration`, `execute_sql`, `deploy_edge_function`, operasi branch) | Tidak ada pembatasan scope selain project ref | Pakai hanya untuk baca sampai gate pencabutan token tertutup dan penerapan hardening disetujui |
| Keadaan schema/ledger staging | Delapan kolom preflight ada di staging (query tidak gagal) | Apakah staging berisi fondasi saja, sudah hardening, atau ledger-nya sama dengan produksi | Periksa ledger lewat jalur read-only yang disetujui sebelum menerapkan apa pun |

## Storage (unggah foto): belum diimplementasi

Keputusan saat ini: **Storage sengaja tidak diimplementasi** di PR ini. Tidak ada bucket, policy, migrasi `storage.*`, atau tes. Ini bukan kelalaian. Semantik yang dibutuhkan belum ditetapkan di sumber, dan lingkungan tes lokal tidak bisa menjalankan Storage.

Dasar dari sumber:

- Prioritas: IPD §5 menaruh "Upload foto produk" di **P1**; TRD §1 menyebut Storage "bila diperlukan untuk foto produk/avatar"; PRD P0 tidak memuat unggah foto. MVP P0 bisa berjalan dengan `image_url` teks dan placeholder (DBD §6).
- Kolom yang ada: `profiles.avatar_url`, `stores.image_url`, `products.image_url` (semua `text` tanpa constraint, `20261107000000_..._foundation.sql`). Tidak ada spesifikasi path, bucket, ukuran, atau tipe file.
- Visibilitas data yang sudah berlaku (RLS fondasi): profil hanya terbaca oleh pemiliknya dan admin (`profiles_select_self_or_admin`); produk hanya publik bila `is_available` dan tokonya aktif; toko nonaktif hanya terlihat oleh pemilik dan admin. Bucket publik akan membuat foto produk tersembunyi, toko nonaktif, dan avatar tetap dapat diambil lewat URL, jadi bertentangan dengan RLS ini kecuali pemilik menerimanya secara eksplisit.
- Siklus hidup: menghapus produk membuat `order_items.product_id` menjadi `null` (`on delete set null`); item pesanan tidak menyimpan snapshot foto. Tidak ada aturan apakah objek foto ikut dihapus, disimpan, atau diganti.
- Lingkungan: Supabase Storage v1.90.0 butuh Node >= 26. Sandbox per 2026-11-09 hanya punya Node 18.20.8, 20.20.2, 22.23.4, 24.22.1, jadi policy Storage tidak bisa diuji lokal terhadap layanan Storage nyata.
- Tidak ada draf Storage di branch ini, di worktree, atau di stash per 2026-11-09.

Keputusan yang dibutuhkan dari pemilik produk:

1. Aset mana yang masuk cakupan: foto produk saja (sesuai IPD P1), atau juga foto toko dan avatar.
2. Visibilitas baca: publik lewat URL (lebih sederhana, tetapi foto produk/toko tersembunyi tetap bisa diambil), atau privat dengan signed URL yang mengikuti RLS katalog.
3. Siapa yang boleh unggah, ganti, dan hapus: seller pemilik toko saja, atau juga admin (moderasi).
4. Siklus hidup: apa yang terjadi pada objek saat produk dihapus, produk dinonaktifkan, toko dinonaktifkan, atau foto diganti.
5. Batas file: tipe MIME yang diizinkan dan ukuran maksimum.
6. Apakah `image_url` harus dibatasi ke origin Storage proyek setelah unggah tersedia.

**Usulan least-privilege (belum disetujui, bukan keputusan):**

- Foto produk/toko di satu bucket dengan path `<store_id>/<product_id|store>/<nama-acak>`. Insert/update/delete hanya untuk `authenticated` yang `stores.owner_id = auth.uid()` untuk `<store_id>` di path dan ber-role `seller`. Tidak ada tulis untuk anon.
- Bila foto produk tersembunyi tidak boleh bocor: bucket privat, baca lewat signed URL berumur pendek yang hanya diterbitkan untuk baris yang lolos RLS katalog. Bucket publik hanya bila pemilik menyatakan menerima kebocoran tersebut.
- Avatar: tunda, atau bucket privat yang hanya terbaca pemilik dan admin, konsisten dengan RLS `profiles`.
- MIME allowlist `image/jpeg`, `image/png`, `image/webp` dan batas ukuran di konfigurasi bucket. Penghapusan objek dilakukan eksplisit, tidak lewat cascade diam-diam.
- Migrasi maju baru plus tes pada tumpukan lokal yang memuat Storage (butuh Node >= 26), sebelum diterapkan ke hosted mana pun.
