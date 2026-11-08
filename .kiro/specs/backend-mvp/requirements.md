# Requirements: backend MVP SendFood

Ditelusuri ke prioritas `docs/specs/PRD.md` bagian 10. Status sebenarnya: lihat `tasks.md`. Hasil tes lokal bukan kesiapan pilot.

## P0
- R1 (Autentikasi): akun dibuat lewat Supabase Auth; profil otomatis ber-role `customer`; role tidak dapat dinaikkan dari client.
- R2 (Katalog): anon/pelanggan melihat hanya toko aktif dan produk tersedia, dengan pencarian dan pagination.
- R3 (Checkout/pesanan): pelanggan membuat pesanan COD satu-toko lewat RPC; harga, ongkir, total dihitung server; idempoten; ditolak bila toko belum dikonfigurasi (fail closed).
- R4 (Status penjual): penjual toko terkait menerima/menolak, menyiapkan, menandai siap diambil; setiap transisi tercatat.
- R5 (Driver): admin menugaskan driver; driver yang ditugaskan menandai `picked_up` lalu `delivered`.
- R6 (Kontrol akses): RLS di semua tabel; tulis langsung ke order/item/riwayat ditolak; antar-peran terisolasi.

## P1
- R7 (Filter/urut): `list_stores`, `search_products` dengan sort dan radius.
- R8 (Riwayat): `list_my_orders` per peran.
- R9 (Transfer manual): TETAP DITOLAK sampai verifikator/bukti/rekening diputuskan.
- R10 (Admin): RPC dasar dan audit log; tanpa UI.

## Lintas bidang
- R11 (Fail closed): pembatalan, COD collection, dan transfer manual ditutup via `ops_policy` sampai operator memutuskan.
- R12 (Integritas angka): NaN tidak boleh masuk kolom uang/radius dan tidak boleh menembus checkout.
- R13 (Migrasi aman): hardening atomik; kegagalan di-rollback; fondasi tidak diubah.
- R14 (Bukti): dua suite tes lokal dengan hasil terdokumentasi.

## Di luar lingkup saat ini
Frontend/PWA, Storage/foto, rating (P2), pembayaran online, keputusan bisnis terbuka (lihat steering/product.md).
