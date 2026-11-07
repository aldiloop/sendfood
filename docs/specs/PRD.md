# PRD — Product Requirements Document
## Send Food

**Versi:** 1.0 (baseline MVP)  
**Tanggal:** 7 November 2026  
**Status:** Draft kerja — siap ditinjau sebelum implementasi

## 1. Ringkasan produk
Send Food adalah aplikasi pemesanan makanan lokal yang menghubungkan pelanggan, penjual makanan, dan driver dalam satu wilayah desa pada tahap awal. Fokus MVP adalah membuat proses menemukan makanan, memesan, menerima pesanan, dan mengantarkan pesanan berjalan sederhana serta dapat diuji dari awal sampai selesai.

Send Food dibangun **PWA mobile-first** terlebih dahulu. APK Android merupakan tahap lanjutan, bukan syarat MVP.

## 2. Masalah yang ingin diselesaikan
- Pelanggan membutuhkan cara praktis menemukan makanan dari penjual lokal.
- Penjual lokal membutuhkan kanal digital sederhana untuk menampilkan produk dan mengelola pesanan.
- Driver membutuhkan informasi pesanan dan alamat pengantaran yang jelas.
- Admin membutuhkan kontrol operasional dasar agar aktivitas platform dapat dipantau.

## 3. Sasaran dan indikator keberhasilan
### Sasaran MVP
1. Pelanggan dapat melihat daftar penjual dan produk.
2. Pelanggan dapat membuat pesanan dengan metode COD atau transfer manual.
3. Penjual dapat menerima/menolak dan memperbarui status pesanan.
4. Driver dapat melihat tugas pengantaran dan memperbarui status pengiriman.
5. Admin dapat mengelola pengguna, penjual, produk, dan pesanan secara dasar.

### Indikator penerimaan
- Satu alur transaksi uji berhasil dari pelanggan sampai pesanan selesai.
- Hak akses setiap peran membatasi data dan tindakan sesuai kewenangannya.
- Harga, jumlah, biaya pengiriman, dan total pesanan konsisten antara UI dan backend.
- Tampilan utama dapat digunakan pada layar ponsel.
- Tidak ada kredensial rahasia yang tersimpan di source code frontend.

## 4. Pengguna dan peran
| Peran | Kebutuhan utama |
|---|---|
| Customer / Pelanggan | Menemukan makanan, memesan, membayar, melacak status |
| Seller / Penjual | Mengelola toko, menu, ketersediaan, dan pesanan |
| Driver | Melihat penugasan, mengambil, dan mengantar pesanan |
| Admin | Mengelola operasional, akun, toko, produk, dan pesanan |

## 5. Ruang lingkup MVP
### Termasuk
- Registrasi/login dan profil pengguna.
- Pemisahan akses berdasarkan peran.
- Daftar toko/penjual dan katalog produk.
- Pencarian dan pengurutan/filter: terdekat, terjauh, termurah, termahal, rating tertinggi, dan biaya pengiriman.
- Keranjang dan checkout.
- Alamat/catatan pengantaran.
- Metode pembayaran COD dan transfer manual.
- Riwayat pesanan dan status pesanan.
- Dashboard penjual.
- Dashboard driver.
- Dashboard admin dasar.
- PWA responsif dan instalasi melalui browser yang mendukung.

### Tidak termasuk pada MVP
- Payment gateway otomatis.
- Dompet digital, saldo, atau escrow.
- Pelacakan GPS real-time.
- Chat real-time pelanggan–penjual–driver.
- Program loyalitas, voucher kompleks, dan langganan.
- Multi-kota/multi-wilayah.
- Aplikasi native APK sebagai deliverable pertama.

## 6. Alur transaksi utama
1. Pelanggan memilih toko dan produk.
2. Pelanggan memasukkan produk ke keranjang.
3. Pelanggan mengisi alamat dan catatan.
4. Pelanggan memilih COD atau transfer manual.
5. Sistem membuat pesanan dengan status awal yang jelas.
6. Penjual menerima atau menolak pesanan.
7. Jika diterima, pesanan diproses dan disiapkan.
8. Driver ditugaskan/menyetujui tugas sesuai mekanisme yang disepakati.
9. Driver mengambil dan mengantarkan pesanan.
10. Pesanan ditandai selesai; pelanggan dapat melihat riwayat.

Status dan aturan transisi final harus konsisten dengan TRD, BSD, dan kontrak API.

## 7. Aturan bisnis awal
- Satu pesanan MVP berasal dari satu toko. Multi-toko dalam satu checkout ditunda.
- Harga produk dan biaya pengiriman disimpan sebagai snapshot pada detail pesanan agar riwayat tidak berubah ketika harga katalog berubah.
- Produk yang tidak tersedia tidak dapat dipesan.
- COD dibayar saat pesanan diterima.
- Transfer manual memerlukan instruksi pembayaran dan verifikasi oleh pihak yang ditentukan admin/penjual; jangan mengklaim pembayaran otomatis.
- Pembatalan setelah penjual memproses pesanan mengikuti aturan operasional yang akan ditetapkan sebelum pilot.
- Rating dapat ditunda jika waktu implementasi terbatas; jangan menjadikan rating palsu atau data contoh sebagai rating nyata.

## 8. Asumsi dan keputusan yang belum final
- Nama desa/wilayah peluncuran: **belum ditentukan**.
- Rumus biaya pengiriman, radius layanan, dan penentuan driver: perlu disepakati sebelum pilot.
- Apakah driver dipilih admin, penjual, atau mengambil tugas dari daftar: perlu diputuskan.
- Alur bukti transfer manual dan pihak yang memverifikasi: perlu diputuskan.
- Kebijakan pembatalan, refund, komisi, dan jam operasional: perlu ditetapkan.
- Rating/review: opsional untuk iterasi MVP berikutnya.

## 9. Risiko utama
- Operasional driver dan biaya pengiriman belum ditetapkan.
- Transfer manual berpotensi memerlukan verifikasi di luar aplikasi.
- Data lokasi/alamat yang tidak akurat dapat menghambat pengantaran.
- Hak akses yang salah dapat mengekspos data pesanan.
- Keterbatasan waktu/kredit hackathon menuntut prioritas pada satu alur end-to-end.

## 10. Prioritas
**P0:** autentikasi, katalog, keranjang/checkout, pembuatan pesanan, status penjual, tugas/status driver, kontrol akses.  
**P1:** filter/pengurutan, riwayat, transfer manual, dashboard admin yang lebih lengkap.  
**P2:** rating, notifikasi lanjutan, analitik, fitur promosi.

## 11. Definisi selesai
MVP dianggap selesai ketika skenario uji pelanggan → penjual → driver → selesai berjalan pada lingkungan uji, data tersimpan di Supabase, hak akses diuji, dan PWA dapat digunakan pada perangkat mobile.
