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

## Tes lokal (Postgres sekali pakai)

Runner: `backend/tests/run.sh`. Runner membuat cluster Postgres sementara (socket unix saja), database `sendfood_test_*`, menerapkan `backend/tests/harness/supabase_shim.sql` (schema `auth`, `auth.users`, `auth.uid()`, role `anon`/`authenticated`/`service_role`), semua migrasi berurutan, `verify_schema.sql`, lalu `backend/tests/runtime/*.sql`. Semuanya dihapus di akhir.

Menyediakan biner Postgres (tanpa root install; terverifikasi di sandbox dengan Postgres 16.2):

```
python3 -m venv .pgtools/venv && .pgtools/venv/bin/pip install pgserver
```

Alternatif: `PG_BIN=/path/ke/bin`, atau `psql` dan `initdb` di PATH. Jika dijalankan sebagai root, runner menjalankan Postgres sebagai uid 65534.

Mode server sendiri: set `SENDFOOD_TEST_PGHOST` (hanya `localhost`, `127.0.0.1`, `::1`, atau path socket), `SENDFOOD_TEST_PGPORT`, `SENDFOOD_TEST_PGUSER`. Host lain ditolak dengan exit code 3. Shim juga menolak berjalan jika schema `auth` sudah ada atau nama database tidak berawalan `sendfood_test_`. Salin `.env.example` ke `.env` hanya jika perlu; isinya placeholder.
