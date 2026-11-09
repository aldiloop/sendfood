# SendFood Backend API Contract (MVP, contract-first)

## Status integrasi

Kontrak ini sesuai migrasi `20261107000000_sendfood_backend_foundation.sql` (sudah diterapkan di proyek Supabase MVP) ditambah migrasi maju `20261108000000_sendfood_backend_mvp_hardening.sql`.

- **Hardening tidak diterapkan oleh PR ini ke Supabase mana pun.** Proyek staging kini ada, tetapi keadaan schema-nya (fondasi saja atau sudah hardening) belum diverifikasi. Frontend boleh dibangun *contract-first*, tetapi RPC/kolom yang hanya ada di hardening (`create_order` 8 argumen, `list_stores`, `search_products`, `list_my_orders`, `record_cod_collection`, `admin_*`, `customer_addresses`) tidak boleh diasumsikan aktif di lingkungan hosted mana pun. Gate hosted yang masih terbuka: [MVP_GAP_CHECKLIST.md](MVP_GAP_CHECKLIST.md#gate-hosted-yang-masih-diblokir).
- Diverifikasi **lokal** terhadap Postgres 16.2 sekali pakai, lalu terhadap tumpukan HTTP nyata: Supabase Auth (GoTrue) v2.197.0 + PostgREST v16.5 (bukan Supabase cloud). Lihat `TEST_EVIDENCE.md` dan `README.md`.
- Supabase Storage **belum diimplementasi**: tidak ada bucket, policy, maupun tes. Kontrak hanya memakai `image_url`/`avatar_url` (text); unggah foto belum tersedia. Keputusan yang dibutuhkan sebelum Storage dibuat: [MVP_GAP_CHECKLIST.md](MVP_GAP_CHECKLIST.md#storage-unggah-foto-belum-diimplementasi).
- Backend lokal yang lulus tes **bukan** kesiapan pilot/produksi: keputusan bisnis masih terbuka dan frontend belum ada.

Gunakan Supabase Auth untuk sesi. Katalog menggunakan akses tabel yang dilindungi RLS; checkout, perubahan status, dan assignment driver hanya melalui RPC. Jangan menaruh `service_role` key di browser.

## Entitas utama

- `profiles`: dibuat otomatis saat akun Supabase Auth dibuat. Role awal selalu `customer`; metadata dari client tidak dapat menaikkan role.
- `stores`: profil penjual, katalog publik hanya menampilkan toko aktif. `delivery_fee`, `service_radius_km`, koordinat toko, dan status aktif diatur oleh operator tepercaya.
- `products`: katalog per toko. Produk yang tidak tersedia tidak tampil ke publik dan tidak dapat dipesan.
- `orders`, `order_items`, `order_status_history`: data pesanan dan snapshot harga/nama untuk riwayat.

## Akses data dan RLS

| Aktor | Akses yang diizinkan |
|---|---|
| Anon | Baca toko aktif dan produk tersedia dari toko aktif |
| Customer | Profil sendiri, katalog publik, pesanan/item/status miliknya; membuat pesanan melalui `create_order` |
| Seller | Profil sendiri, toko dan produk miliknya, serta pesanan toko tersebut; memperbarui produk dan transisi status seller yang sah |
| Driver | Pesanan yang ditugaskan kepadanya dan transisi pengantaran yang sah |
| Admin | Baca data operasional dan gunakan RPC assignment/status; perubahan role/konfigurasi operasional tetap melalui lingkungan tepercaya |

Tidak ada akses tulis langsung dari client ke tabel orders, items, atau status history. Role profil tidak dapat diedit melalui client. RLS tetap berlaku meskipun UI menyembunyikan aksi.

## RPC

### Membuat pesanan COD

`supabase.rpc('create_order', { ... })`

```json
{
  "p_store_id": "<uuid toko>",
  "p_items": [
    { "product_id": "<uuid produk>", "quantity": 2 }
  ],
  "p_delivery_address": "Alamat lengkap",
  "p_delivery_latitude": -6.2,
  "p_delivery_longitude": 106.8,
  "p_delivery_note": "Opsional",
  "p_payment_method": "cod",
  "p_idempotency_key": "<8-100 karakter dari A-Z a-z 0-9 _. : - , unik per percobaan checkout>"
}
```

`p_idempotency_key` (argumen ke-8, opsional di sisi database) **wajib selalu dikirim oleh client**. Kunci yang sama dari customer yang sama dengan payload identik (toko, item produk dan quantity, alamat, koordinat, catatan; spasi di tepi alamat/catatan diabaikan) mengembalikan pesanan yang sudah ada tanpa membuat duplikat (aman untuk klik ganda/retry). Kunci yang sama dengan payload berbeda (toko, item, alamat, koordinat, atau catatan) ditolak `idempotency_key_conflict`; buat kunci baru bila keranjang berubah. Replay hanya membandingkan payload dan mengembalikan pesanan lama apa adanya: status toko, ketersediaan, dan harga saat ini tidak diperiksa ulang (toko yang kini nonaktif tetap mengembalikan pesanan lama; kunci baru ke toko nonaktif ditolak `store_not_available`). kunci tidak valid ditolak `invalid_idempotency_key`. Panggilan tanpa kunci tidak di-deduplikasi, hanya diserialkan per customer. Buat kunci baru (mis. UUID) per keranjang/percobaan checkout dan pakai ulang hanya saat retry.

Respons berupa satu baris berisi `order_id`, `order_code`, `subtotal`, `delivery_fee`, `total`, `payment_method`, `payment_status`, dan `order_status`. Harga produk, subtotal, biaya, total, serta snapshot item diambil/dihitung di backend, bukan dipercaya dari payload.

Syarat: sesi customer aktif; 1–50 item produk unik dari toko yang sama; kuantitas 1–99; produk/toko aktif; alamat dan koordinat pengantaran valid. Checkout akan ditolak sampai operator mengisi biaya pengiriman tetap per toko, radius layanan, dan koordinat toko. Jarak saat ini dihitung garis lurus dengan Haversine. Ini konfigurasi/asumsi sementara yang harus disetujui sebelum pilot.

Hanya COD yang aktif. `manual_transfer` ditolak dengan `manual_transfer_not_configured` sampai pihak verifikasi dan alur bukti transfer diputuskan.

### Mengubah status pesanan

`supabase.rpc('change_order_status', { p_order_id, p_new_status, p_note })`

Transisi:

- `pending_seller` → `accepted` atau `rejected` (seller toko; alasan wajib untuk penolakan)
- `accepted` → `preparing` (seller toko)
- `preparing` → `ready_for_pickup` (seller toko)
- `ready_for_pickup` → `picked_up` → `delivered` (driver yang ditugaskan)
- `delivered` → `completed`: **tertutup secara default**. Migrasi tidak membuat baris `completion_actor`; selama baris itu tidak ada atau nilainya bukan `customer`/`seller`/`driver`, `completed` ditolak `completion_policy_not_configured` untuk SEMUA peran (termasuk admin) sampai operator menyetel `completion_actor` secara eksplisit lewat `provision_set_policy('completion_actor', 'customer'|'seller'|'driver')` (hanya `service_role`/`postgres`). Order dan history tidak berubah saat ditolak. Setelah dikonfigurasi: hanya aktor itu (customer pemilik / seller pemilik toko / driver yang ditugaskan) dan admin (override kontrak) yang boleh. Aktor mana yang dipakai adalah keputusan bisnis yang belum ditetapkan.
- Admin dapat melakukan transisi yang sama, tetapi tidak dapat melompati tahapan.

`cancelled` ditolak dengan `cancellation_policy_not_configured` selama `ops_policy.cancellation_enabled` bukan `true` atau `cancellation_allowed_statuses` kosong (default: tertutup). Jika operator mengaktifkannya: hanya dari status yang terdaftar (selain itu `status_transition_not_allowed`), alasan wajib (`cancellation_reason_required`), dan aktor yang boleh adalah admin, customer pemilik, atau seller toko. Pembatalan **tidak** mengubah `payment_status`; refund belum ada. Setiap transisi sah dicatat di `order_status_history`.

### Assignment driver

`supabase.rpc('assign_order_driver', { p_order_id, p_driver_id })`

Hanya admin; order harus berstatus `accepted`, `preparing`, atau `ready_for_pickup`; profil target harus ber-role `driver`. Ini fallback admin-only sementara, bukan keputusan final antara admin/penjual/driver self-claim.

### Pencatatan COD

`supabase.rpc('record_cod_collection', { p_order_id, p_note })` mengembalikan `payment_status` (`verified`). Untuk COD, `verified` berarti uang tunai sudah dicatat diterima; bukan verifikasi transfer bank, jadi laporan jangan membacanya sebagai bukti transfer. Bila flag `cod_collection_recording_enabled` aktif, admin selalu boleh mencatat, apa pun nilai `cod_collection_actor`.

Ditolak `cod_collection_policy_not_configured` sampai operator mengatur `cod_collection_recording_enabled=true` dan `cod_collection_actor` (`driver` atau `admin`). Admin selalu dapat; driver hanya jika aktor `driver` dan driver ditugaskan pada pesanan. Syarat: pesanan COD (`order_not_cod`), berstatus `delivered`/`completed` (`order_not_delivered`), dan `payment_status` masih `unpaid` (`payment_already_recorded`). **Status `delivered`/`completed` tidak pernah mengubah pembayaran menjadi lunas**; hanya aksi eksplisit ini yang melakukannya, dan dicatat di `order_status_history` (`cod_collected`).

### Katalog dan pencarian (publik, SECURITY INVOKER, RLS tetap berlaku)

- `list_stores({ p_query, p_latitude, p_longitude, p_sort, p_limit, p_offset })`: `p_sort` = `name` | `nearest` | `farthest` | `delivery_fee`. Hanya toko aktif. Mengembalikan `distance_km` dan `within_service_radius` (null jika koordinat/radius tidak tersedia).
- `search_products({ p_query, p_store_id, p_min_price, p_max_price, p_latitude, p_longitude, p_sort, p_limit, p_offset })`: hanya produk tersedia dari toko aktif; mengembalikan nama toko, biaya kirim, jarak, dan `within_service_radius`.
- Error: `search_query_too_long`, `invalid_pagination`, `invalid_sort`, `valid_coordinates_required`, `location_required_for_sort` (sort jarak tanpa koordinat), `invalid_price_range`.

### Riwayat pesanan

`list_my_orders({ p_status, p_limit, p_offset })`: pesanan milik pemanggil sesuai perannya (customer/seller/driver/admin) lengkap dengan `items` (jsonb). Pesanan dari toko yang sudah dinonaktifkan tetap muncul; `store_name` bernilai `null` untuk customer/driver karena RLS menyembunyikan toko nonaktif (admin dan pemilik toko tetap melihat nama). Error: `authentication_required`, `invalid_pagination`.

### Alamat tersimpan

Tabel `customer_addresses` (label, address, latitude, longitude, note) dengan RLS: customer hanya mengakses miliknya. Insert/update memakai kolom terbatas; batas jumlah alamat per customer (maks. 10) menghasilkan `address_limit_reached`.

### RPC admin (hanya role admin; selain itu `admin_role_required`)

- `admin_set_store_active(p_store_id, p_active)`: `store_not_found`, `invalid_argument`.
- `admin_set_store_delivery_config(p_store_id, p_delivery_fee, p_service_radius_km, p_latitude, p_longitude)`: `invalid_delivery_config`, `valid_coordinates_required`, `store_not_found`.
- `admin_set_product_available(p_product_id, p_available)`: `product_not_found`, `invalid_argument`.
- `admin_get_policies()`: daftar `key`/`value` dari `ops_policy`.

Perubahan admin dicatat di `admin_audit_log` (admin dapat membaca). Seller tidak dapat mengubah `delivery_fee`, radius, status aktif, atau lokasi toko (`store_operational_field_forbidden`, `store_location_locked`); produk dibatasi pada kolom yang diizinkan.

### Provisioning tepercaya (BUKAN untuk client)

`provision_set_user_role(p_user_id, p_role, p_reason)` dan `provision_set_policy(p_key, p_value)` hanya dapat dieksekusi `service_role`/`postgres`; anon/authenticated ditolak oleh hak akses. Jangan dipanggil dari browser. Kunci kebijakan valid: `completion_actor` (`customer|seller|driver`), `cancellation_enabled`, `manual_transfer_enabled`, `cod_collection_recording_enabled` (`true|false`), `cancellation_allowed_statuses` (daftar dipisah koma dari `pending_seller,accepted,preparing,ready_for_pickup`), `cod_collection_actor` (`driver|admin`). Kesalahan: `invalid_policy_value`, `unknown_policy_key`, `profile_not_found`. Catatan: `manual_transfer_enabled=true` pun belum membuka transfer, karena workflow verifikasi/bukti belum ada; `create_order` tetap menolak `manual_transfer`.

## Autentikasi dan contoh pemanggilan (tanpa rahasia)

Placeholder: `<SUPABASE_URL>` dan `<SUPABASE_ANON_KEY>` (kunci publik/publishable) berasal dari env; jangan tulis nilai asli di repo. `service_role` tidak pernah dipakai di client.

```js
import { createClient } from '@supabase/supabase-js'
const supabase = createClient(import.meta.env.VITE_SUPABASE_URL, import.meta.env.VITE_SUPABASE_ANON_KEY)

await supabase.auth.signUp({ email: '<email>', password: '<password>' })
const { data: s } = await supabase.auth.signInWithPassword({ email: '<email>', password: '<password>' })
await supabase.auth.refreshSession()          // memutar refresh token
const { data: u } = await supabase.auth.getUser()   // validasi ke server Auth
await supabase.auth.signOut()
```

Jalur HTTP mentah (relatif terhadap `<SUPABASE_URL>`; header `apikey: <SUPABASE_ANON_KEY>`, sesudah login tambah `Authorization: Bearer <access_token>`):

```
POST /auth/v1/signup                       {"email":"<email>","password":"<password>"}
POST /auth/v1/token?grant_type=password    {"email":"<email>","password":"<password>"}
POST /auth/v1/token?grant_type=refresh_token  {"refresh_token":"<refresh_token>"}
POST /auth/v1/logout
GET  /auth/v1/user
POST /rest/v1/rpc/<nama_rpc>               {"p_arg": ...}
GET  /rest/v1/<tabel>?select=kolom
```

Perilaku terverifikasi lokal (GoTrue v2.197.0 nyata):

- `signUp` selalu membuat `profiles.role = customer`, juga bila metadata klien berisi `{"role":"admin"}`; `PUT /auth/v1/user` dengan `data.role` tidak mengubah role aplikasi, dan `app_metadata` tidak dapat ditulis user. Signup ganda tidak membuat profil kedua.
- Access token: JWT HS256, `role=authenticated`, `aud=authenticated`, `sub` = id user, masa berlaku 3600 detik pada setup lokal.
- Password salah / email tidak dikenal: HTTP 400; password terlalu pendek: 422.
- PostgREST menjawab 401 (`PGRST30x`) untuk token dengan secret salah, `alg: none`, payload diubah (`sub`/`role`), kedaluwarsa, atau sampah. `GET /auth/v1/user` menolak token diubah/kedaluwarsa.
- Rotasi refresh token: memakai ulang token induk langsung mengembalikan sesi aktif yang sama (toleransi GoTrue); memakai token yang lebih lama ditolak 400 `refresh_token_already_used` dan seluruh keluarga token dicabut (token terbaru pun kemudian `refresh_token_already_used`).
- **Logout dan access token:** `signOut` mencabut refresh token (memakainya lagi: 400 `refresh_token_not_found`) dan `GET /auth/v1/user` menjawab 403, **tetapi access token yang sudah terbit tetap diterima PostgREST sampai `exp`** (JWT stateless). Ini risiko yang didokumentasikan: jaga `exp` tetap pendek di pengaturan Auth, dan jangan menganggap logout langsung memutus akses data.

## Pemetaan error HTTP (via PostgREST)

| Kelas | HTTP | Isi body | Catatan |
|---|---|---|---|
| Pengecualian RPC aplikasi (`raise exception`, mis. `invalid_sort`, `store_delivery_not_configured`) | 400 | `{"code":"P0001","message":"<snake_case>", ...}` | Tampilkan pesan ramah berdasarkan `message`; jangan tampilkan mentah |
| Pelanggaran constraint (mis. harga NaN, kolom `*_not_nan`) | 400 | `code: "23514"` | Nama constraint ada di `message` |
| Tanpa hak eksekusi/tabel, anon | 401 | `code: "42501"` | Mis. anon memanggil `create_order` |
| Tanpa hak eksekusi/tabel, authenticated | 403 | `code: "42501"` | Mis. `PATCH profiles` kolom `role`, `provision_*` |
| JWT tidak valid/kedaluwarsa | 401 | `code: "PGRST30x"` | Minta login ulang / refresh |
| `PATCH`/`DELETE` yang difilter RLS | 200 `[]` (dengan `Prefer: return=representation`) atau 204 | kosong | **Nol baris terpengaruh, bukan error**: periksa jumlah baris yang kembali |
| Auth (GoTrue) gagal | 400/422/403 | `error_code`/`msg` GoTrue | Lihat bagian Autentikasi |

## Bentuk kembalian RPC lewat HTTP (terverifikasi)

| RPC | Bentuk JSON |
|---|---|
| `create_order` | **array** berisi satu objek `{order_id, order_code, subtotal, delivery_fee, total, payment_method, payment_status, order_status}` (ambil `data[0]`) |
| `change_order_status` | string JSON status baru, mis. `"accepted"` |
| `assign_order_driver` | string uuid driver |
| `admin_set_store_active`, `admin_set_product_available` | boolean |
| `admin_set_store_delivery_config` | `void`: HTTP 204 atau 200 tanpa isi |
| `admin_get_policies` | array `{key, value}` |
| `record_cod_collection` | string `"verified"` |
| `list_my_orders` | array; `items` = array `{product_id, name, unit_price, quantity, line_total}` |
| `list_stores`, `search_products` | array baris sesuai signature di bawah |

## Matriks peran (terverifikasi lewat HTTP dengan JWT asli, lokal)

| Aktor | Boleh | Tidak boleh |
|---|---|---|
| Anon | Baca toko aktif dan produk tersedia; `list_stores`, `search_products` | Profil, order, item, riwayat status, alamat, `ops_policy`, audit; semua tulis |
| Customer | Hanya profil, order, item, riwayat, dan alamat miliknya; `create_order` | Menyentuh alamat orang lain (0 baris); memalsukan `customer_id`; membuat toko/produk; tulis langsung ke order |
| Seller | Hanya order toko sendiri; toko nonaktif miliknya terlihat oleh pemilik saja; edit deskripsi toko sendiri; produk toko sendiri | Mengubah `is_active`, `delivery_fee`, `service_radius_km`, `owner_id`, lokasi toko aktif; menyentuh toko/produk lain; memindah `store_id` produk; harga NaN (`23514`); mengaktifkan toko sendiri |
| Driver | Hanya order yang ditugaskan dan itemnya | Alamat tersimpan; order lain; menugaskan diri sendiri |
| Admin | Baca semua order, profil, audit log; RPC `admin_*`; `assign_order_driver` | Membaca tabel `ops_policy` langsung (pakai `admin_get_policies`); menulis order langsung; mengubah role lewat PATCH |

Tulis langsung ke `orders`, `order_items`, `order_status_history` ditolak untuk keempat peran; total tabel tidak berubah.

Permukaan RPC (`EXECUTE`) terverifikasi:

- anon: hanya `haversine_km`, `list_stores`, `search_products`, `validate_catalog_params`.
- authenticated: `admin_get_policies`, `admin_set_product_available`, `admin_set_store_active`, `admin_set_store_delivery_config`, `assign_order_driver`, `change_order_status`, `create_order`, `current_app_role`, `haversine_km`, `list_my_orders`, `list_stores`, `record_cod_collection`, `search_products`, `validate_catalog_params` (fungsi `admin_*` menolak non-admin di dalam fungsi: `admin_role_required`).
- `provision_set_policy`, `provision_set_user_role`: hanya `service_role`. Fungsi trigger tidak dapat dipanggil lewat `/rpc`. RLS aktif di semua tabel `public`.

## Perilaku NaN (hardening)

Di fondasi, `stores.delivery_fee` `numeric(12,2)` dan `stores.service_radius_km` `numeric(8,2)` hanya memakai `check (... >= 0)`, yang lolos untuk `NaN` di PostgreSQL (`NaN = NaN` benar, `x > NaN` salah, `x <= NaN` benar). Sebelum perbaikan, pada fixture lokal: ongkir NaN menghasilkan pesanan ber-total NaN, radius NaN menerima alamat ~60 km dari toko, dan `list_stores` melaporkan `within_service_radius = true`. `Infinity` tidak bisa tersimpan di kolom bertipe ini (`numeric field overflow`); koordinat aman karena check rentangnya salah untuk NaN.

Perbaikan di hardening (maju, fondasi tidak diubah, data tidak ditulis ulang):

- Constraint baru: `products_price_not_nan`, `stores_delivery_fee_not_nan`, `stores_service_radius_not_nan`, `orders_amounts_not_nan` (subtotal, delivery_fee, total), `order_items_amounts_not_nan` (unit_price_snapshot, line_total). Pelanggaran menghasilkan HTTP 400 `23514`.
- `create_order`: ongkir NaN/negatif, radius NaN/<= 0, atau koordinat toko NaN dianggap `store_delivery_not_configured`; jarak NaN menjadi `outside_store_service_radius`; subtotal/total NaN menjadi `order_subtotal_unavailable`; harga produk NaN `invalid_product_price`.
- `list_stores`/`search_products`: `within_service_radius = null` bila jarak atau radius NaN.
- Baris legacy ber-NaN pada salah satu kolom di atas membuat migrasi gagal `23514` dan di-rollback seluruhnya; baris tidak pernah diubah otomatis (lihat preflight di `README.md`).

## Ringkasan kontrak untuk frontend

Kepemilikan frontend mengikuti `docs/specs/TRD.md` §2. Pembaruan dokumen spesifikasi yang menetapkan frontend dikerjakan dengan Kiro ada di PR #3 (belum di-merge); kontrak ini tidak bergantung pada siapa yang mengerjakan frontend.

Bagian ini merangkum deklarasi SQL apa adanya (`F` = migrasi fondasi `20261107000000_...`, `H` = migrasi hardening `20261108000000_...`). Nomor baris sengaja tidak dicantumkan karena cepat basi; cari deklarasi dengan `grep -n` pada berkas migrasi. Bila ada selisih, SQL yang benar.

### Status penerapan (penting)

Migrasi hardening (`H`) di PR ini **belum diterapkan ke proyek Supabase mana pun**; hanya diuji pada Postgres lokal sekali pakai. Frontend boleh dibangun *contract-first* terhadap dokumen ini, tetapi **tidak boleh mengasumsikan endpoint baru (`list_stores`, `search_products`, `list_my_orders`, `record_cod_collection`, `admin_*`, `create_order` 8 argumen, `customer_addresses`) sudah aktif** di lingkungan mana pun sampai migrasi diterapkan dan dikonfirmasi.

### Cara memanggil dari client

- Foto: tidak ada Storage; pakai `image_url` (text) saja.
- `stores.image_url`, `products.image_url`, dan `profiles.avatar_url` adalah teks bebas: migrasi tidak membatasi skema, host, atau panjangnya, dan seller/pemilik profil dapat mengisinya dengan URL apa pun. Perlakukan sebagai input tak tepercaya: render hanya URL `https:` (tolak `javascript:`, `data:`, dan skema lain), selalu lewat atribut `src` gambar, dengan placeholder bila kosong/gagal dimuat.
- Base URL dan anon key berasal dari env proyek Supabase (mis. `VITE_SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL`); jangan menulis hostname di kode. Jangan pernah memakai `service_role` di browser.
- RPC: `supabase.rpc('<nama>', { p_arg: ... })`, jalur PostgREST relatif `POST /rest/v1/rpc/<nama>` dengan body JSON bernama-argumen. Argumen ber-default boleh dihilangkan.
- Tabel: `supabase.from('<tabel>').select('kolom, ...')`, jalur relatif `/rest/v1/<tabel>`.
- Fungsi `returns table`/`setof` mengembalikan array baris; fungsi skalar mengembalikan nilai tunggal (`change_order_status` berupa string JSON); `returns void` mengembalikan HTTP 204/200 tanpa isi. `create_order` mengembalikan array satu baris.
- Contoh:

```js
const { data, error } = await supabase.rpc('list_stores', {
  p_query: 'bakso', p_latitude: -6.2, p_longitude: 106.8, p_sort: 'nearest', p_limit: 20, p_offset: 0,
})
const { data: store } = await supabase.from('stores').select('id, name, delivery_fee').eq('is_active', true)
```

Kegagalan RPC datang sebagai HTTP 400 dengan body `{code:'P0001', message:'<snake_case>'}` (mis. `invalid_sort`); lihat bagian Pemetaan error.

### Tabel yang boleh diakses client langsung (grant + RLS)

| Tabel | Hak client | Catatan |
|---|---|---|
| `profiles` | `select` (authenticated); `update (full_name, phone, avatar_url)` | role/id/created_at tidak bisa diubah (`profile_role_change_forbidden`) |
| `stores` | `select` (anon, authenticated); seller: `insert`/`update` kolom terbatas | kolom operasional ditolak (`store_operational_field_forbidden`, `store_location_locked`) |
| `products` | `select` (anon, authenticated); seller: `insert (store_id, name, description, price, image_url, is_available)`, `update (name, description, price, image_url, is_available)`, `delete` | grant kolom dipersempit oleh hardening; harga NaN ditolak (`23514`) |
| `orders`, `order_items`, `order_status_history` | **hanya `select`** (authenticated, peserta pesanan) | **Tulis langsung (insert/update/delete) ditolak** `direct_write_forbidden` (trigger; client juga tidak diberi grant tulis) |
| `customer_addresses` | `select`, `delete`, `insert`/`update` pada (label, address, latitude, longitude, note) | hanya milik sendiri; maks. 10 alamat (`address_limit_reached`) |
| `admin_audit_log` | `select` (authenticated), RLS hanya admin | |
| `ops_policy` | **tidak ada** (revoke dari public/anon/authenticated) | admin membaca lewat `admin_get_policies()` |

Order selalu dibuat lewat `create_order`, status lewat `change_order_status`, driver lewat `assign_order_driver`.

### Katalog dan riwayat: signature lengkap

Semua `p_*` di bawah bertipe sesuai deklarasi; default sebagaimana tertulis.

**`list_stores`** (SECURITY INVOKER, `stable`; grant anon + authenticated)

```
list_stores(p_query text default null, p_latitude numeric default null, p_longitude numeric default null,
            p_sort text default 'name', p_limit integer default 20, p_offset integer default 0)
returns table (id uuid, name text, description text, address text,
  latitude numeric, longitude numeric, phone text, image_url text, opening_hours jsonb,
  delivery_fee numeric, service_radius_km numeric,
  distance_km double precision, within_service_radius boolean)
```

- `p_sort` yang diizinkan: `name`, `nearest`, `farthest`, `delivery_fee`.
- Urutan: sesuai `p_sort` (`nearest` jarak naik, `farthest` jarak turun, `delivery_fee` naik; nilai null di akhir), lalu selalu `name` naik, `id` naik. Hanya `is_active = true`. Pencarian `p_query` mencocokkan `name`/`description` (ILIKE, karakter `% _ \` di-escape; query kosong/spasi = tanpa filter).
- `distance_km` null bila koordinat pemanggil tidak dikirim; `within_service_radius` null bila jarak atau radius null atau NaN (data legacy; lihat bagian NaN).

**`search_products`** (SECURITY INVOKER, `stable`; grant anon + authenticated)

```
search_products(p_query text default null, p_store_id uuid default null,
                p_min_price numeric default null, p_max_price numeric default null,
                p_latitude numeric default null, p_longitude numeric default null,
                p_sort text default 'name', p_limit integer default 20, p_offset integer default 0)
returns table (id uuid, store_id uuid, store_name text, name text, description text,
  price numeric, image_url text, delivery_fee numeric, service_radius_km numeric,
  distance_km double precision, within_service_radius boolean)
```

- `p_sort` yang diizinkan: `name`, `nearest`, `farthest`, `cheapest`, `priciest`, `delivery_fee`.
- Urutan: sesuai `p_sort` (`cheapest` harga naik, `priciest` harga turun, dst.; null di akhir), lalu `name` naik, `id` naik. Hanya produk `is_available = true` dari toko `is_active = true`. Query mencocokkan nama produk, deskripsi, atau nama toko.

**Validasi katalog** (`validate_catalog_params` dipakai kedua fungsi di atas):

- `p_limit` harus 1–100, `p_offset` ≥ 0 (default 20/0); selain itu `invalid_pagination`.
- `p_query` maks. 100 karakter, jika lebih `search_query_too_long`.
- `p_sort` di luar daftar (atau null) → `invalid_sort`.
- Hanya salah satu dari latitude/longitude, atau di luar rentang (lat −90..90, lon −180..180) → `valid_coordinates_required`.
- `nearest`/`farthest` tanpa koordinat → `location_required_for_sort`.
- Khusus `search_products`: harga negatif atau `p_min_price > p_max_price` → `invalid_price_range`.

**`list_my_orders`** (SECURITY INVOKER, `stable`; grant **authenticated saja**, anon di-revoke)

```
list_my_orders(p_status public.order_status default null, p_limit integer default 20, p_offset integer default 0)
returns table (order_id uuid, order_code text, store_id uuid, store_name text,
  customer_id uuid, driver_id uuid,
  delivery_address text, delivery_latitude numeric, delivery_longitude numeric, delivery_note text,
  subtotal numeric, delivery_fee numeric, total numeric,
  payment_method public.payment_method, payment_status public.payment_status,
  order_status public.order_status, created_at timestamptz, items jsonb)
```

- Error: `authentication_required` (tanpa sesi), `invalid_pagination` (limit 1–100, offset ≥ 0).
- Cakupan menurut role: customer = `customer_id` sendiri; seller = toko miliknya; driver = `driver_id` sendiri; admin = semua. `p_status` null = semua status.
- Urutan: `created_at` turun, lalu `id` turun.
- `items` (jsonb array; `[]` bila kosong), diurutkan `order_items.created_at`, lalu `order_items.id`. Setiap elemen persis:

| Key | Sumber kolom | Tipe |
|---|---|---|
| `product_id` | `order_items.product_id` | uuid |
| `name` | `order_items.product_name_snapshot` | text |
| `unit_price` | `order_items.unit_price_snapshot` | numeric(12,2) |
| `quantity` | `order_items.quantity` | integer |
| `line_total` | `order_items.line_total` | numeric(12,2) |

### `create_order`

SECURITY DEFINER; grant authenticated saja (anon di-revoke).

```
create_order(p_store_id uuid, p_items jsonb, p_delivery_address text,
             p_delivery_latitude numeric, p_delivery_longitude numeric,
             p_delivery_note text default null,
             p_payment_method public.payment_method default 'cod',
             p_idempotency_key text default null)
returns table (order_id uuid, order_code text, subtotal numeric(12,2), delivery_fee numeric(12,2),
  total numeric(12,2), payment_method public.payment_method, payment_status public.payment_status,
  order_status public.order_status)
```

Versi 7 argumen dari `F` di-drop. Tiga argumen terakhir (`p_delivery_note`, `p_payment_method`, `p_idempotency_key`) ber-default sehingga boleh dihilangkan, tetapi client **wajib** mengirim `p_idempotency_key`.

### Tipe kembalian semua RPC yang dapat dipanggil client

Semua fungsi di bawah di-grant ke `authenticated` (kecuali ditandai anon juga); `public` dan `anon` di-revoke bila tidak ditandai.

| Fungsi | Tipe kembalian | Role yang dapat eksekusi |
|---|---|---|
| `create_order` | table (8 kolom di atas) | authenticated |
| `change_order_status(p_order_id uuid, p_new_status order_status, p_note text default null)` | skalar `public.order_status` (status baru) | authenticated |
| `assign_order_driver(p_order_id uuid, p_driver_id uuid)` | skalar `uuid` (id driver) | authenticated |
| `record_cod_collection(p_order_id uuid, p_note text default null)` | skalar `public.payment_status` (`verified`) | authenticated |
| `admin_set_store_active(p_store_id uuid, p_active boolean)` | skalar `boolean` | authenticated; admin saja di dalam fungsi |
| `admin_set_store_delivery_config(p_store_id uuid, p_delivery_fee numeric, p_service_radius_km numeric, p_latitude numeric default null, p_longitude numeric default null)` | `void` | authenticated; admin saja |
| `admin_set_product_available(p_product_id uuid, p_available boolean)` | skalar `boolean` | authenticated; admin saja |
| `admin_get_policies()` | table `(key text, value text)` | authenticated; admin saja |
| `list_stores` | table (13 kolom) | anon + authenticated |
| `search_products` | table (11 kolom) | anon + authenticated |
| `list_my_orders` | table (18 kolom) | authenticated |

Tidak ada fungsi `setof` pada kontrak ini. Seluruh nama di dokumen ini (termasuk di bagian RPC di atas) sudah dicocokkan dengan deklarasi SQL; tidak ada nama yang tidak ditemukan.

### Provisioning: BUKAN API frontend

`provision_set_user_role(p_user_id uuid, p_role public.app_role, p_reason text default null)` → `public.app_role` dan `provision_set_policy(p_key text, p_value text)` → `void` : `revoke all... from public, anon, authenticated` lalu `grant execute... to service_role` (`postgres` sebagai pemilik). Hanya dari SQL editor/CLI/CI tepercaya; **jangan pernah dari frontend**.

### Fungsi internal (bukan API aplikasi)

Fungsi/trigger berikut adalah detail implementasi. Jangan dipanggil atau dibangun di atasnya oleh frontend:

| Fungsi | Hak eksekusi client |
|---|---|
| `haversine_km` | **Di-grant ke anon dan authenticated**, sehingga secara teknis dapat dipanggil lewat `/rest/v1/rpc/haversine_km`. Dibuka agar `list_stores`/`search_products` (SECURITY INVOKER) berjalan; bukan API aplikasi. |
| `validate_catalog_params` | **Di-grant ke anon dan authenticated** dengan alasan sama; bukan API aplikasi. |
| `current_app_role` | Di-grant ke authenticated, dipakai kebijakan RLS; bukan API aplikasi (role dapat dibaca dari `profiles`). |
| `ops_policy_value` | Di-revoke dari public/anon/authenticated |
| `block_client_direct_write`, `guard_profile_update`, `guard_store_update` | Di-revoke dari public/anon/authenticated; fungsi trigger |
| `limit_customer_addresses` | Di-revoke; fungsi trigger |
| `touch_updated_at`, `handle_new_auth_user` | Di-revoke; fungsi trigger |

### Aturan perilaku yang wajib dipatuhi UI

- `manual_transfer` **selalu ditolak** `manual_transfer_not_configured`, bahkan bila `ops_policy.manual_transfer_enabled=true`. Jangan tampilkan sebagai pilihan.
- Penyelesaian pesanan (`completion_policy_not_configured`), pembatalan (`cancellation_policy_not_configured`) dan pencatatan COD (`cod_collection_policy_not_configured`) **fail closed** (tertutup) sampai operator mengatur `ops_policy`. UI harus menangani kedua error tersebut.
- `delivered`/`completed` **tidak sama dengan lunas**. Hanya `record_cod_collection` yang mengubah `payment_status` menjadi `verified`; tampilkan `payment_status` apa adanya.
- Frontend **selalu mengirim `p_idempotency_key`** pada `create_order` (kunci baru per percobaan checkout, dipakai ulang hanya saat retry).
- Catatan: `status_unchanged` hanya ada di `change_order_status` versi foundation yang sudah digantikan; versi hardening tidak memunculkannya, jadi tidak perlu ditangani.

## Perubahan yang berdampak pada frontend

1. `create_order` memiliki argumen ke-8 `p_idempotency_key`; kirim selalu. Fungsi 7 argumen lama diganti (drop) oleh migrasi.
2. Tabel `orders`, `order_items`, `order_status_history` kini ditolak untuk tulis langsung dari client (`direct_write_forbidden`); profil tidak bisa mengubah role (`profile_role_change_forbidden`).
3. Gunakan `list_stores`/`search_products`/`list_my_orders` untuk katalog dan riwayat dengan pagination; `completed` tidak berarti lunas, tampilkan `payment_status` apa adanya.
4. Cancel, transfer manual, dan pencatatan COD tetap tertutup sampai operator mengatur kebijakan; UI harus menangani `cancellation_policy_not_configured`, `manual_transfer_not_configured`, `cod_collection_policy_not_configured`, `completion_policy_not_configured`.
5. Rating tidak ada (P2, ditunda).

## Status dan error yang perlu ditangani UI

Status pesanan: `pending_seller`, `accepted`, `rejected`, `preparing`, `ready_for_pickup`, `picked_up`, `delivered`, `completed`, `cancelled`.

Metode pembayaran: `cod`, `manual_transfer` (belum aktif untuk checkout). Status pembayaran tersedia sebagai enum; pencatatan COD tersedia lewat `record_cod_collection` (tertutup secara default), sedangkan verifikasi transfer manual belum memiliki workflow.

Pesan error RPC yang umum: `authentication_required`, `customer_role_required`, `store_not_available`, `store_delivery_not_configured`, `outside_store_service_radius`, `product_unavailable_or_wrong_store`, `invalid_product_price` (harga produk NaN/legacy tidak valid), `order_not_cod`, `order_not_delivered`, `payment_already_recorded`, `cod_collection_policy_not_configured`, `completion_policy_not_configured`, `address_limit_reached`, `manual_transfer_not_configured`, `status_transition_not_allowed`, `cancellation_policy_not_configured`, `admin_role_required`, `driver_profile_required`, `invalid_idempotency_key`, `idempotency_key_conflict`, `items_must_be_array`, `item_count_out_of_range`, `invalid_order_item`, `duplicate_product_in_items`, `delivery_address_required`, `delivery_note_too_long`, `valid_delivery_coordinates_required`, `order_subtotal_unavailable`, `order_not_found`, `order_not_assignable`, `driver_not_assigned`, `rejection_reason_required`, `cancellation_reason_required`, `status_note_too_long`, `direct_write_forbidden`. Semua memakai `errcode P0001` dengan pesan snake_case.

Daftar di atas tidak lengkap. Error katalog (`invalid_pagination`, `invalid_sort`, `search_query_too_long`, `valid_coordinates_required`, `location_required_for_sort`, `invalid_price_range`), admin (`store_not_found`, `product_not_found`, `invalid_argument`, `invalid_delivery_config`), dan guard tulis tabel (`profile_role_change_forbidden`, `store_operational_field_forbidden`, `store_location_locked`) dijelaskan di bagian masing-masing. `invalid_policy_value`, `unknown_policy_key`, `profile_not_found` hanya muncul dari `provision_*` (bukan client). `hardening_requires_supabase_auth_schema` dan `hardening_requires_foundation_migration` hanya muncul saat migrasi diterapkan.

UI harus menampilkan pesan yang ramah dan tidak memaparkan SQL/detail internal. Pertahankan keranjang ketika checkout gagal.

## Keputusan yang harus ditutup sebelum pilot

1. Wilayah pilot, biaya kirim (apakah tarif tetap per toko atau rumus lain), radius, dan metode geolokasi/jarak.
2. Apakah admin-only assignment diterima atau driver/penjual boleh memilih tugas.
3. Siapa memverifikasi transfer manual, bukti apa yang diperlukan, dan informasi rekening/instruksi.
4. Kebijakan pembatalan, termasuk tahap yang masih dapat dibatalkan.
5. Apakah customer-confirmed `completed` sesuai dengan proses serah-terima.
6. Pencatatan penagihan COD setelah driver menyerahkan pesanan.

Konfigurasi yang diperlukan untuk masing-masing keputusan, beserta kunci `ops_policy`-nya, ada di [MVP_GAP_CHECKLIST.md](MVP_GAP_CHECKLIST.md).

Sebelum keputusan itu disetujui, jangan tampilkan transfer sebagai metode yang dapat dipilih, jangan menyebut pembayaran “lunas”, dan jangan anggap checkout siap untuk pilot.
