# SendFood backend foundation

Backend foundation untuk schema Supabase, Row Level Security (RLS), RPC transaksi/status, pemeriksaan struktur, dan kontrak API. Frontend belum termasuk dalam repository ini.

## Berkas
- `migrations/20261107000000_sendfood_backend_foundation.sql` — migrasi fondasi PostgreSQL.
- `API_CONTRACT.md` — kontrak integrasi frontend–backend.
- `migrations/20261108000000_sendfood_backend_mvp_hardening.sql` - migrasi maju hardening (belum diterapkan ke Supabase mana pun).
- `MVP_GAP_CHECKLIST.md` - checklist gap MVP dan keputusan wajib sebelum pilot.
- `tests/verify_schema.sql` — pemeriksaan struktur read-only setelah migrasi.
- `tests/run.sh`, `tests/harness/`, `tests/runtime/`, `tests/concurrency/` - harness dan tes runtime lokal.

## Catatan operasional
- Migrasi fondasi telah diterapkan pada proyek Supabase yang terkait dengan MVP ini.
- Frontend/PWA belum ada. Backend ini sendiri **belum siap pilot** sebelum keputusan bisnis ditutup (lihat `MVP_GAP_CHECKLIST.md`).
- Checkout menerima COD saja sampai konfigurasi toko (biaya tetap, radius layanan, dan koordinat) tersedia.
- Radius memakai jarak garis lurus Haversine sebagai asumsi sementara.
- Transfer manual, pembatalan, dan pencatatan COD tertutup (fail closed) lewat tabel `ops_policy` sampai operator mengaturnya; assignment driver sementara hanya admin.
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

### Perintah dan hasil tes

```
bash backend/tests/run.sh
```

Tahap: struktural (`verify_schema.sql`), smoke hardening, fixture, tes runtime positif/negatif (`tests/runtime/*.sql`), lalu tes konkurensi (`tests/concurrency/*.sh`). Runner mencetak jumlah lulus, gagal, dan dilewati; exit code bukan nol jika ada yang gagal. Hasil terakhir yang dijalankan di sandbox (Postgres 16.2 via `pgserver`) dicatat di laporan tugas, bukan diasumsikan di sini; jalankan ulang untuk bukti terbaru. Yang diuji hanya Postgres lokal dengan shim Supabase, bukan Supabase Auth/PostgREST sungguhan.

## CI

`.github/workflows/backend-tests.yml` menjalankan runner yang sama terhadap service container Postgres 16 (mode `SENDFOOD_TEST_PGHOST=127.0.0.1`). Workflow ini **belum pernah dijalankan** (GitHub Actions tidak dapat dijalankan dari lingkungan pengembangan); hanya sintaks YAML yang divalidasi lokal. Anggap statusnya tidak diketahui sampai ada run pertama di GitHub.

## Provisioning admin dan kebijakan (lingkungan tepercaya)

Role selalu `customer` saat akun dibuat dan tidak dapat dinaikkan dari client. Admin pertama dan kebijakan operasional hanya diatur oleh operator tepercaya (Supabase SQL editor, CLI dengan koneksi database admin, atau job CI dengan secret), memakai fungsi yang hanya dapat dieksekusi `service_role`/`postgres`:

```sql
select public.provision_set_user_role('<uuid user>', 'admin', 'alasan');
select public.provision_set_policy('cancellation_enabled', 'true');
```

Jangan menaruh `service_role` key, token, atau password di source, commit, atau frontend; simpan sebagai secret di lingkungan operator. Setiap pemanggilan dicatat di `admin_audit_log`. `.env.example` hanya berisi placeholder.

## Menerapkan migrasi maju (panduan, tidak dijalankan di sini)

Migrasi fondasi sudah live dan tidak boleh diubah. Migrasi hardening bersifat maju (forward) dan memakai `create ... if not exists`/`create or replace`, tetapi tetap menghapus `create_order` 7 argumen dan menambah pembatasan hak akses yang berdampak ke client.

1. Pastikan tes lokal lulus pada commit yang akan diterapkan (`bash backend/tests/run.sh`).
2. Buat proyek Supabase **staging** terpisah (atau branch database). Jangan mulai dari produksi. Cadangkan database (dump/PITR) sebelum menerapkan.
3. Periksa riwayat migrasi target (`supabase migration list` atau tabel `supabase_migrations.schema_migrations`) dan pastikan `20261107000000` sudah tercatat serta `20261108000000` belum.
4. Terapkan hanya migrasi baru, mis. `supabase db push` ke staging atau jalankan berkas SQL lewat SQL editor oleh operator.
5. Verifikasi di staging: jalankan `tests/verify_schema.sql`; buat akun uji terpisah per peran (customer, seller, driver, admin) lewat Supabase Auth, promosikan lewat `provision_set_user_role`, lalu uji dengan JWT asli: katalog anon, checkout dengan idempotency key, alur status lengkap, penolakan akses lintas peran, dan bahwa `manual_transfer`, pembatalan, serta `record_cod_collection` ditolak sebelum kebijakan diatur.
6. Perbarui frontend sesuai bagian "Perubahan yang berdampak pada frontend" di `API_CONTRACT.md` sebelum atau bersamaan dengan produksi (kontrak `create_order` berubah).
7. Hanya setelah staging terverifikasi dan keputusan bisnis ditutup, terapkan ke produksi dengan jadwal dan rencana rollback (restore cadangan; tidak ada migrasi turun).

Langkah-langkah ini belum dijalankan terhadap proyek Supabase mana pun.
