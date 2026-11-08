# Design: backend MVP SendFood

Rincian kontrak: `backend/API_CONTRACT.md`. SQL yang berlaku: `backend/migrations/`.

## Skema (ringkas)
Tabel: `profiles`, `stores`, `products`, `orders`, `order_items`, `order_status_history` (fondasi); `customer_addresses`, `ops_policy`, `admin_audit_log` (hardening). Order menyimpan snapshot nama/harga item. RLS aktif di semua tabel `public`.

## Akses
- Client hanya `select` pada order/item/riwayat; semua tulis lewat RPC `SECURITY DEFINER` (`create_order`, `change_order_status`, `assign_order_driver`, `record_cod_collection`, `admin_*`). Trigger `direct_write_forbidden` sebagai pertahanan berlapis.
- Katalog: `list_stores`, `search_products` (SECURITY INVOKER, RLS tetap berlaku), `list_my_orders`.
- `provision_set_user_role`, `provision_set_policy`: hanya `service_role`.
- Grant minimal: setiap fungsi baru `revoke` lalu `grant` eksplisit karena default privileges Supabase.

## Fail closed
`ops_policy` menyimpan kebijakan (`cancellation_enabled`, `cancellation_allowed_statuses`, `manual_transfer_enabled`, `cod_collection_recording_enabled`, `cod_collection_actor`, `completion_actor`). Nilai default menolak; `completion_actor` sengaja tidak punya baris default sehingga `completed` ditolak `completion_policy_not_configured` untuk semua peran termasuk admin. `manual_transfer` tetap ditolak walau flag aktif karena workflow belum ada.

## Integritas angka
Constraint `*_not_nan` pada harga, ongkir, radius, jumlah order dan item. `create_order` memperlakukan data NaN sebagai tidak terkonfigurasi atau di luar radius. Haversine garis lurus adalah asumsi sementara.

## Migrasi dan pengujian
Hardening = satu transaksi eksplisit dengan `lock_timeout`/`statement_timeout` dan prasyarat; gagal di-rollback. Runner lokal `apply_migration_local.sh` membatasi target. Dua suite: SQL dengan shim, dan tumpukan HTTP (Postgres + GoTrue + PostgREST) dengan JWT asli. Tidak ada Storage dalam tumpukan.
