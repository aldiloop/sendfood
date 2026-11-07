# SendFood Backend API Contract (MVP foundation)

## Status integrasi

Kontrak ini sesuai migrasi `20261107000000_sendfood_backend_foundation.sql` ditambah migrasi maju `20261108000000_sendfood_backend_mvp_hardening.sql`. Migrasi kedua baru diverifikasi pada Postgres lokal sekali pakai (lihat `README.md`); **belum diterapkan ke proyek Supabase mana pun**. Gunakan Supabase Auth untuk sesi. Katalog menggunakan akses tabel yang dilindungi RLS; checkout, perubahan status, dan assignment driver hanya melalui RPC. Jangan menaruh `service_role` key di browser.

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
  "p_idempotency_key": "<8-100 karakter dari A-Z a-z 0-9 _ . : - , unik per percobaan checkout>"
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
- `delivered` → `completed` (aktor ditentukan `ops_policy.completion_actor`: `customer` (default, konvensi sementara), `seller`, atau `driver`; admin selalu dapat)
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

## Perubahan yang berdampak pada frontend

1. `create_order` memiliki argumen ke-8 `p_idempotency_key`; kirim selalu. Fungsi 7 argumen lama diganti (drop) oleh migrasi.
2. Tabel `orders`, `order_items`, `order_status_history` kini ditolak untuk tulis langsung dari client (`direct_write_forbidden`); profil tidak bisa mengubah role (`profile_role_change_forbidden`).
3. Gunakan `list_stores`/`search_products`/`list_my_orders` untuk katalog dan riwayat dengan pagination; `completed` tidak berarti lunas, tampilkan `payment_status` apa adanya.
4. Cancel, transfer manual, dan pencatatan COD tetap tertutup sampai operator mengatur kebijakan; UI harus menangani `cancellation_policy_not_configured`, `manual_transfer_not_configured`, `cod_collection_policy_not_configured`.
5. Rating tidak ada (P2, ditunda).

## Status dan error yang perlu ditangani UI

Status pesanan: `pending_seller`, `accepted`, `rejected`, `preparing`, `ready_for_pickup`, `picked_up`, `delivered`, `completed`, `cancelled`.

Metode pembayaran: `cod`, `manual_transfer` (belum aktif untuk checkout). Status pembayaran tersedia sebagai enum; pencatatan COD tersedia lewat `record_cod_collection` (tertutup secara default), sedangkan verifikasi transfer manual belum memiliki workflow.

Pesan error RPC yang umum: `authentication_required`, `customer_role_required`, `store_not_available`, `store_delivery_not_configured`, `outside_store_service_radius`, `product_unavailable_or_wrong_store`, `manual_transfer_not_configured`, `status_transition_not_allowed`, `cancellation_policy_not_configured`, `admin_role_required`, `driver_profile_required`, `invalid_idempotency_key`, `idempotency_key_conflict`, `items_must_be_array`, `item_count_out_of_range`, `invalid_order_item`, `duplicate_product_in_items`, `delivery_address_required`, `delivery_note_too_long`, `valid_delivery_coordinates_required`, `order_subtotal_unavailable`, `order_not_found`, `order_not_assignable`, `driver_not_assigned`, `rejection_reason_required`, `cancellation_reason_required`, `status_note_too_long`, `direct_write_forbidden`. Semua memakai `errcode P0001` dengan pesan snake_case.

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
