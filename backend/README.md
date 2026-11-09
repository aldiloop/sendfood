# SendFood backend foundation

Backend foundation untuk schema Supabase, Row Level Security (RLS), RPC transaksi/status, pemeriksaan struktur, dan kontrak API. Frontend belum termasuk dalam repository ini.

## Berkas
- `migrations/20261107000000_sendfood_backend_foundation.sql` — migrasi fondasi PostgreSQL.
- `API_CONTRACT.md` — kontrak integrasi frontend–backend.
- `migrations/20261108000000_sendfood_backend_mvp_hardening.sql` - migrasi maju hardening (belum diterapkan ke Supabase mana pun).
- `migrations/20261109000000_sendfood_rls_initplan_fk_indexes.sql` - migrasi maju performa: kebijakan RLS memanggil `auth.uid()`/`current_app_role()` lewat `(select ...)` agar dievaluasi sekali per query (advisor `auth_rls_initplan`), plus index untuk tiga foreign key (advisor `unindexed_foreign_keys`). Logika akses tidak berubah. Diterapkan setelah hardening; belum diterapkan ke Supabase mana pun.
- `MVP_GAP_CHECKLIST.md` - checklist gap MVP dan keputusan wajib sebelum pilot.
- `tests/verify_schema.sql` — pemeriksaan struktur read-only setelah migrasi.
- `scripts/apply_migration_local.sh` - penerap migrasi KHUSUS lokal/sekali pakai (bukan alat deploy produksi).
- `tests/run.sh`, `tests/harness/`, `tests/runtime/`, `tests/concurrency/`, `tests/migration/` - suite SQL pada Postgres lokal dengan shim.
- `tests/stack/`, `tests/http/` - tumpukan HTTP nyata (Postgres + Supabase Auth/GoTrue + PostgREST) dan tes `node:test`.
- `tests/all.sh` - menjalankan kedua suite berurutan.
- `TEST_EVIDENCE.md` - bukti hasil tes aktual (perintah, versi, hitungan, exit code).

## Catatan operasional
- Migrasi fondasi telah diterapkan pada proyek Supabase yang terkait dengan MVP ini. Migrasi hardening `20261108000000` **belum diterapkan** ke Supabase mana pun.
- Tes lulus secara lokal (Postgres lokal, GoTrue dan PostgREST nyata) **bukan** kesiapan pilot/produksi; frontend belum ada dan keputusan bisnis terbuka.
- Frontend/PWA belum ada. Backend ini sendiri **belum siap pilot** sebelum keputusan bisnis ditutup (lihat `MVP_GAP_CHECKLIST.md`).
- Checkout menerima COD saja sampai konfigurasi toko (biaya tetap, radius layanan, dan koordinat) tersedia.
- Radius memakai jarak garis lurus Haversine sebagai asumsi sementara.
- Transfer manual, pembatalan, dan pencatatan COD tertutup (fail closed) lewat tabel `ops_policy` sampai operator mengaturnya; assignment driver sementara hanya admin.
- Pemeriksaan struktur bukan pengganti uji RLS lintas peran. Uji runtime memerlukan akun staging terpisah untuk setiap peran; jangan memakai akun pengguna produksi.
- Jangan pernah menaruh `service_role` key atau kredensial lain di frontend atau commit repository.

## Tes lokal

Ada dua suite; keduanya hanya berjalan di mesin lokal dengan database sekali pakai dan tidak pernah menghubungi Supabase cloud.

### Suite 1: SQL (Postgres 16 + shim Supabase)

```
PG_BIN=<direktori bin postgres> bash backend/tests/run.sh
```

Runner membuat cluster Postgres sementara (socket unix), database `sendfood_test_*`, menerapkan `tests/harness/supabase_shim.sql` (schema `auth`, `auth.users`, `auth.uid()`, role `anon`/`authenticated`/`service_role`), semua migrasi berurutan, `verify_schema.sql`, `tests/runtime/*.sql`, tes konkurensi (`tests/concurrency/*.sh`), dan tes migrasi legacy (`tests/migration/*.sh`, database terpisah `sendfood_test_legacy_*`; perlu `pg_dump` sebaris dengan `psql`). Semuanya dihapus di akhir. Mencetak lulus/gagal/dilewati; exit code bukan nol bila ada yang gagal. Yang diuji: Postgres lokal dengan shim, **bukan** Auth/PostgREST.

Biner Postgres: `PG_BIN=/path/ke/bin`, atau `psql`/`initdb` di PATH, atau mis. `python3 -m venv .pgtools/venv && .pgtools/venv/bin/pip install pgserver` (terverifikasi dengan PostgreSQL 16.2). Bila dijalankan sebagai root, Postgres berjalan sebagai uid 65534. Mode server sendiri: `SENDFOOD_TEST_PGHOST` (hanya `localhost`, `127.0.0.1`, `::1`, atau path socket), `SENDFOOD_TEST_PGPORT`, `SENDFOOD_TEST_PGUSER`; host lain ditolak exit 3. Shim menolak berjalan bila schema `auth` sudah ada atau nama database tidak berawalan `sendfood_test_`.

### Suite 2: tumpukan HTTP nyata

```
bash backend/tests/stack/fetch_bins.sh                # sekali: unduh biner terpin SHA256
PG_BIN=<direktori bin postgres> bash backend/tests/stack/run_stack.sh
```

- Versi dan SHA256 terpin di `tests/stack/VERSIONS`: Supabase Auth (GoTrue) v2.197.0 dan PostgREST v16.5 dari GitHub Releases, diunduh ke `.pgtools/svc` (di-gitignore). PostgreSQL 16.2 lokal. Variabel `STACK_BIN` dapat menunjuk direktori biner yang sudah ada.
- `bootstrap.sql` membuat role mirip Supabase (`anon`, `authenticated`, `service_role`, `authenticator`, `supabase_auth_admin`) pada database `sendfood_stack_*`; GoTrue menjalankan migrasi schema `auth`-nya sendiri, lalu migrasi aplikasi lewat `scripts/apply_migration_local.sh`, lalu PostgREST.
- Semua layanan bind ke 127.0.0.1 pada port acak; JWT secret dan password role acak per run, tidak dicetak; JWT disamarkan di output tes; semuanya dibersihkan saat selesai.
- Tes (`tests/http/*.test.mjs`, `node:test`, `fetch` nyata, tanpa mock): `00_stack_surface`, `10_auth_jwt`, `20_cod_flow`, `30_checkout_negative`, `40_rls_matrix`. Perlu Node 18+.
- **Supabase Storage tidak dijalankan**: Storage v1.90.0 membutuhkan Node >= 26, sedangkan hanya Node 18/20/22/24 tersedia. Storage bukan P0 di PRD; kontrak hanya memakai `image_url` (text), tidak ada bucket/policy. Unggah foto memerlukan migrasi policy Storage yang diuji pada tumpukan yang memuat Storage.
- Nilai ongkir/radius/koordinat di tes adalah data sintetis di database sekali pakai, **bukan** keputusan bisnis.

### Kedua suite sekaligus

```
PG_BIN=<direktori bin postgres> bash backend/tests/all.sh
```

Hasil aktual (perintah, versi, hitungan, exit code) dicatat di [TEST_EVIDENCE.md](TEST_EVIDENCE.md); jalankan ulang untuk bukti terbaru.

## CI

`.github/workflows/backend-tests.yml` kini punya dua job: `runtime-tests` (suite SQL terhadap service container Postgres 16, `SENDFOOD_TEST_PGHOST=127.0.0.1`) dan `http-stack-tests` (tumpukan HTTP nyata; PostgreSQL 16.2 dari `pgserver==0.1.4` karena runner ubuntu-latest 26.04 tidak menyediakan paket `postgresql-16`). Action dipin ke SHA commit (checkout v7.0.1, setup-node v7.1.0).

Riwayat: workflow versi lama (hanya job SQL) pernah lulus di GitHub untuk commit `41eb679` ([run 42342259072](https://github.com/aldiloop/sendfood/actions/runs/42342259072) pull_request, [run 42342249122](https://github.com/aldiloop/sendfood/actions/runs/42342249122) push) dan `22e5133` ([run 42342881893](https://github.com/aldiloop/sendfood/actions/runs/42342881893) pull_request, [run 42342878043](https://github.com/aldiloop/sendfood/actions/runs/42342878043) push). Workflow dua-job pertama kali berjalan pada `8429a92`: `runtime-tests` lulus, `http-stack-tests` gagal sebelum tes (`E: Unable to locate package postgresql-16`); diperbaiki dengan `pgserver`. Status commit terbaru: lihat checks PR #1 dan `TEST_EVIDENCE.md`. CI membuktikan hanya apa yang diuji (Postgres lokal, GoTrue/PostgREST lokal), bukan staging atau produksi Supabase.

## Provisioning admin dan kebijakan (lingkungan tepercaya)

Role selalu `customer` saat akun dibuat dan tidak dapat dinaikkan dari client. Admin pertama dan kebijakan operasional hanya diatur oleh operator tepercaya (Supabase SQL editor, CLI dengan koneksi database admin, atau job CI dengan secret), memakai fungsi yang hanya dapat dieksekusi `service_role`/`postgres`:

```sql
select public.provision_set_user_role('<uuid user>', 'admin', 'alasan');
select public.provision_set_policy('cancellation_enabled', 'true');
```

Jangan menaruh `service_role` key, token, atau password di source, commit, atau frontend; simpan sebagai secret di lingkungan operator. Setiap pemanggilan dicatat di `admin_audit_log`. `.env.example` hanya berisi placeholder.

## Runbook migrasi

### Lokal / sekali pakai: `scripts/apply_migration_local.sh`

```
PGHOST=127.0.0.1 PGPORT=<port> PGUSER=<user> PGDATABASE=sendfood_<nama> bash backend/scripts/apply_migration_local.sh backend/migrations/<berkas>.sql
```

- Hanya menerima `PGHOST` `localhost`/`127.0.0.1`/`::1`/path socket dan `PGDATABASE` berawalan `sendfood_` (prefiks lain hanya lewat `SENDFOOD_MIGRATION_ALLOW_DB_PREFIX`). Selain itu ditolak.
- Sebelum menyentuh database, `scripts/sql_tx_scan.py` memindai statement top-level (komentar, string, identifier ber-kutip dan dollar-quote dilewati, jadi `BEGIN`/`END` di body fungsi tidak salah dibaca). Diterima hanya: (a) tanpa kontrol transaksi sama sekali, dibungkus `--single-transaction`; atau (b) tepat satu `BEGIN` sebagai statement pertama dan satu `COMMIT` terakhir. Selain itu (BEGIN/COMMIT ganda, `END`, `ROLLBACK`, `SAVEPOINT`, psql meta-command atau backslash apa pun di luar komentar/literal, termasuk inline `select 'commit' \gexec` yang terbukti bisa meng-commit transaksi luar, dan `BEGIN ATOMIC`) ditolak exit 65 tanpa eksekusi. Versi runner sebelumnya (`8429a92`) meloloskan `BEGIN;..COMMIT; BEGIN;..ERROR;COMMIT;` dan meninggalkan commit parsial; diperbaiki dan diuji (`tests/migration/10_legacy_nan_migration.sh` bagian H).
- Selalu `psql -X -v ON_ERROR_STOP=1`.
- Gagal: exit 3 dengan pesan `MIGRASI GAGAL (exit 3): <berkas> di-rollback seluruhnya.`
- Ini **bukan alat deploy produksi**; jangan diarahkan ke database Supabase.

### Atomisitas hardening dan `ON_ERROR_STOP`

Berkas hardening adalah SATU transaksi eksplisit: `begin; set local lock_timeout='5s'; set local statement_timeout='120s'; <blok DO prasyarat>; ...; commit;`. Maka atomik meski dijalankan lewat `psql -f` atau ditempel di SQL editor. Namun `psql -f` TANPA `-v ON_ERROR_STOP=1` **keluar dengan kode 0 walau gagal** (gagal diam-diam, walau data tetap di-rollback). Selalu pakai `ON_ERROR_STOP=1`. Bila ada kunci yang ditahan, migrasi gagal cepat (SQLSTATE `55P03`, ~5 detik) dan di-rollback. Prasyarat gagal dengan `hardening_requires_supabase_auth_schema` atau `hardening_requires_foundation_migration`.

### Staging dan produksi

**Tidak ada staging.** Hardening belum diterapkan di mana pun. Aturan:

- **JANGAN PERNAH memutar ulang (replay) atau mengedit migrasi fondasi di remote.** Fondasi sudah diterapkan pada proyek Supabase live.
- **Ketidakcocokan ledger yang diketahui:** ledger migrasi live mencatat fondasi sebagai versi `20261107042649`, bukan `20261107000000` (nama berkas). Jangan "memperbaiki" dengan `supabase db push` tanpa menyelaraskan ledger dan nama berkas lebih dulu; `db push` buta bisa mencoba menerapkan ulang fondasi.
- Tidak ada penulisan/migrasi live tanpa persetujuan eksplisit pemilik. PR ini **tidak mengeksekusi** apa pun terhadap Supabase.

Panduan bagi operator tepercaya di kemudian hari (**tidak dijalankan oleh PR ini**):

1. Pastikan kedua suite lulus pada commit yang akan diterapkan.
2. Cadangkan database (dump/PITR). Idealnya mulai dari proyek/branch staging terpisah, bukan produksi.
3. Periksa ledger (`supabase migration list` atau `supabase_migrations.schema_migrations`): fondasi tercatat (ingat versi `20261107042649`), hardening belum.
4. Jalankan preflight NaN (di bawah) sebagai role yang melihat semua baris. Jika ada baris, berhenti dan putuskan bersama pemilik; jangan perbaiki otomatis.
5. Terapkan HANYA berkas hardening, dengan `psql -X -v ON_ERROR_STOP=1 -f backend/migrations/20261108000000_sendfood_backend_mvp_hardening.sql` ke koneksi admin, atau tempel utuh di SQL editor. Pastikan keluaran tanpa `ERROR`, dan catat ledger sesuai prosedur proyek.
6. Verifikasi: `tests/verify_schema.sql` (read-only), pemeriksaan permukaan RPC, lalu akun uji per peran dengan JWT asli.
7. Perbarui frontend sesuai "Perubahan yang berdampak pada frontend" di `API_CONTRACT.md` (kontrak `create_order` berubah).
8. Rollback: tidak ada migrasi turun; kegagalan di tengah berkas sudah di-rollback otomatis, sedangkan pemulihan setelah commit memakai cadangan.

## Preflight NaN sebelum migrasi hardening

Di PostgreSQL `'NaN'::numeric >= 0` bernilai benar, jadi check `>= 0` fondasi meloloskan NaN. Hardening menambah constraint `products_price_not_nan`, `stores_delivery_fee_not_nan`, `stores_service_radius_not_nan`, `orders_amounts_not_nan`, `order_items_amounts_not_nan`. Baris legacy NaN pada kolom mana pun membuat migrasi **gagal tertutup** (SQLSTATE `23514`, nama constraint di baris ERROR) dan di-rollback seluruhnya; baris tidak pernah diubah otomatis.

Preflight read-only untuk SEMUA kolom (harus dijalankan sebagai role yang melihat semua baris, mis. `postgres`/`service_role` di SQL editor; klien dengan RLS akan melihat sebagian baris saja dan memberi hasil 0 yang menyesatkan):

```sql
select 'products.price' as kolom, count(*) from public.products where price = 'NaN'::numeric
union all select 'stores.delivery_fee', count(*) from public.stores where delivery_fee = 'NaN'::numeric
union all select 'stores.service_radius_km', count(*) from public.stores where service_radius_km = 'NaN'::numeric
union all select 'orders.subtotal', count(*) from public.orders where subtotal = 'NaN'::numeric
union all select 'orders.delivery_fee', count(*) from public.orders where delivery_fee = 'NaN'::numeric
union all select 'orders.total', count(*) from public.orders where total = 'NaN'::numeric
union all select 'order_items.unit_price_snapshot', count(*) from public.order_items where unit_price_snapshot = 'NaN'::numeric
union all select 'order_items.line_total', count(*) from public.order_items where line_total = 'NaN'::numeric;
```

Semua hitungan harus 0. Audit live sebelumnya hanya mencakup `products.price` dan dilaporkan 0 oleh pengguna; kolom-kolom baru (toko, orders, order_items) **belum diaudit live** dan tidak boleh diasumsikan bersih. Jika ada baris, putuskan per baris dengan pemilik/operator (mis. nonaktifkan produk lalu set harga valid yang disetujui; tidak ada hapus untuk baris yang punya riwayat pesanan). Cadangkan sebelum DML apa pun. Jalur gagal-tertutup dan opsi pembersihan diuji hanya pada fixture lokal (`tests/migration/10_legacy_nan_migration.sh`).
