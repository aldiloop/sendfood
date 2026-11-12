#!/usr/bin/env bash
# Menjalankan SELURUH suite backend lokal: (1) suite SQL pada Postgres sekali pakai + shim Supabase,
# (2) stack HTTP dengan Supabase Auth (GoTrue) + PostgREST asli. Exit non-nol bila salah satu gagal.
# Tidak pernah menyentuh Supabase cloud. Prasyarat: lihat backend/README.md.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
echo "########## 1/2 Suite SQL (Postgres + shim)"
bash "$ROOT/backend/tests/run.sh"; rc1=$?
echo "########## 2/2 Stack HTTP (GoTrue + PostgREST asli)"
bash "$ROOT/backend/tests/stack/run_stack.sh"; rc2=$?
echo "########## Hasil: suite SQL exit=$rc1 | stack HTTP exit=$rc2"
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ]
