# Desain UI/UX SendFood (usulan)

`sendfood-luna-mockup.html` adalah mockup statis untuk ditinjau. File ini bukan kode aplikasi dan tidak mengunci framework frontend. Buka langsung di browser.

Status: **usulan, belum disetujui**. Sesuai [DBD §6](../specs/DBD.md), warna dan token baru final setelah mockup disetujui pemilik UI/frontend.

## Palet

Luna Color Palette:

| Token | Hex | Pemakaian |
|---|---|---|
| `luna-100` | `#A7EBF2` | Latar highlight, badge, item navigasi aktif |
| `luna-300` | `#54ACBF` | Focus ring, dekoratif |
| `luna-500` | `#26658C` | Warna utama: tombol primary, tautan, harga |
| `luna-700` | `#023859` | Header, chip terpilih |
| `luna-900` | `#011C40` | Teks utama, bar keranjang |

`#A7EBF2` dan `#54ACBF` kontrasnya rendah di atas putih, jadi tidak dipakai untuk teks kecil. Warna semantik (sukses, peringatan, error, informasi) ditambahkan di luar palet dan selalu disertai ikon serta label teks.

## Layar

- **Pelanggan:** beranda dan daftar toko, sheet urutkan, detail toko, checkout, status pesanan, konfirmasi penerimaan, riwayat, login.
- **State:** loading, empty, error checkout, offline dan success.
- **Penjual:** dashboard pesanan masuk, konfirmasi tolak dengan alasan, detail pesanan, kelola ketersediaan produk.
- **Driver:** tugas aktif, detail pengantaran.
- **Admin:** ringkasan, tugaskan driver, daftar pengguna.

## Batasan yang diikuti

Mengacu pada [PRD](../specs/PRD.md), [AFD](../specs/AFD.md), [DBD](../specs/DBD.md), dan [kontrak API](../../backend/API_CONTRACT.md):

- Checkout hanya COD. Transfer manual tidak ditampilkan.
- Tidak ada tombol batal pesanan sampai kebijakan pembatalan ditetapkan.
- Status dan transisi memakai enum `order_status` backend.
- Assignment driver hanya oleh admin.
- Tidak ada rating, voucher, dompet, chat, GPS real-time, estimasi waktu, jam buka, atau kategori menu, karena di luar MVP atau datanya belum ada.
- Semua nama, harga, kode pesanan, dan jarak adalah data contoh dan diberi label "DATA CONTOH".

## Yang perlu dikonfirmasi

- Apakah pelanggan boleh melihat nama/kontak driver. RLS saat ini membatasi pelanggan ke profilnya sendiri.
- Teks pemetaan error RPC ke pesan pengguna.
