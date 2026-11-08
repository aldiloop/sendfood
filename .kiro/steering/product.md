---
inclusion: always
---
# Produk: SendFood MVP

SendFood adalah aplikasi pemesanan makanan lokal berbasis PWA mobile-first untuk empat peran: pelanggan, penjual, driver, admin. Sumber kebenaran: `docs/specs/PRD.md` (urutan baca PRD, TRD, AFD, DBD, BSD, IPD). BSD dan sebagian TRD adalah rancangan awal, bukan schema yang berlaku; schema yang berlaku ada di `backend/migrations/` dan kontrak di `backend/API_CONTRACT.md`.

## Cakupan
- P0: autentikasi, katalog, keranjang/checkout, pembuatan pesanan, status penjual, tugas/status driver, kontrol akses.
- P1: filter/pengurutan, riwayat, transfer manual, dashboard admin yang lebih lengkap.
- P2 (ditunda): rating, notifikasi lanjutan, analitik, promosi.
- Di luar MVP: GPS real-time, chat, loyalitas/voucher, multi-kota, APK native, multi-toko per checkout.

## Status aktual
- Hanya backend yang ada. Frontend/PWA belum dibuat; jangan mengasumsikan framework.
- Hanya COD yang aktif. Transfer manual, pembatalan, dan pencatatan COD tertutup (fail closed) sampai operator memutuskan.
- Backend lulus tes lokal bukan berarti siap pilot/produksi. Jangan mencampur keduanya dalam klaim apa pun.

## Keputusan bisnis yang masih terbuka (jangan mengarang)
1. Wilayah pilot, rumus ongkir, radius layanan, koordinat nyata toko.
2. Mekanisme assignment driver selain jalur admin yang ada.
3. Verifikator transfer manual, bukti, rekening.
4. Pembatalan dan refund.
5. Aktor penyelesaian pesanan (`completed`).
6. Pencatatan penagihan COD.
Nilai sintetis di tes bukan keputusan bisnis. Rincian: `backend/MVP_GAP_CHECKLIST.md`.
