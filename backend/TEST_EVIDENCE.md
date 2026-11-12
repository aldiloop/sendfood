# Bukti tes backend SendFood

Semua hasil di bawah berasal dari run **lokal** (Postgres sekali pakai, GoTrue dan PostgREST nyata di 127.0.0.1). Tidak ada kontak ke Supabase cloud. Ini bukti kesiapan backend lokal, **bukan** kesiapan pilot/produksi.

> Run final: 2026-11-12, pohon kerja di atas `f0dfefd` dengan migrasi baru `20261112000002_sendfood_admin_completion_cancel_guards.sql`, tes baru `92_admin_completion_and_cancel_guards.sql`, dan skenario E `80_completion_policy.sql` yang diperbarui (admin selesai kini wajib alasan), dan seluruh perubahan commit ini (kode final identik dengan commit yang memuat file ini). Hanya dokumen yang diubah setelah run final.

## Lingkungan

| Komponen | Versi / sumber |
|---|---|
| PostgreSQL | 16.2 (lokal, sekali pakai) |
| Supabase Auth (GoTrue) | v2.197.0, GitHub Releases, SHA256 di `tests/stack/VERSIONS` |
| PostgREST | v16.5, GitHub Releases, SHA256 di `tests/stack/VERSIONS` |
| Supabase Storage | TIDAK dijalankan (v1.90.0 butuh Node >= 26; tersedia Node 18/20/22/24) |
| Node (tes HTTP) | `node:test`, `fetch` nyata, tanpa mock |

## Perintah dan hasil

| Suite | Perintah | Lulus | Gagal | Dilewati | Exit code | Tanggal | Commit |
|---|---|---|---|---|---|---|---|
| SQL (Postgres + shim; bukan Auth/PostgREST) | `PG_BIN=<pg bin> bash backend/tests/run.sh` | 563 | 0 | 0 | 0 | 2026-11-12 | commit ini |
| HTTP stack (Postgres + GoTrue + PostgREST) | `PG_BIN=<pg bin> bash backend/tests/stack/run_stack.sh` | 47 | 0 | 0 | 0 | 2026-11-12 | commit ini |
| Gabungan | `PG_BIN=<pg bin> bash backend/tests/all.sh` | 610 | 0 | 0 | 0 | 2026-11-12 | commit ini |

Cakupan HTTP: `00_stack_surface`, `10_auth_jwt`, `20_cod_flow`, `30_checkout_negative`, `40_rls_matrix`. Log mentah run final (disanitasi, JWT tidak tercetak) diekspor di luar repo sebagai `sendfood-backend-final-tests.log`.

## Bukti NaN (sebelum dan sesudah perbaikan)

| Keadaan | Hasil | Sumber |
|---|---|---|
| Sebelum perbaikan (fixture lokal, tes `70_store_nonfinite`) | lulus=416, gagal=18; ongkir NaN menghasilkan total NaN, radius NaN menerima alamat ~60 km, `list_stores` melaporkan `within_service_radius=true` | log lokal `sendfood-backend-final-nonfinite-before-fix.log` (di luar repo, tidak di-commit) |
| Setelah perbaikan (hardening maju) | suite SQL lulus=563 gagal=0 (di atas, run 2026-11-12); kolom NaN ditolak constraint `23514`; `create_order` tertutup; `within_service_radius=null` | `tests/runtime/60_price_nan.sql`, `70_store_nonfinite.sql`, `tests/migration/10_legacy_nan_migration.sh` |

## Migrasi baru 12 Nov 2026 (pembatalan per aktor + rumus ongkir)

Keputusan pemilik 12 Nov 2026, diuji di run final yang sama (angka di atas sudah mencakupnya):

| Migrasi | Perilaku | Tes |
|---|---|---|
| `20261112000000_sendfood_cancel_per_actor.sql` | Customer batal hanya dari `pending_seller`; seller dari `pending_seller,accepted,preparing`; admin dari status mana pun; alasan wajib; `payment_status` tidak disentuh. Kunci baru `cancellation_allowed_statuses_seller`; seed `cancellation_enabled='true'`, `cancellation_allowed_statuses='pending_seller'`, `cancellation_allowed_statuses_seller='pending_seller,accepted,preparing'` | `tests/runtime/90_cancellation_per_actor.sql` |
| `20261112000001_sendfood_distance_fee.sql` | Ongkir rumus jarak: ≤1.000 m → Rp2.000; >1.000 m → 2.000 + `ceil((m−1.000)/100)×200` (2.350 m → 4.800); helper `delivery_fee_for_distance` (internal, tidak di-grant ke anon/authenticated); `stores.delivery_fee` tidak lagi dibaca/diwajibkan saat checkout; radius maks 5 km (`stores_service_radius_max_5km`) | `tests/runtime/91_delivery_fee_formula.sql` |
| `20261112000002_sendfood_admin_completion_cancel_guards.sql` | Batal dari status terminal (`completed`/`cancelled`/`rejected`) ditolak untuk SEMUA aktor termasuk admin (`cancel_from_terminal_status_not_allowed`); admin tetap bypass daftar status untuk status non-terminal. Admin menandai selesai wajib alasan (`completion_reason_required`); driver/pelanggan/penjual sesuai `completion_actor` tetap tanpa alasan wajib. Skenario E `80_completion_policy.sql` diperbarui ke kontrak baru (admin selesai + alasan, alasan tercatat di riwayat) | `tests/runtime/92_admin_completion_and_cancel_guards.sql` (14 asersi baru) |

Catatan dari run ini: `stores.delivery_fee` NaN tidak lagi memengaruhi checkout (ongkir memakai rumus jarak; `70_store_nonfinite.sql` bagian B ditulis ulang untuk itu). `UPDATE stores.service_radius_km = NaN` kini ditolak constraint `stores_service_radius_max_5km` duluan (`NaN <= 5` bernilai false) — perilaku tetap benar (NaN ditolak), hanya nama constraint yang dilaporkan berbeda.

## Penutupan gate tambahan (run final yang sama)

| Gate | Bukti sebelum perbaikan | Setelah perbaikan |
|---|---|---|
| Aktor `completed` tanpa kebijakan | `c122079`/`8429a92`: seed `completion_actor=customer`, fallback `coalesce(...,'customer')`, admin selalu boleh | Tanpa baris/nilai tidak valid: semua peran termasuk admin ditolak `completion_policy_not_configured`, order/history tidak berubah (`runtime/80_completion_policy.sql`, `http/20_cod_flow`) |
| Runner menerima `BEGIN;..COMMIT; BEGIN;..ERROR;COMMIT;` | runner `8429a92`: exit 3 dan pesan "di-rollback seluruhnya" tetapi tabel `tx_a` tertinggal (log `sendfood-backend-final-runner-before-fix.log`, di luar repo) | Ditolak exit 65 sebelum eksekusi; jebakan komentar/string/dollar-quote diterima; tidak ada tabel tertinggal (`migration/10_legacy_nan_migration.sh` bagian H) |
| CI `http-stack-tests` | `8429a92`: gagal `E: Unable to locate package postgresql-16` (runner 26.04) | PostgreSQL 16.2 via `pgserver==0.1.4`; `708bed1` masih gagal karena Python runner tidak punya wheel pgserver -> `actions/setup-python` (Python 3.11, dipin SHA) |
| Meta-command inline `select 'commit' \gexec` | runner `708bed1`: pemindai `own`, exit 3 "di-rollback seluruhnya" tetapi tabel `rx_q` tertinggal (log `sendfood-backend-final-gexec-before-fix.log`, di luar repo) | Semua backslash di luar komentar/literal ditolak exit 65 sebelum eksekusi (`inline_gexec`, `semicolon_meta`, `inline_g`); `E'..\\..'`, string standar dan dollar-quote yang memuat backslash tetap lulus |

## CI

| Workflow | Status |
|---|---|
| `backend-tests.yml` dua job (`runtime-tests`, `http-stack-tests`), action dipin SHA | Lulus pada `e798fab`: empat check-run sukses (run [42491401976](https://github.com/aldiloop/sendfood/actions/runs/42491401976) dan [42491398283](https://github.com/aldiloop/sendfood/actions/runs/42491398283), masing-masing dua job). Commit sesudahnya: lihat checks PR #1 |
| Versi lama (hanya job SQL) | Lulus pada `41eb679` dan `22e5133` (lihat `README.md`) |

## Belum dibuktikan

- Penerapan hardening ke Supabase sungguhan (staging ada, tetapi keadaan schema-nya belum diverifikasi; hardening tidak diterapkan oleh PR ini).
- Audit NaN produksi pada kolom baru. Staging 2026-11-09: preflight dari `README.md` mengembalikan 0 untuk delapan kolom, tetapi role sesi tidak diperiksa sehingga visibilitas semua baris belum terbukti.
- Penegakan read-only produksi di tingkat role (hanya `transaction_read_only = on` untuk satu query) dan pencabutan token lama. Rincian: `MVP_GAP_CHECKLIST.md`, bagian Gate hosted.
- Storage (belum diimplementasi), frontend/PWA, keputusan bisnis.

Angka 563/47/610 di atas berasal dari run 2026-11-12 (migrasi 20261112000002 + tes 92 + skenario E 80 yang diperbarui). Angka 549/47/596 berasal dari run 2026-11-12 sebelumnya (commit `f0dfefd`). Angka lama 507/47/554 berasal dari run 2026-11-08 (commit `278513a`).
