---
inclusion: always
---
# Struktur repository

```text
.kiro/                       steering dan spec proyek (tanpa rahasia/cache)
docs/specs/                  PRD, TRD, AFD, DBD, BSD, IPD
backend/
  API_CONTRACT.md            kontrak frontend-backend (RPC, error, role matrix)
  MVP_GAP_CHECKLIST.md       gap dan keputusan wajib sebelum pilot
  README.md                  tes, CI, runbook migrasi, preflight NaN
  TEST_EVIDENCE.md           bukti hasil tes
  migrations/                foundation (live, jangan diubah/diputar ulang) dan mvp_hardening (belum live)
  scripts/                   apply_migration_local.sh (khusus lokal)
  tests/
    run.sh, all.sh           runner suite SQL dan gabungan
    harness/                 shim Supabase untuk Postgres biasa
    runtime/ concurrency/ migration/   tes SQL dan shell
    stack/                   run_stack.sh, fetch_bins.sh, bootstrap.sql, VERSIONS
    http/                    tes node:test terhadap GoTrue + PostgREST
    verify_schema.sql        pemeriksaan struktur read-only
.github/workflows/backend-tests.yml
.env.example                 placeholder saja
```
Frontend belum ada. Arah branch: `main` (ditinjau), `frontend`, `backend`, `integration`.
