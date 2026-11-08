# BSD — Backend Schema Documentation
## Send Food

**Versi:** 1.0 | **Tanggal:** 7 November 2026  
**Status:** Usulan model data — Kiro wajib memvalidasi sebelum migrasi

## 1. Prinsip
Schema berikut adalah rancangan awal untuk MVP, bukan klaim bahwa tabel sudah dibuat. Kiro harus memeriksa kebutuhan aktual, menormalisasi relasi, menetapkan constraint/index, menulis migrasi, dan menguji RLS sebelum frontend menggunakannya.

## 2. Entitas yang diusulkan
### `profiles`
- `id` UUID, PK, FK ke `auth.users.id`
- `full_name` text
- `phone` text nullable
- `role` enum/text terbatas: `customer`, `seller`, `driver`, `admin`
- `avatar_url` text nullable
- `created_at`, `updated_at` timestamptz

Catatan: role tidak boleh dapat dinaikkan sendiri oleh pengguna dari client.

### `stores`
- `id` UUID, PK
- `owner_id` UUID FK ke `profiles.id`
- `name` text
- `description` text nullable
- `address` text
- `latitude`, `longitude` numeric nullable
- `phone` text nullable
- `image_url` text nullable
- `is_active` boolean
- `opening_hours` jsonb nullable (format harus ditentukan)
- `created_at`, `updated_at`

### `products`
- `id` UUID, PK
- `store_id` UUID FK ke `stores.id`
- `name` text
- `description` text nullable
- `price` numeric(12,2), constraint >= 0
- `image_url` text nullable
- `is_available` boolean
- `created_at`, `updated_at`

### `orders`
- `id` UUID, PK
- `order_code` text unique
- `customer_id` UUID FK ke `profiles.id`
- `store_id` UUID FK ke `stores.id`
- `driver_id` UUID FK ke `profiles.id`, nullable
- `delivery_address` text
- `delivery_latitude`, `delivery_longitude` numeric nullable
- `delivery_note` text nullable
- `subtotal` numeric(12,2)
- `delivery_fee` numeric(12,2)
- `total` numeric(12,2)
- `payment_method` enum/text terbatas: `cod`, `manual_transfer`
- `payment_status` enum/text terbatas, misalnya `unpaid`, `pending_verification`, `verified`, `failed`
- `order_status` enum/text terbatas sesuai TRD
- `created_at`, `updated_at`

### `order_items`
- `id` UUID, PK
- `order_id` UUID FK ke `orders.id`
- `product_id` UUID FK ke `products.id`
- `product_name_snapshot` text
- `unit_price_snapshot` numeric(12,2)
- `quantity` integer, constraint > 0
- `line_total` numeric(12,2)

Snapshot menjaga histori pesanan walaupun nama/harga produk berubah.

### `manual_payment_proofs` (opsional untuk MVP)
- `id` UUID, PK
- `order_id` UUID FK ke `orders.id`
- `file_path` text
- `submitted_by` UUID FK ke `profiles.id`
- `verification_status` text terbatas
- `verified_by` UUID FK ke `profiles.id`, nullable
- `verified_at` timestamptz nullable
- `created_at` timestamptz

Gunakan Storage bucket privat dan kebijakan akses yang ketat jika bukti transfer diaktifkan.

### `order_status_history` (direkomendasikan)
- `id` UUID, PK
- `order_id` UUID FK ke `orders.id`
- `old_status` text nullable
- `new_status` text
- `changed_by` UUID FK ke `profiles.id`
- `note` text nullable
- `created_at` timestamptz

## 3. Relasi
- Satu profile penjual dapat memiliki satu atau lebih store (kebijakan MVP dapat membatasi satu).
- Satu store memiliki banyak products.
- Satu customer memiliki banyak orders.
- Satu store memiliki banyak orders.
- Satu order memiliki banyak order_items.
- Satu driver dapat ditugaskan ke banyak orders.
- Satu order dapat memiliki banyak catatan status.

## 4. RLS — matriks akses minimum
| Tabel | Customer | Seller | Driver | Admin |
|---|---|---|---|---|
| profiles | Baca/ubah profil sendiri | Baca/ubah sendiri | Baca/ubah sendiri | Kelola sesuai kebijakan |
| stores | Baca toko aktif | Kelola toko milik sendiri | Baca informasi toko untuk tugas | Kelola semua |
| products | Baca produk tersedia | CRUD produk toko sendiri | Baca ringkasan item tugas | Kelola/moderasi |
| orders | Baca pesanan sendiri, buat pesanan | Baca/update pesanan toko sendiri sesuai transisi | Baca/update tugas yang ditugaskan | Kelola/pantau semua |
| order_items | Baca item pesanan sendiri | Baca item pesanan toko sendiri | Baca item tugas | Kelola/pantau |
| payment proofs | Kirim/baca bukti sendiri | Baca hanya bila perlu | Tidak perlu akses | Verifikasi sesuai kebijakan |
| status history | Baca pesanan sendiri | Baca pesanan toko sendiri | Baca tugas sendiri | Baca semua |

Semua kebijakan di atas harus diterjemahkan ke RLS yang diuji. Jangan mengandalkan pemeriksaan UI.

## 5. Constraint dan validasi
- Harga, subtotal, biaya kirim, dan total tidak negatif.
- Quantity bilangan bulat positif.
- `total = subtotal + delivery_fee` dihitung ulang pada sisi tepercaya.
- Order item harus berasal dari store yang sama dengan order.
- `order_code` unik.
- Status hanya dapat berubah melalui transisi yang diizinkan.
- `driver_id` hanya dapat diisi oleh aktor yang berwenang.
- Timestamp menggunakan timezone-aware `timestamptz`.

## 6. Index awal
Pertimbangkan index pada `stores.owner_id`, `products.store_id`, `orders.customer_id`, `orders.store_id`, `orders.driver_id`, `orders.order_status`, `orders.created_at`, dan `order_items.order_id`. Kiro harus memeriksa query aktual sebelum menetapkan index final.

## 7. Hal yang belum diputuskan
- Apakah alamat pelanggan disimpan sebagai tabel `customer_addresses` atau hanya saat checkout.
- Apakah satu penjual dibatasi satu toko.
- Mekanisme assignment driver.
- Apakah bukti transfer masuk MVP.
- Format jam operasional.
- Metode penghitungan jarak dan biaya kirim.

## 8. Checklist sebelum schema dianggap final
- [ ] Relasi dan foreign key tervalidasi.
- [ ] Constraint harga/quantity/status dibuat.
- [ ] RLS aktif untuk semua tabel yang diakses client.
- [ ] Tes akses silang antar customer, seller, dan driver lulus.
- [ ] Total pesanan dihitung di sisi tepercaya.
- [ ] Migrasi dapat dijalankan ulang/di-version-control sesuai praktik proyek.
- [ ] Kontrak API diperbarui dan frontend disesuaikan dengan kontrak tersebut.
