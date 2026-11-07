# AFD — App Flow Documentation
## Send Food

**Versi:** 1.0 | **Tanggal:** 7 November 2026

## 1. Peta navigasi umum
### Area publik/pelanggan
- Splash / loading
- Onboarding singkat (opsional)
- Login / Daftar
- Beranda
- Daftar toko
- Detail toko
- Detail produk
- Keranjang
- Checkout
- Detail/status pesanan
- Riwayat pesanan
- Profil dan alamat

### Area penjual
- Login
- Dashboard penjual
- Pesanan masuk
- Detail pesanan
- Kelola produk
- Tambah/edit produk
- Profil dan pengaturan toko

### Area driver
- Login
- Dashboard driver
- Daftar tugas / tugas aktif
- Detail pengantaran
- Perbarui status pengantaran
- Riwayat pengantaran
- Profil

### Area admin
- Login admin
- Ringkasan operasional
- Manajemen pengguna
- Manajemen penjual/toko
- Manajemen produk
- Manajemen pesanan
- Pengaturan operasional dasar

## 2. Flow pelanggan
1. Buka PWA.
2. Jika belum login, pengguna dapat menjelajah katalog publik; login diminta sebelum checkout.
3. Pilih toko.
4. Lihat menu dan gunakan pencarian/filter.
5. Pilih produk, jumlah, dan catatan item bila tersedia.
6. Masukkan ke keranjang.
7. Periksa ringkasan: item, subtotal, biaya pengiriman, total.
8. Pilih/simpan alamat dan catatan pengantaran.
9. Pilih COD atau transfer manual.
10. Konfirmasi pesanan.
11. Lihat status pesanan dan riwayat.

**Cabang error:** toko tutup, produk habis/nonaktif, harga berubah, alamat tidak lengkap, jaringan gagal, atau pesanan ditolak. UI harus menjelaskan tindakan berikutnya dan tidak menghapus keranjang tanpa konfirmasi.

## 3. Flow penjual
1. Login.
2. Dashboard menampilkan ringkasan dan pesanan baru.
3. Buka detail pesanan.
4. Terima atau tolak dengan alasan bila ditolak.
5. Jika diterima, ubah status menjadi diproses.
6. Tandai siap diambil.
7. Serahkan pesanan kepada driver.
8. Pantau status sampai selesai.

Penjual hanya melihat pesanan toko yang menjadi kewenangannya.

## 4. Flow driver
1. Login.
2. Buka dashboard dan lihat tugas yang ditugaskan/tersedia sesuai aturan assignment final.
3. Buka detail: kode pesanan, titik/alamat, kontak yang diizinkan, dan catatan.
4. Konfirmasi pengambilan.
5. Tandai pesanan diambil.
6. Antar ke pelanggan.
7. Tandai terkirim; penyelesaian akhir mengikuti aturan verifikasi yang disepakati.

Jangan tampilkan tugas milik driver lain tanpa izin.

## 5. Flow admin
1. Login dengan akun admin.
2. Lihat ringkasan pesanan dan aktivitas.
3. Kelola/validasi akun penjual dan driver.
4. Moderasi toko dan produk.
5. Pantau pesanan dan bantu penyelesaian masalah.
6. Ubah pengaturan operasional hanya melalui kontrol yang diizinkan.

## 6. Flow pembayaran
### COD
Checkout → pilih COD → pesanan dibuat → penjual menerima → driver mengantar → pelanggan membayar saat menerima → pesanan diselesaikan.

### Transfer manual
Checkout → pilih transfer manual → tampilkan instruksi rekening/metode yang dikonfirmasi admin → pelanggan melakukan transfer di luar aplikasi → pelanggan mengirim bukti bila fitur bukti disetujui → pihak yang ditunjuk memverifikasi → status pembayaran diperbarui → pesanan diproses.

Transfer manual bukan pembayaran otomatis. Jangan menampilkan status “lunas” sebelum diverifikasi.

## 7. Navigasi dan UX
- Navigasi utama pelanggan menggunakan pola mobile yang mudah dijangkau ibu jari.
- Aksi utama tiap halaman harus jelas.
- Dashboard penjual/driver memprioritaskan tugas yang perlu tindakan.
- Sediakan konfirmasi sebelum tindakan berisiko seperti menolak pesanan atau membatalkan.
- Semua flow memiliki loading, empty, error, dan success state.

## 8. Flow yang belum diputuskan
- Driver mengambil tugas sendiri atau ditugaskan admin/penjual.
- Siapa memverifikasi transfer manual.
- Kapan pelanggan dapat membatalkan pesanan.
- Apakah bukti serah-terima diperlukan.
