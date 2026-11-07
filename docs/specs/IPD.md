# IPD — Implementation Plan Documentation
## Send Food

**Versi:** 1.0 | **Tanggal:** 7 November 2026  
**Strategi:** MVP bertahap, PWA terlebih dahulu, biaya awal serendah mungkin (target Rp0 selama memungkinkan).

## 1. Strategi pelaksanaan
Bangun satu alur transaksi end-to-end yang benar-benar berfungsi sebelum memperluas fitur. Hindari mengerjakan semua dashboard dan fitur tambahan sekaligus. Kiro Web/Cue menangani backend; Antigravity/Muse menangani frontend. Gunakan GitHub dan kontrak API sebagai titik koordinasi.

## 2. Tahapan kerja
### Fase 0 — Persiapan dan verifikasi
- Periksa repository, struktur folder, package/config, branch, dan fitur yang sudah ada.
- Tetapkan wilayah pilot (saat ini belum ditentukan).
- Sepakati aturan biaya kirim, driver assignment, pembatalan, dan transfer manual.
- Buat issue/task board dan definisi selesai.
**Output:** baseline repository dan keputusan MVP yang tercatat.

### Fase 1 — Fondasi backend
**Cue**
- Siapkan proyek Supabase dan environment.
- Buat migrasi schema minimum.
- Implementasikan Auth/profile dan role.
- Terapkan RLS dan uji akses silang.
- Buat kontrak API untuk katalog, checkout/order, dan perubahan status.
**Gate:** schema, RLS, dan kontrak API diverifikasi sebelum Muse mengintegrasikan.

### Fase 2 — Fondasi frontend
**Muse**
- Inspeksi repository dan ikuti stack aktual.
- Bangun design tokens, layout mobile, navigasi, auth screens.
- Buat komponen kartu toko/produk, form, status, loading/empty/error.
- Gunakan mock data hanya sementara dan tandai jelas.
**Gate:** tampilan responsif dan alur navigasi dasar dapat diuji.

### Fase 3 — Katalog dan keranjang
- Hubungkan daftar toko/produk.
- Implementasikan pencarian dan sort/filter yang didukung data.
- Implementasikan detail produk dan keranjang.
- Validasi harga/ketersediaan dari backend.
**Gate:** pelanggan dapat menyusun keranjang valid.

### Fase 4 — Checkout dan pemrosesan pesanan
- Implementasikan alamat/catatan dan COD.
- Tambahkan transfer manual hanya setelah aturan verifikasi disepakati.
- Buat order dan order items secara konsisten.
- Dashboard penjual: terima/tolak, proses, siap diambil.
**Gate:** satu pesanan tercatat dan dapat dikelola penjual.

### Fase 5 — Driver dan penyelesaian
- Implementasikan mekanisme assignment driver yang telah diputuskan.
- Dashboard driver: tugas, detail, ambil, antar, selesai.
- Sinkronkan timeline status pelanggan.
**Gate:** transaksi uji berhasil sampai selesai.

### Fase 6 — Hardening dan rilis pilot
- Uji role/RLS, validasi, error handling, dan edge cases.
- Uji perangkat mobile dan koneksi lambat.
- Perbaiki aksesibilitas dan performa.
- Siapkan PWA installability, ikon, metadata, dan deployment.
- Siapkan akun demo dan data uji yang tidak mengandung data pribadi nyata.
**Gate:** checklist acceptance terpenuhi.

## 3. Pembagian kerja agent
| Area | Cue (Kiro Web) | Muse (Antigravity) |
|---|---|---|
| PRD/keputusan produk | Konsultasi, tidak mengubah keputusan sepihak | Konsultasi, tidak mengubah keputusan sepihak |
| Schema/migrasi/RLS | Owner | Tidak mengubah |
| Backend/API contract | Owner | Mengonsumsi kontrak |
| UI/UX/components | Tidak mengubah | Owner |
| Frontend integration | Menyediakan contract/test data | Owner |
| Integration testing | Backend tests | UI/e2e bersama |
| Perubahan lintas area | Review dampak dan update contract | Ajukan perubahan contract |

## 4. Strategi branch dan integrasi
- Gunakan branch terpisah, misalnya `backend/cue` dan `frontend/muse`, disesuaikan dengan repository aktual.
- Perubahan masuk melalui pull request/commit yang dapat ditinjau.
- Jangan mengedit file yang sama secara bersamaan.
- Integrasikan setelah kontrak API stabil.
- Setiap perubahan schema harus disertai migrasi dan pembaruan dokumentasi.

## 5. Urutan prioritas backlog
**P0**
1. Inspeksi repo dan konfigurasi.
2. Auth + profil + role.
3. RLS.
4. Katalog toko/produk.
5. Cart + checkout COD.
6. Order lifecycle penjual.
7. Driver assignment + lifecycle.
8. Riwayat/status pelanggan.

**P1**
1. Transfer manual.
2. Filter jarak/harga/biaya kirim.
3. Admin management lebih lengkap.
4. Upload foto produk.
5. Notifikasi dasar.

**P2**
1. Rating/review.
2. Promo/voucher.
3. Analitik.
4. GPS real-time dan chat.

## 6. Acceptance checklist
- [ ] Pelanggan dapat daftar/login/logout.
- [ ] Peran pengguna tidak dapat dimanipulasi dari client.
- [ ] Pelanggan dapat melihat toko dan produk aktif.
- [ ] Pelanggan dapat membuat pesanan COD.
- [ ] Total dihitung dan divalidasi backend.
- [ ] Penjual hanya melihat pesanan tokonya.
- [ ] Penjual dapat menerima/menolak dan memperbarui status yang sah.
- [ ] Driver hanya melihat tugas yang ditugaskan.
- [ ] Driver dapat memperbarui status sesuai transisi.
- [ ] Pelanggan dapat melihat status dan riwayat pesanan sendiri.
- [ ] RLS menolak akses silang.
- [ ] PWA dapat digunakan pada layar ponsel.
- [ ] Loading, empty, error, dan success state tersedia.
- [ ] Tidak ada secret di bundle frontend.

## 7. Risiko dan mitigasi
- **Kredit/tool terbatas:** prioritaskan P0; jangan membangun fitur nice-to-have.
- **Kontrak berubah:** versioning dan komunikasi sebelum integrasi.
- **Schema salah:** migrasi kecil, review, dan tes RLS sebelum frontend.
- **Wilayah belum dipilih:** jangan mengunci radius, tarif, atau koordinat.
- **Operasional belum jelas:** putuskan driver assignment dan transfer sebelum fase terkait.
- **Koneksi pengguna:** optimalkan gambar, loading, dan ukuran bundle.

## 8. Kaitan hackathon
Untuk Kiroween 2026, pastikan penggunaan Kiro nyata dan dapat didemonstrasikan, repository publik memenuhi ketentuan resmi, aplikasi dapat diuji, dan video demo mengikuti batas durasi/ketentuan penyelenggara. Periksa kembali halaman resmi sebelum submission karena aturan dapat berubah. Tema/kategori hackathon harus dipilih secara sadar; jangan mengubah seluruh UI menjadi horor kecuali kategori yang dipilih memang menuntutnya.

## 9. Laporan progres harian
Setiap agent melaporkan:
- Selesai (tautan commit/PR bila ada).
- Sedang dikerjakan.
- Terhambat dan keputusan yang dibutuhkan.
- File/schema/API yang berubah.
- Cara menguji hasil.
- Risiko terhadap agent lain.

## 10. Aturan anti-halusinasi proyek
- Selalu inspeksi file dan konfigurasi aktual sebelum mengubah.
- Jangan mengarang file, fungsi, endpoint, fitur platform, atau kemampuan tool.
- Jangan menyatakan integrasi berhasil sebelum diuji.
- Tandai asumsi sebagai asumsi dan keputusan yang belum final sebagai pending.
- Jangan menghapus fungsi yang sudah berjalan tanpa alasan dan persetujuan.
