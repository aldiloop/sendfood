# SendFood

Fondasi MVP aplikasi pemesanan makanan lokal berbasis **PWA mobile-first** yang menghubungkan pelanggan, penjual, driver, dan admin.

Repository ini memuat spesifikasi produk dan handoff backend Supabase. **Source code frontend belum tersedia; repository ini belum berisi aplikasi yang siap dijalankan atau di-deploy.**

## Isi repository

```text
docs/specs/          PRD, TRD, AFD, DBD, BSD, dan IPD baseline MVP
backend/
  API_CONTRACT.md    Kontrak integrasi frontend–backend
  migrations/       Migrasi PostgreSQL/Supabase yang versioned
  tests/            Pemeriksaan struktur skema read-only
```

Mulai dari [PRD](docs/specs/PRD.md), lalu baca [panduan spesifikasi](docs/specs/README.md). Untuk integrasi aktual, gunakan [kontrak API backend](backend/API_CONTRACT.md) sebagai acuan nama field, RPC, status, dan akses data. Beberapa bagian BSD/TRD masih berupa rancangan awal; jangan menganggap usulan tersebut sebagai fitur yang sudah aktif.

## Status implementasi

- Migrasi fondasi backend tersedia dan telah diterapkan pada proyek Supabase terkait.
- Backend mencakup enam tabel aplikasi, RLS, dan RPC untuk pembuatan pesanan, transisi status, serta assignment driver.
- Checkout fondasi hanya menerima **COD** dan akan ditolak sampai toko memiliki konfigurasi biaya pengiriman, radius layanan, dan koordinat.
- Transfer manual dan pembatalan belum diaktifkan; assignment driver sementara hanya admin.
- Pemeriksaan struktur tersedia, tetapi bukan pengganti tes RLS lintas peran dan tes transaksi end-to-end dengan akun staging.
- Frontend, konfigurasi build PWA, dan deployment aplikasi belum dibuat di repository ini.

Detail batasan dan keputusan operasional yang belum final ada dalam [kontrak API](backend/API_CONTRACT.md#keputusan-yang-harus-ditutup-sebelum-pilot). MVP belum boleh dianggap siap pilot hanya karena skema sudah tersedia.

## Alur kerja

- `main`: baseline yang sudah ditinjau.
- `frontend`: pekerjaan UI/PWA dan integrasi sesuai kontrak API.
- `backend`: perubahan migrasi, RLS, RPC, dan tes backend.
- `integration`: penggabungan dan pengujian frontend–backend sebelum masuk ke `main`.

Jangan mengasumsikan framework frontend sebelum proyek frontend benar-benar dipilih dan dibuat. Perubahan schema/RLS harus disertai migrasi dan pembaruan kontrak; frontend tidak boleh mengubahnya secara sepihak.

## Migrasi dan verifikasi

Baca [panduan backend](backend/README.md). Migrasi di `backend/migrations/` merupakan riwayat fondasi yang sudah diterapkan, bukan perintah untuk dijalankan ulang sembarangan pada database yang sama. Periksa riwayat migrasi dan lingkungan target sebelum menerapkan perubahan berikutnya.

`backend/tests/verify_schema.sql` adalah pemeriksaan read-only pascamigrasi. Gunakan akun staging terpisah per peran untuk pengujian akses runtime; jangan mengubah akun produksi untuk pengujian.

## Keamanan

Jangan commit `.env`, password, token GitHub, atau Supabase `service_role` key. File `.gitignore` mengecualikan konfigurasi rahasia lokal. Browser/frontend hanya boleh menerima public/publishable key sesuai aturan Supabase dan tetap dilindungi RLS.

Repository publik ini tidak memuat kredensial atau konfigurasi rahasia lingkungan.
