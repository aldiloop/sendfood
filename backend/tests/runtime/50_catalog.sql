-- Katalog: list_stores dan search_products (filter, urutan, validasi parameter, visibilitas).
\set ON_ERROR_STOP on
begin;

do $$
declare a text[]; n int;
begin
  perform t.login(null, 'anon');

  -- list_stores
  select array_agg(name order by ord) into a from (select name, row_number() over () ord from public.list_stores()) x;
  perform t.ok('list_stores: anon hanya melihat toko aktif, urut nama (3)',
    a = array['Kedai Belum Setting', 'Toko B', 'Warung A']);
  select array_agg(name order by ord) into a from (select name, row_number() over () ord from public.list_stores(null, -6.2, 106.8, 'nearest')) x;
  perform t.ok('list_stores: nearest dari titik toko A', a = array['Warung A', 'Toko B', 'Kedai Belum Setting']);
  select array_agg(name order by ord) into a from (select name, row_number() over () ord from public.list_stores(null, -6.2, 106.8, 'farthest')) x;
  perform t.ok('list_stores: farthest', a = array['Kedai Belum Setting', 'Toko B', 'Warung A']);
  select array_agg(name order by ord) into a from (select name, row_number() over () ord from public.list_stores(null, null, null, 'delivery_fee')) x;
  perform t.ok('list_stores: delivery_fee termurah dulu, belum dikonfigurasi terakhir', a = array['Warung A', 'Toko B', 'Kedai Belum Setting']);
  perform t.ok('list_stores: pencarian nama (case-insensitive)', (select count(*) from public.list_stores('WARUNG')) = 1);
  perform t.ok('list_stores: tanda % dalam query dianggap literal (0 hasil)', (select count(*) from public.list_stores('%')) = 0);
  perform t.ok('list_stores: tanda _ dalam query dianggap literal (0 hasil)', (select count(*) from public.list_stores('W_rung')) = 0);
  perform t.ok('list_stores: pagination limit 1 offset 1', (select name from public.list_stores(null, null, null, 'name', 1, 1)) = 'Toko B');
  perform t.ok('list_stores: within_service_radius benar untuk titik dalam radius toko A',
    (select within_service_radius from public.list_stores('Warung', -6.21, 106.81)) is true);
  perform t.ok('list_stores: within_service_radius salah untuk titik jauh',
    (select within_service_radius from public.list_stores('Warung', -6.5, 107.2)) is false);
  perform t.ok('list_stores: toko belum dikonfigurasi -> within_service_radius null',
    (select within_service_radius from public.list_stores('Kedai', -6.21, 106.81)) is null);
  perform t.ok('list_stores: tidak membocorkan toko nonaktif', not exists (select 1 from public.list_stores() where name = 'Toko Nonaktif'));

  perform t.expect_err('list_stores: sort tidak valid', $q$select * from public.list_stores(null, null, null, 'bogus')$q$, 'invalid_sort');
  perform t.expect_err('list_stores: sort injeksi ditolak', $q$select * from public.list_stores(null, null, null, 'name; drop table x')$q$, 'invalid_sort');
  perform t.expect_err('list_stores: sort cheapest tidak berlaku untuk toko', $q$select * from public.list_stores(null, null, null, 'cheapest')$q$, 'invalid_sort');
  perform t.expect_err('list_stores: limit 0', $q$select * from public.list_stores(null, null, null, 'name', 0, 0)$q$, 'invalid_pagination');
  perform t.expect_err('list_stores: limit 101', $q$select * from public.list_stores(null, null, null, 'name', 101, 0)$q$, 'invalid_pagination');
  perform t.expect_err('list_stores: offset negatif', $q$select * from public.list_stores(null, null, null, 'name', 10, -1)$q$, 'invalid_pagination');
  perform t.expect_err('list_stores: nearest tanpa lokasi', $q$select * from public.list_stores(null, null, null, 'nearest')$q$, 'location_required_for_sort');
  perform t.expect_err('list_stores: hanya lat', $q$select * from public.list_stores(null, -6.2, null)$q$, 'valid_coordinates_required');
  perform t.expect_err('list_stores: lat di luar rentang', $q$select * from public.list_stores(null, 91, 106.8)$q$, 'valid_coordinates_required');
  perform t.expect_err('list_stores: query > 100 karakter', format('select * from public.list_stores(%L)', repeat('x', 101)), 'search_query_too_long');

  -- search_products
  perform t.ok('search_products: anon melihat 4 produk tersedia di toko aktif', (select count(*) from public.search_products()) = 4);
  perform t.ok('search_products: tidak membocorkan produk tidak tersedia / toko nonaktif',
    not exists (select 1 from public.search_products() where name in ('Sate Habis', 'Mie Toko Nonaktif')));
  perform t.ok('search_products: query "nasi" -> 2 produk', (select count(*) from public.search_products('nasi')) = 2);
  perform t.ok('search_products: query cocok nama toko ("Kedai")', (select name from public.search_products('kedai')) = 'Bakso Belum Setting');
  select array_agg(name order by ord) into a from (select name, row_number() over () ord from public.search_products('nasi', null, null, null, null, null, 'cheapest')) x;
  perform t.ok('search_products: cheapest', a = array['Nasi Goreng A', 'Nasi Uduk B']);
  select array_agg(name order by ord) into a from (select name, row_number() over () ord from public.search_products('nasi', null, null, null, null, null, 'priciest')) x;
  perform t.ok('search_products: priciest', a = array['Nasi Uduk B', 'Nasi Goreng A']);
  select array_agg(name order by ord) into a from (select name, row_number() over () ord from public.search_products(null, null, null, null, -6.22, 106.82, 'nearest')) x;
  perform t.ok('search_products: nearest dari titik toko B (toko B pertama)', a[1] = 'Nasi Uduk B');
  perform t.ok('search_products: filter toko', (select count(*) from public.search_products(null, '50000000-0000-0000-0000-00000000000a')) = 2);
  perform t.ok('search_products: filter harga min', (select count(*) from public.search_products(null, null, 10000)) = 2);
  perform t.ok('search_products: filter harga max', (select count(*) from public.search_products(null, null, null, 9000)) = 2);
  perform t.ok('search_products: filter rentang harga', (select name from public.search_products(null, null, 11000, 13000)) = 'Nasi Uduk B');
  select array_agg(name order by ord) into a from (select name, row_number() over () ord from public.search_products(null, null, null, null, null, null, 'delivery_fee')) x;
  perform t.ok('search_products: delivery_fee, toko A (5000) sebelum toko B (7000) dan belum dikonfigurasi terakhir',
    a[1] in ('Nasi Goreng A', 'Teh Manis A') and a[4] = 'Bakso Belum Setting');
  perform t.ok('search_products: % literal (0 hasil)', (select count(*) from public.search_products('%')) = 0);
  perform t.ok('search_products: within_service_radius dihitung', (select within_service_radius from public.search_products('goreng', null, null, null, -6.21, 106.81)) is true);

  perform t.expect_err('search_products: sort tidak valid', $q$select * from public.search_products(null, null, null, null, null, null, 'bogus')$q$, 'invalid_sort');
  perform t.expect_err('search_products: min > max', $q$select * from public.search_products(null, null, 5, 1)$q$, 'invalid_price_range');
  perform t.expect_err('search_products: harga negatif', $q$select * from public.search_products(null, null, -1, null)$q$, 'invalid_price_range');
  perform t.expect_err('search_products: limit 0', $q$select * from public.search_products(null, null, null, null, null, null, 'name', 0, 0)$q$, 'invalid_pagination');
  perform t.expect_err('search_products: nearest tanpa lokasi', $q$select * from public.search_products(null, null, null, null, null, null, 'nearest')$q$, 'location_required_for_sort');
  perform t.expect_err('search_products: lon di luar rentang', $q$select * from public.search_products(null, null, null, null, -6.2, 181)$q$, 'valid_coordinates_required');
  perform t.logout();

  -- Pemilik tetap melihat produk tidak tersedia miliknya lewat tabel (bukan lewat katalog publik)
  perform t.login('20000000-0000-0000-0000-00000000000a');
  perform t.ok('katalog: seller A melihat produk tidak tersedia miliknya di tabel', exists (select 1 from public.products where name = 'Sate Habis'));
  perform t.ok('katalog: search_products tetap hanya produk tersedia untuk seller A', not exists (select 1 from public.search_products() where name = 'Sate Habis'));
  perform t.login('20000000-0000-0000-0000-00000000000b');
  perform t.ok('katalog: seller B tidak melihat produk tidak tersedia seller A', not exists (select 1 from public.products where name = 'Sate Habis'));
  perform t.logout();
end $$;

rollback;
