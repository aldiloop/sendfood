# Tasks: backend MVP SendFood

Status per 2026-11-08. `[x]` = selesai dan terverifikasi LOKAL (bukan Supabase cloud). `[ ]` = terbuka atau diblokir. Angka tes: `backend/TEST_EVIDENCE.md`.

## Selesai (lokal)
- [x] Migrasi fondasi (live di Supabase; ledger `20261107042649`, jangan diputar ulang).
- [x] Migrasi hardening ditulis sebagai satu transaksi atomik (lokal teruji; BELUM live).
- [x] RPC: create_order, change_order_status, assign_order_driver, record_cod_collection, list_stores, search_products, list_my_orders, admin_*.
- [x] RLS dan matriks peran diuji via HTTP dengan JWT asli (GoTrue v2.197.0 + PostgREST v16.5 lokal).
- [x] Alur COD end-to-end dan konkurensi diuji via HTTP.
- [x] Perbaikan NaN (constraint + guard RPC) dengan bukti sebelum/sesudah.
- [x] Aktor `completed` fail-closed: tanpa kebijakan eksplisit semua peran (termasuk admin) ditolak `completion_policy_not_configured`; tes SQL+HTTP.
- [x] Runner migrasi memindai kontrol transaksi top-level sebelum eksekusi; bug commit parsial di `8429a92` dibuktikan lalu ditutup.
- [x] CI job HTTP memakai PostgreSQL 16.2 (pgserver) karena runner 26.04 tidak punya `postgresql-16`.
- [x] Suite SQL (Postgres 16.2 + shim) dan suite HTTP; runner gabungan `all.sh`.
- [x] Runner migrasi lokal dengan guard; CI dua-job dengan action dipin SHA (ditulis).
- [x] API_CONTRACT, README backend, checklist, TEST_EVIDENCE diperbarui; `.kiro` ditambahkan.

## Terbuka / diblokir
- [ ] CI dua-job pada commit final: lihat checks PR #1 (pada `8429a92` job HTTP gagal saat instalasi paket).
- [ ] Hardening belum diterapkan ke Supabase mana pun; tidak ada staging. Perlu persetujuan dan runbook operator.
- [ ] Preflight NaN live untuk kolom baru (stores, orders, order_items) belum dilakukan.
- [ ] Ketidakcocokan ledger fondasi (`20261107042649` vs `20261107000000`) belum diselaraskan.
- [ ] DIBLOKIR: Supabase Storage (butuh Node >= 26; tidak ada bucket/policy; unggah foto belum ada).
- [ ] Keputusan bisnis: wilayah/ongkir/radius/koordinat; assignment driver; verifikasi transfer; pembatalan/refund; aktor completion; pencatatan COD.
- [ ] Frontend/PWA belum ada.
- [ ] Uji terhadap Supabase cloud/staging belum dilakukan.
- [ ] Pemeriksaan aturan hackathon belum lengkap; folder `.kiro` bukan bukti kepatuhan sendirian.
