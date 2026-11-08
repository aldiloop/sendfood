# TRD — Technical Requirements Document
## Send Food

**Versi:** 1.0 | **Tanggal:** 7 November 2026 | **Status:** Draft teknis untuk validasi

## 1. Arsitektur yang dituju
- **Frontend:** PWA mobile-first, dikerjakan dengan Kiro.
- **Backend/data:** Supabase, dikerjakan dengan Kiro.
- **Database:** PostgreSQL yang disediakan Supabase.
- **Authentication:** Supabase Auth.
- **Authorization:** role-based access control dan Row Level Security (RLS).
- **File storage:** Supabase Storage bila diperlukan untuk foto produk/avatar.
- **Source control:** GitHub dengan branch terpisah untuk frontend dan backend serta branch integrasi.

Teknologi framework frontend, package manager, dan pola routing harus mengikuti hasil inspeksi repository aktual. Jangan mengasumsikan stack atau membuat file konfigurasi sebelum memeriksa project.

## 2. Kepemilikan pengembangan
Seluruh pengembangan dikerjakan dengan **Kiro**, backend maupun frontend.

| Area | Cakupan | Aturan |
|---|---|---|
| Backend | Supabase, migrasi/schema, RLS, backend logic, API contract, backend tests | Perubahan schema/RLS selalu lewat migrasi maju baru dan pembaruan `backend/API_CONTRACT.md` |
| Frontend | UI, UX, komponen, halaman, state frontend, integrasi API | Hanya memakai field, RPC, status, dan error yang tercantum di kontrak API |

Walaupun dikerjakan oleh tool yang sama, kontrak API tetap menjadi batas antara backend dan frontend. Jika frontend butuh data atau perilaku baru, ubah backend dan kontraknya lebih dulu dalam perubahan terpisah yang dapat ditinjau.

## 3. Persyaratan fungsional teknis
- Login dan registrasi menggunakan Supabase Auth.
- Profil pengguna terhubung ke identitas Auth.
- Setiap pengguna memiliki satu peran operasional yang valid pada MVP.
- Data toko dan produk dapat dibaca pelanggan sesuai status publikasi/aktif.
- Pelanggan hanya dapat mengakses pesanan miliknya.
- Penjual hanya dapat mengakses toko dan pesanan yang menjadi kewenangannya.
- Driver hanya dapat mengakses tugas yang ditugaskan kepadanya.
- Admin memiliki akses administratif sesuai kebijakan RLS yang eksplisit.
- Perubahan status pesanan divalidasi di backend, bukan hanya disembunyikan di UI.

## 4. Persyaratan nonfungsional
- Mobile-first, responsif, dan nyaman digunakan pada lebar layar ponsel.
- Loading, empty, error, offline/connection-lost, dan success state tersedia.
- Validasi input dilakukan di frontend dan backend.
- Query daftar produk/pesanan menggunakan pagination saat data bertambah.
- Foto dioptimalkan ukurannya dan memiliki fallback.
- Secret/service-role key tidak pernah dikirim ke browser.
- Semua tabel yang berisi data pengguna/pesanan dilindungi RLS.
- Operasi penting memiliki timestamp `created_at` dan `updated_at`.
- Error yang ditampilkan ke pengguna tidak membocorkan detail internal database.

## 5. Keamanan
1. Aktifkan RLS untuk seluruh tabel yang dapat diakses dari client.
2. Gunakan anon/publishable key hanya sesuai pola resmi Supabase.
3. Service-role key hanya di lingkungan server/secret manager.
4. Jangan percaya `user_id`, `role`, harga, total, atau status yang dikirim client tanpa validasi.
5. Hitung ulang subtotal/total di sisi tepercaya.
6. Batasi perubahan status berdasarkan peran dan status sebelumnya.
7. Validasi tipe, panjang, rentang, dan format input.
8. Uji akses silang: pelanggan A tidak boleh membaca pesanan pelanggan B.

## 6. Status pesanan — usulan awal
Status konseptual:
`pending_seller` → `accepted` atau `rejected` → `preparing` → `ready_for_pickup` → `picked_up` → `delivered` → `completed`.

Status tambahan yang perlu aturan eksplisit: `cancelled` dan `payment_pending`/`payment_verified` untuk transfer manual. Nama enum final ditetapkan di migrasi backend dan dicerminkan persis pada frontend. Jangan implementasikan dua sistem status yang berbeda.

## 7. Integrasi frontend–backend
- API contract menjadi sumber kebenaran untuk nama field, tipe data, error, dan status.
- Frontend tidak boleh mengakses tabel secara bebas jika kontrak mengharuskan fungsi/RPC/endpoint terkontrol.
- Gunakan environment variables untuk URL dan public key.
- Buat file contoh environment tanpa secret nyata.
- Integrasi dilakukan setelah backend menyediakan schema/contract yang telah diverifikasi.

## 8. Testing minimum
- Auth: signup/login/logout dan sesi.
- RLS: akses sesuai peran dan penolakan akses silang.
- Produk: produk aktif tampil, produk nonaktif tidak bisa dipesan.
- Order: validasi item, harga, total, dan stok/ketersediaan.
- Status: transisi valid diterima, transisi ilegal ditolak.
- UI: ukuran mobile, form validation, loading/error/empty state.
- End-to-end: satu transaksi lengkap COD dan satu skenario transfer manual.

## 9. Deployment dan lingkungan
Pisahkan development/test dan production jika fasilitas/anggaran memungkinkan. Catat URL proyek, variabel lingkungan, migrasi, dan langkah deployment di dokumentasi internal. Mulai dengan tier gratis sesuai batas layanan yang berlaku; periksa kuota dan kebijakan terbaru sebelum peluncuran publik.

## 10. Keputusan teknis yang wajib dikonfirmasi
- Framework/build tool berdasarkan repository aktual.
- Mekanisme driver assignment.
- Perhitungan jarak dan biaya pengiriman.
- Implementasi transfer manual dan bukti pembayaran.
- Notifikasi: polling sederhana atau mekanisme Supabase Realtime; pilih setelah kebutuhan diuji.
- Kebijakan penyimpanan foto dan ukuran file.
