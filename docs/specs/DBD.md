# DBD — Design Brief Documentation
## Send Food

**Versi:** 1.0 | **Tanggal:** 7 November 2026

## 1. Arah desain
Send Food harus terasa **modern, premium, sederhana, ramah, dan terpercaya**. Desain dibuat mobile-first karena PWA akan menjadi platform pertama. Hindari tampilan padat, dekorasi berlebihan, dan pola dashboard desktop yang dipaksakan ke layar ponsel.

## 2. Prinsip desain
- **Clarity first:** harga, status, biaya, dan aksi utama mudah dipahami.
- **Local and human:** foto makanan dan identitas penjual menjadi fokus.
- **Fast to use:** alur pesan singkat dan form tidak berlebihan.
- **Consistent:** komponen, jarak, tipografi, ikon, dan status konsisten.
- **Accessible:** kontras memadai, target sentuh nyaman, label form jelas.
- **Honest UI:** rating, stok, estimasi, dan status hanya menampilkan data nyata.

## 3. Pengguna dan kebutuhan antarmuka
### Pelanggan
Beranda yang mudah dipindai, kartu toko/produk, pencarian, filter/sort, keranjang yang selalu mudah ditemukan, checkout yang ringkas, dan status pesanan yang jelas.

### Penjual
Dashboard berisi pesanan baru dan tindakan prioritas. Produk dikelola lewat daftar yang mudah diedit. Informasi penjualan tidak boleh memenuhi layar jika belum diperlukan.

### Driver
Dashboard berorientasi tugas: alamat, ringkasan pesanan, tombol status yang besar, dan riwayat sederhana.

### Admin
Antarmuka operasional yang jelas untuk memeriksa pengguna, toko, produk, dan pesanan. Pada ponsel, tabel kompleks sebaiknya diubah menjadi daftar/kartu.

## 4. Struktur layar utama
- Beranda pelanggan: header, pencarian, kategori/shortcut bila dibutuhkan, rekomendasi/daftar toko, sort/filter.
- Daftar toko: kartu toko dengan foto, nama, jarak (jika tersedia), rating (jika ada data valid), dan biaya kirim.
- Detail toko: profil toko, jam/status buka, daftar menu.
- Detail produk: foto, nama, deskripsi, harga, jumlah, catatan.
- Keranjang: item, kuantitas, subtotal, biaya kirim, total.
- Checkout: alamat, catatan, metode pembayaran, ringkasan.
- Status pesanan: timeline/status, ringkasan, informasi driver bila telah ditugaskan.
- Dashboard penjual: pesanan masuk, proses, siap diambil, produk.
- Dashboard driver: tugas aktif, detail alamat, aksi update status.
- Admin: ringkasan dan daftar operasional.

## 5. Filter dan pengurutan
Filter/sort yang diminta:
- Terdekat
- Terjauh
- Termurah (berdasarkan harga produk atau nilai minimum yang dijelaskan)
- Termahal
- Rating tertinggi (hanya bila rating tersedia dan valid)
- Biaya pengiriman terendah/tertinggi

Pisahkan filter dari kategori produk. Jangan menampilkan kontrol yang tidak didukung data. Jarak membutuhkan lokasi/alamat dan metode perhitungan yang disepakati.

## 6. Sistem visual
- Gunakan satu warna utama yang kuat dan palet netral untuk menjaga kesan premium.
- Gunakan warna semantik secara konsisten: sukses, peringatan, error, dan informasi.
- Tipografi sans-serif yang mudah dibaca; hierarki heading/body/label jelas.
- Radius kartu dan tombol konsisten; bayangan tipis dan tidak berlebihan.
- Foto makanan berkualitas dengan rasio konsisten dan placeholder saat kosong.
- Ikon harus familiar dan tidak menggantikan label untuk aksi penting.

Warna final, font, dan token desain ditetapkan setelah eksplorasi visual dan disimpan sebagai design tokens; dokumen ini tidak mengunci kode warna sebelum mockup disetujui.

## 7. Komponen UI minimum
Button (primary/secondary/destructive), input, select, search, filter/sort sheet, product card, store card, quantity stepper, price summary, status badge, order timeline, empty state, skeleton/loading, error message, confirmation dialog, bottom navigation, dashboard summary card.

## 8. Responsif dan aksesibilitas
- Desain utama pada viewport ponsel; tablet/desktop mengikuti dengan layout adaptif.
- Target sentuh cukup besar dan memiliki jarak.
- Kontras teks dan latar memenuhi praktik aksesibilitas yang baik.
- Jangan mengandalkan warna saja untuk menunjukkan status.
- Semua input memiliki label dan pesan validasi.
- Gambar memiliki teks alternatif yang relevan.

## 9. Batasan desain
- Jangan menambahkan fitur visual yang belum didukung backend.
- Jangan membuat data demo terlihat seperti transaksi/rating nyata.
- Jangan membuat dashboard penuh grafik sebelum data analitik tersedia.
- Jangan mengubah schema backend hanya untuk menyesuaikan desain. Jika desain butuh data baru, buat migrasi maju dan perbarui kontrak API lebih dulu.
