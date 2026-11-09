# SendFood

Fondasi MVP aplikasi pemesanan makanan lokal berbasis **PWA mobile-first** yang menghubungkan pelanggan, penjual, driver, dan admin.

Repository ini memuat spesifikasi produk dan handoff backend Supabase. **Source code frontend belum tersedia; repository ini belum berisi aplikasi yang siap dijalankan atau di-deploy.**

## Isi repository

```text
.kiro/              Steering dan spec proyek (konteks untuk Kiro)
docs/specs/          PRD, TRD, AFD, DBD, BSD, dan IPD baseline MVP
backend/
  API_CONTRACT.md    Kontrak integrasi frontend–backend
  migrations/       Migrasi PostgreSQL/Supabase yang versioned
  tests/            Suite SQL (run.sh), tumpukan HTTP nyata (stack/, http/), all.sh
  scripts/          apply_migration_local.sh (khusus lokal)
  TEST_EVIDENCE.md  Bukti hasil tes aktual
  MVP_GAP_CHECKLIST.md  Gap MVP dan keputusan wajib sebelum pilot
```

Mulai dari [PRD](docs/specs/PRD.md), lalu baca [panduan spesifikasi](docs/specs/README.md). Untuk integrasi aktual, gunakan [kontrak API backend](backend/API_CONTRACT.md) sebagai acuan nama field, RPC, status, dan akses data. Beberapa bagian BSD/TRD masih berupa rancangan awal; jangan menganggap usulan tersebut sebagai fitur yang sudah aktif.

## Status implementasi

- Migrasi fondasi backend tersedia dan telah diterapkan pada proyek Supabase terkait (ledger live mencatat versi `20261107042649`; jangan memutar ulang fondasi).
- Backend mencakup enam tabel aplikasi, RLS, dan RPC untuk pembuatan pesanan, transisi status, serta assignment driver.
- Checkout fondasi hanya menerima **COD** dan akan ditolak sampai toko memiliki konfigurasi biaya pengiriman, radius layanan, dan koordinat.
- Migrasi hardening `20261108000000` tersedia di branch ini tetapi belum diterapkan ke Supabase; transfer manual, pembatalan, dan pencatatan COD tertutup sampai kebijakan operator diatur; assignment driver sementara hanya admin.
- Dua suite tes lokal tersedia (SQL, dan HTTP dengan Supabase Auth/GoTrue + PostgREST nyata di localhost); bukti di [TEST_EVIDENCE](backend/TEST_EVIDENCE.md), panduan di [panduan backend](backend/README.md). CI dua-job lulus pada `e798fab`; lihat checks PR #1 untuk commit terbaru. Storage belum diimplementasi (menunggu keputusan visibilitas/siklus hidup); audit NaN produksi kolom baru belum dilakukan; gate hosted masih terbuka. Checklist: [MVP_GAP_CHECKLIST](backend/MVP_GAP_CHECKLIST.md).
- Pemeriksaan struktur tersedia, tetapi bukan pengganti tes RLS lintas peran dan tes transaksi end-to-end dengan akun staging.
- Frontend, konfigurasi build PWA, dan deployment aplikasi belum dibuat di repository ini.

Detail batasan dan keputusan operasional yang belum final ada dalam [kontrak API](backend/API_CONTRACT.md#keputusan-yang-harus-ditutup-sebelum-pilot). MVP/PWA belum siap pilot: frontend belum ada dan keputusan bisnis belum ditutup.

## Alur kerja

- `main`: baseline yang sudah ditinjau.
- `frontend`: pekerjaan UI/PWA dan integrasi sesuai kontrak API.
- `backend`: perubahan migrasi, RLS, RPC, dan tes backend.
- `integration`: penggabungan dan pengujian frontend–backend sebelum masuk ke `main`.

Jangan mengasumsikan framework frontend sebelum proyek frontend benar-benar dipilih dan dibuat. Perubahan schema/RLS harus disertai migrasi dan pembaruan kontrak; frontend tidak boleh mengubahnya secara sepihak.

## Migrasi dan verifikasi

Baca [panduan backend](backend/README.md). Migrasi fondasi sudah diterapkan dan tidak boleh diputar ulang atau diedit di remote. Hardening belum diterapkan; runbook (khusus lokal, plus panduan operator yang tidak dieksekusi) ada di panduan backend. Periksa riwayat migrasi dan lingkungan target sebelum menerapkan perubahan berikutnya.

`backend/tests/verify_schema.sql` adalah pemeriksaan read-only pascamigrasi. Gunakan akun staging terpisah per peran untuk pengujian akses runtime; jangan mengubah akun produksi untuk pengujian.

## Keamanan

Jangan commit `.env`, password, token GitHub, atau Supabase `service_role` key. File `.gitignore` mengecualikan konfigurasi rahasia lokal. Browser/frontend hanya boleh menerima public/publishable key sesuai aturan Supabase dan tetap dilindungi RLS.

Repository publik ini tidak memuat kredensial atau konfigurasi rahasia lingkungan.
