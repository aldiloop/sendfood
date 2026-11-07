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

Tahap: struktural (`verify_schema.sql`), smoke hardening, fixture, tes runtime positif/negatif (`tests/runtime/*.sql`), tes konkurensi (`tests/concurrency/*.sh`), lalu tes migrasi legacy (`tests/migration/*.sh`, memakai database terpisah `sendfood_test_legacy_*` yang di-drop di akhir; perlu `pg_dump` sebaris dengan `psql`). Runner mencetak jumlah lulus, gagal, dan dilewati; exit code bukan nol jika ada yang gagal. Hasil terakhir yang dijalankan di sandbox (Postgres 16.2 via `pgserver`) dicatat di laporan tugas, bukan diasumsikan di sini; jalankan ulang untuk bukti terbaru. Yang diuji hanya Postgres lokal dengan shim Supabase, bukan Supabase Auth/PostgREST sungguhan.

## CI

`.github/workflows/backend-tests.yml` menjalankan runner yang sama terhadap service container Postgres 16 (mode `SENDFOOD_TEST_PGHOST=127.0.0.1`). Workflow `backend-tests` sudah dijalankan di GitHub dan semua run berikut berstatus completed/success, masing-masing satu event `pull_request` dan satu event `push` per commit: commit `41eb679`: [run 42342259072](https://github.com/aldiloop/sendfood/actions/runs/42342259072) (pull_request) dan [run 42342249122](https://github.com/aldiloop/sendfood/actions/runs/42342249122) (push); commit `22e5133`: [run 42342881893](https://github.com/aldiloop/sendfood/actions/runs/42342881893) (pull_request) dan [run 42342878043](https://github.com/aldiloop/sendfood/actions/runs/42342878043) (push). Itu hanya membuktikan runner SQL/konkurensi lulus di service container Postgres 16 dengan shim Supabase; **bukan** uji Supabase Auth, PostgREST, atau staging, yang belum dilakukan. Status CI untuk commit yang lebih baru harus dicek terpisah di tab Actions.

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
   - Sebelum menerapkan, jalankan preflight harga NaN di bawah. Jika ada baris, migrasi akan gagal; jangan diperbaiki otomatis.
   - Atomisitas hanya terbukti untuk runner lokal `psql -1 -f <berkas>` (satu transaksi; lihat `tests/migration/10_legacy_nan_migration.sh`). `psql -f` TANPA `-1` terbukti tidak atomik (perubahan parsial tertinggal saat gagal) dan tidak boleh dipakai. Atomisitas `supabase db push` atau SQL editor BELUM diuji di sini; jika memakai SQL editor, jalankan seluruh berkas dalam satu `begin; ... commit;` eksplisit dan verifikasi rollback di staging lebih dulu.
5. Verifikasi di staging: jalankan `tests/verify_schema.sql`; buat akun uji terpisah per peran (customer, seller, driver, admin) lewat Supabase Auth, promosikan lewat `provision_set_user_role`, lalu uji dengan JWT asli: katalog anon, checkout dengan idempotency key, alur status lengkap, penolakan akses lintas peran, dan bahwa `manual_transfer`, pembatalan, serta `record_cod_collection` ditolak sebelum kebijakan diatur.
6. Perbarui frontend sesuai bagian "Perubahan yang berdampak pada frontend" di `API_CONTRACT.md` sebelum atau bersamaan dengan produksi (kontrak `create_order` berubah).
7. Hanya setelah staging terverifikasi dan keputusan bisnis ditutup, terapkan ke produksi dengan jadwal dan rencana rollback (restore cadangan; tidak ada migrasi turun).

Langkah-langkah ini belum dijalankan terhadap proyek Supabase mana pun.

## Preflight harga NaN sebelum migrasi hardening

Kolom `products.price` di fondasi hanya memakai `check (price >= 0)`, dan di PostgreSQL `'NaN'::numeric >= 0` bernilai benar, sehingga harga NaN dapat tersimpan. Migrasi hardening menambah constraint `products_price_not_nan` dan akan **gagal tertutup** (SQLSTATE `23514`, `check constraint "products_price_not_nan" of relation "products" is violated by some row`, exit psql 3) jika ada baris NaN; seluruh migrasi di-rollback pada jalur `psql -1`, dan baris legacy tidak diubah.

Audit live **BELUM TERLAKSANA**: tidak ada akses baca terotorisasi ke Supabase dari lingkungan pengembangan ini, sehingga keadaan produksi tidak diketahui (jangan menganggap bersih). Operator tepercaya menjalankan query read-only ini di database target:

```sql
select count(*) as jumlah_harga_nan from public.products where price = 'NaN'::numeric;
select id, store_id, name, price, is_available
from public.products where price = 'NaN'::numeric order by created_at limit 100;
```

Jika hasilnya bukan nol, putuskan per baris (memerlukan keputusan pemilik/operator; tidak dilakukan otomatis). Opsi: (a) nonaktifkan produk lalu set harga valid yang disetujui penjual; (b) nonaktifkan produk (`is_available=false`) dan tetapkan harga sementara, mis. 0, hingga penjual memperbaiki; (c) hapus produk jika belum dipakai (periksa dulu `order_items` yang merujuknya; jangan hapus yang punya riwayat). Cadangkan data sebelum DML apa pun. Opsi (b) hanya diuji pada fixture lokal terpisah di `tests/migration/10_legacy_nan_migration.sh`.
