---
inclusion: always
---
# Teknologi dan perintah tes

## Stack
- Backend: Supabase (PostgreSQL, Auth, PostgREST), RLS, RPC `plpgsql`. Migrasi SQL versioned di `backend/migrations/`.
- Frontend: belum dipilih/dibuat. Klien hanya memakai URL dan anon (publishable) key.
- Supabase Storage: tidak digunakan/diuji (v1.90.0 butuh Node >= 26; tersedia Node 18/20/22/24). Foto hanya `image_url` text.

## Versi yang diuji lokal
PostgreSQL 16.2; Supabase Auth (GoTrue) v2.197.0; PostgREST v16.5 (SHA256 terpin di `backend/tests/stack/VERSIONS`, diunduh `backend/tests/stack/fetch_bins.sh` ke `.pgtools/svc` yang di-gitignore).

## Perintah
- Suite SQL (Postgres + shim, bukan Auth/PostgREST): `PG_BIN=<pg bin> bash backend/tests/run.sh`
- Tumpukan HTTP nyata: `bash backend/tests/stack/fetch_bins.sh` lalu `PG_BIN=<pg bin> bash backend/tests/stack/run_stack.sh`
- Keduanya: `PG_BIN=<pg bin> bash backend/tests/all.sh`
- Migrasi lokal saja: `PGHOST=127.0.0.1 PGDATABASE=sendfood_x bash backend/scripts/apply_migration_local.sh <berkas.sql>`
- Pemeriksaan whitespace: `git diff --check`
Hasil aktual dan angka bertanggal: `backend/TEST_EVIDENCE.md`. CI: `.github/workflows/backend-tests.yml` (job `runtime-tests`, `http-stack-tests`, action dipin SHA).

## Konvensi
Dokumen berbahasa Indonesia. Perubahan schema/RLS selalu lewat migrasi maju baru plus pembaruan `API_CONTRACT.md`; jangan edit migrasi yang sudah live.
