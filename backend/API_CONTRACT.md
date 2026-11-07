# SendFood Backend API Contract (MVP foundation)

## Status integrasi

Kontrak ini sesuai migrasi `20261107000000_sendfood_backend_foundation.sql`. Gunakan Supabase Auth untuk sesi. Katalog menggunakan akses tabel yang dilindungi RLS; checkout, perubahan status, dan assignment driver hanya melalui RPC. Jangan menaruh `service_role` key di browser.

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
  "p_payment_method": "cod"
}
```

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
- `delivered` → `completed` (customer mengonfirmasi penerimaan; konvensi sementara)
- Admin dapat melakukan transisi yang sama, tetapi tidak dapat melompati tahapan.

`cancelled` sengaja ditolak dengan `cancellation_policy_not_configured` hingga kebijakan pembatalan disepakati. Setiap transisi sah dicatat di `order_status_history`.

### Assignment driver

`supabase.rpc('assign_order_driver', { p_order_id, p_driver_id })`

Hanya admin; order harus berstatus `accepted`, `preparing`, atau `ready_for_pickup`; profil target harus ber-role `driver`. Ini fallback admin-only sementara, bukan keputusan final antara admin/penjual/driver self-claim.

## Status dan error yang perlu ditangani UI

Status pesanan: `pending_seller`, `accepted`, `rejected`, `preparing`, `ready_for_pickup`, `picked_up`, `delivered`, `completed`, `cancelled`.

Metode pembayaran: `cod`, `manual_transfer` (belum aktif untuk checkout). Status pembayaran tersedia sebagai enum, tetapi verifikasi manual/COD belum memiliki workflow UI/API di MVP foundation.

Pesan error RPC yang umum: `authentication_required`, `customer_role_required`, `store_not_available`, `store_delivery_not_configured`, `outside_store_service_radius`, `product_unavailable_or_wrong_store`, `manual_transfer_not_configured`, `status_transition_not_allowed`, `cancellation_policy_not_configured`, `admin_role_required`, `driver_profile_required`.

UI harus menampilkan pesan yang ramah dan tidak memaparkan SQL/detail internal. Pertahankan keranjang ketika checkout gagal.

## Keputusan yang harus ditutup sebelum pilot

1. Wilayah pilot, biaya kirim (apakah tarif tetap per toko atau rumus lain), radius, dan metode geolokasi/jarak.
2. Apakah admin-only assignment diterima atau driver/penjual boleh memilih tugas.
3. Siapa memverifikasi transfer manual, bukti apa yang diperlukan, dan informasi rekening/instruksi.
4. Kebijakan pembatalan, termasuk tahap yang masih dapat dibatalkan.
5. Apakah customer-confirmed `completed` sesuai dengan proses serah-terima.
6. Pencatatan penagihan COD setelah driver menyerahkan pesanan.

Sebelum keputusan itu disetujui, jangan tampilkan transfer sebagai metode yang dapat dipilih, jangan menyebut pembayaran “lunas”, dan jangan anggap checkout siap untuk pilot.
