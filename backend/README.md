# SendFood backend foundation

Backend foundation untuk schema Supabase, Row Level Security (RLS), RPC transaksi/status, pemeriksaan struktur, dan kontrak API. Frontend belum termasuk dalam repository ini.

## Berkas
- `migrations/20261107000000_sendfood_backend_foundation.sql` — migrasi fondasi PostgreSQL.
- `API_CONTRACT.md` — kontrak integrasi frontend–backend.
- `tests/verify_schema.sql` — pemeriksaan struktur read-only setelah migrasi.

## Catatan operasional
- Migrasi fondasi telah diterapkan pada proyek Supabase yang terkait dengan MVP ini.
- Checkout menerima COD saja sampai konfigurasi toko (biaya tetap, radius layanan, dan koordinat) tersedia.
- Radius memakai jarak garis lurus Haversine sebagai asumsi sementara.
- Transfer manual dan pembatalan belum diaktifkan; assignment driver sementara hanya admin.
- Pemeriksaan struktur bukan pengganti uji RLS lintas peran. Uji runtime memerlukan akun staging terpisah untuk setiap peran; jangan memakai akun pengguna produksi.
- Jangan pernah menaruh `service_role` key atau kredensial lain di frontend atau commit repository.
