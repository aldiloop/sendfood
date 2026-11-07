# Fungsi bersama: guard localhost dan lokasi biner Postgres.
# Di-source oleh script lain; jangan dijalankan langsung.

# Menolak host selain loopback atau path socket unix.
require_local_host() {
  local host="${1:-}"
  case "$host" in
    localhost|127.0.0.1|::1|/*) return 0 ;;
    *)
      echo "DITOLAK: host '$host' bukan localhost. Script ini destruktif dan hanya boleh ke Postgres lokal." >&2
      return 1 ;;
  esac
}

# Mencari direktori bin Postgres (initdb, postgres, psql).
find_pg_bin() {
  local root="$1" cand
  if [ -n "${PG_BIN:-}" ] && [ -x "$PG_BIN/psql" ]; then echo "$PG_BIN"; return 0; fi
  if command -v psql >/dev/null 2>&1 && command -v initdb >/dev/null 2>&1; then
    dirname "$(command -v psql)"; return 0
  fi
  for cand in "$root"/.pgtools/venv/lib/python*/site-packages/pgserver/pginstall/bin \
              /usr/lib/postgresql/*/bin; do
    if [ -x "$cand/psql" ] && [ -x "$cand/initdb" ]; then echo "$cand"; return 0; fi
  done
  return 1
}
