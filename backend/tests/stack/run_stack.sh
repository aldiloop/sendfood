#!/usr/bin/env bash
# Stack lokal sekali pakai dengan layanan ASLI: PostgreSQL + Supabase Auth (GoTrue) + PostgREST
# lalu tes HTTP (backend/tests/http/*.test.mjs).
#
# Semua layanan bind ke 127.0.0.1 pada port acak; database bernama sendfood_stack_*; secret JWT dan
# password peran dibuat acak per run dan tidak pernah dicetak. Di akhir semua proses dan direktori kerja
# yang dibuat script ini dihentikan/dihapus. Tidak ada koneksi ke Supabase cloud.
#
# Biner (versi dan SHA256 dicatat di backend/tests/stack/VERSIONS):
#   PG_BIN     : direktori bin Postgres (default: cari seperti run.sh)
#   STACK_BIN  : direktori berisi `postgrest`, `auth` dan `migrations/` GoTrue (default .pgtools/svc)
# Ambil biner: bash backend/tests/stack/fetch_bins.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
HERE="$ROOT/backend/tests"
# shellcheck source=../harness/lib.sh
. "$HERE/harness/lib.sh"

PG_BIN_DIR="$(find_pg_bin "$ROOT")" || { echo "Postgres tidak ditemukan (set PG_BIN)." >&2; exit 2; }
STACK_BIN="${STACK_BIN:-$ROOT/.pgtools/svc}"
for b in postgrest auth; do
  [ -x "$STACK_BIN/$b" ] || { echo "Biner $b tidak ada di $STACK_BIN. Jalankan backend/tests/stack/fetch_bins.sh" >&2; exit 2; }
done
[ -d "$STACK_BIN/migrations" ] || { echo "Migrasi GoTrue tidak ada di $STACK_BIN/migrations" >&2; exit 2; }
command -v node >/dev/null || { echo "node tidak ada" >&2; exit 2; }

WORK="$(mktemp -d /tmp/sendfood_stack.XXXXXX)"
DBNAME="sendfood_stack_$(date +%s)_$$"
PIDS=()
PG_STARTED=0
RUN_PREFIX=()
if [ "$(id -u)" = 0 ]; then
  chown 65534:65534 "$WORK"
  RUN_PREFIX=(setpriv --reuid=65534 --regid=65534 --clear-groups)
fi

cleanup() {
  local rc=$?
  for p in "${PIDS[@]}"; do kill "$p" >/dev/null 2>&1 || true; done
  sleep 0.3
  for p in "${PIDS[@]}"; do kill -9 "$p" >/dev/null 2>&1 || true; done
  if [ "$PG_STARTED" = 1 ]; then
    "${RUN_PREFIX[@]}" "$PG_BIN_DIR/pg_ctl" -D "$WORK/data" -m immediate stop >/dev/null 2>&1 || true
  fi
  if [ -n "${SF_STACK_KEEP_LOGS:-}" ]; then
    mkdir -p "$SF_STACK_KEEP_LOGS"
    # Log layanan tidak memuat secret (secret hanya di env proses), tetapi tetap disaring.
    for f in "$WORK"/*.log; do
      [ -f "$f" ] && sed -E 's/(eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,})/<JWT-REDACTED>/g' "$f" \
        > "$SF_STACK_KEEP_LOGS/$(basename "$f")"
    done
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap cleanup EXIT INT TERM

free_port() { python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()'; }
rand_hex() { python3 -c "import secrets;print(secrets.token_hex($1))"; }
wait_http() { # wait_http <url> <detik> <nama>
  local i
  for i in $(seq 1 $(( $2 * 5 ))); do
    curl -sf -o /dev/null -m 1 "$1" && return 0
    sleep 0.2
  done
  echo "GAGAL: $3 tidak siap ($1)" >&2; return 1
}

PG_PORT="$(free_port)"; AUTH_PORT="$(free_port)"; REST_PORT="$(free_port)"; REST_ADMIN_PORT="$(free_port)"
JWT_SECRET="$(rand_hex 32)"
AUTHENTICATOR_PW="$(rand_hex 16)"; AUTH_ADMIN_PW="$(rand_hex 16)"

# ---- PostgreSQL (TCP hanya 127.0.0.1; socket lokal trust untuk superuser harness) ----
"${RUN_PREFIX[@]}" "$PG_BIN_DIR/initdb" -D "$WORK/data" -U postgres --auth-local=trust --auth-host=scram-sha-256 \
  --no-sync >"$WORK/initdb.log" 2>&1 || { cat "$WORK/initdb.log" >&2; exit 2; }
"${RUN_PREFIX[@]}" "$PG_BIN_DIR/pg_ctl" -D "$WORK/data" -w -l "$WORK/postgres.log" \
  -o "-c listen_addresses=127.0.0.1 -c port=$PG_PORT -c unix_socket_directories='$WORK' -c fsync=off -c max_connections=120" \
  start >/dev/null || { cat "$WORK/postgres.log" >&2; exit 2; }
PG_STARTED=1
export PGHOST="$WORK" PGPORT="$PG_PORT" PGUSER=postgres
require_local_host "$PGHOST" || exit 3
PSQL=("$PG_BIN_DIR/psql" -X -q -v ON_ERROR_STOP=1)
"${PSQL[@]}" -d postgres -c "create database \"$DBNAME\"" || exit 2
export PGDATABASE="$DBNAME"
PG_VERSION="$("${PSQL[@]}" -At -c 'show server_version')"

"${PSQL[@]}" -v authenticator_pw="$AUTHENTICATOR_PW" -v auth_admin_pw="$AUTH_ADMIN_PW" \
  -f "$HERE/stack/bootstrap.sql" >/dev/null || { echo "GAGAL: bootstrap"; exit 1; }

# ---- Supabase Auth (GoTrue) asli: menjalankan migrasinya sendiri ke schema auth ----
AUTH_VERSION="$(cat "$HERE/stack/VERSIONS" 2>/dev/null | awk '/^auth /{print $2}')"
auth_env() {
  env -i PATH=/usr/bin:/bin \
    GOTRUE_DB_DRIVER=postgres \
    DATABASE_URL="postgres://supabase_auth_admin:$AUTH_ADMIN_PW@127.0.0.1:$PG_PORT/$DBNAME?sslmode=disable&search_path=auth" \
    GOTRUE_DB_MIGRATIONS_PATH="$STACK_BIN/migrations" \
    GOTRUE_API_HOST=127.0.0.1 PORT="$AUTH_PORT" \
    API_EXTERNAL_URL="http://127.0.0.1:$AUTH_PORT" GOTRUE_SITE_URL="http://127.0.0.1:3000" \
    GOTRUE_JWT_SECRET="$JWT_SECRET" GOTRUE_JWT_EXP=3600 GOTRUE_JWT_AUD=authenticated \
    GOTRUE_JWT_ADMIN_ROLES=service_role GOTRUE_JWT_DEFAULT_GROUP_NAME=authenticated \
    GOTRUE_DISABLE_SIGNUP=false GOTRUE_EXTERNAL_EMAIL_ENABLED=true GOTRUE_MAILER_AUTOCONFIRM=true \
    GOTRUE_EXTERNAL_PHONE_ENABLED=false GOTRUE_PASSWORD_MIN_LENGTH=8 \
    GOTRUE_SECURITY_REFRESH_TOKEN_ROTATION_ENABLED=true GOTRUE_SECURITY_REFRESH_TOKEN_REUSE_INTERVAL=0 \
    GOTRUE_RATE_LIMIT_TOKEN_REFRESH=100000 GOTRUE_RATE_LIMIT_VERIFY=100000 GOTRUE_RATE_LIMIT_EMAIL_SENT=100000 \
    GOTRUE_LOG_LEVEL=info \
    "${RUN_PREFIX[@]}" "$STACK_BIN/auth" "$@"
}
( cd "$STACK_BIN" && auth_env migrate ) >"$WORK/auth-migrate.log" 2>&1 \
  || { echo "GAGAL: migrasi GoTrue"; tail -20 "$WORK/auth-migrate.log" >&2; exit 2; }
( cd "$STACK_BIN" && auth_env serve ) >"$WORK/auth.log" 2>&1 &
PIDS+=($!)
wait_http "http://127.0.0.1:$AUTH_PORT/health" 60 "GoTrue" || { tail -40 "$WORK/auth.log" >&2; exit 2; }

# ---- Migrasi aplikasi: lewat runner transaksional yang sama dengan runbook ----
for f in "$ROOT"/backend/migrations/*.sql; do
  echo "== Migrasi: $(basename "$f")"
  SENDFOOD_MIGRATION_ALLOW_DB_PREFIX=sendfood_stack_ bash "$ROOT/backend/scripts/apply_migration_local.sh" "$f" \
    || { echo "GAGAL: migrasi $(basename "$f")"; exit 1; }
done
"${PSQL[@]}" -At -c "select tgname from pg_trigger where tgrelid = 'auth.users'::regclass and tgname = 'on_auth_user_created'" \
  | grep -q on_auth_user_created || { echo "GAGAL: trigger on_auth_user_created tidak terpasang di auth.users GoTrue"; exit 1; }

# ---- PostgREST asli ----
(
  env -i PATH=/usr/bin:/bin \
    PGRST_DB_URI="postgres://authenticator:$AUTHENTICATOR_PW@127.0.0.1:$PG_PORT/$DBNAME?sslmode=disable" \
    PGRST_DB_SCHEMAS=public PGRST_DB_ANON_ROLE=anon PGRST_JWT_SECRET="$JWT_SECRET" \
    PGRST_SERVER_HOST=127.0.0.1 PGRST_SERVER_PORT="$REST_PORT" \
    PGRST_ADMIN_SERVER_HOST=127.0.0.1 PGRST_ADMIN_SERVER_PORT="$REST_ADMIN_PORT" \
    PGRST_DB_POOL=20 PGRST_DB_MAX_ROWS=1000 PGRST_DB_EXTRA_SEARCH_PATH=public,extensions PGRST_LOG_LEVEL=info \
    "${RUN_PREFIX[@]}" "$STACK_BIN/postgrest"
) >"$WORK/postgrest.log" 2>&1 &
PIDS+=($!)
wait_http "http://127.0.0.1:$REST_ADMIN_PORT/ready" 60 "PostgREST" || { tail -40 "$WORK/postgrest.log" >&2; exit 2; }
curl -sf -o /dev/null "http://127.0.0.1:$REST_ADMIN_PORT/ready" || { tail -40 "$WORK/postgrest.log" >&2; exit 2; }

echo "== Stack lokal: PostgreSQL $PG_VERSION | $("$STACK_BIN/postgrest" --version 2>/dev/null | head -1) | Supabase Auth ${AUTH_VERSION:-?} | Supabase Storage: tidak dijalankan (lihat README)"
echo "== db: $DBNAME (127.0.0.1 port acak, dihapus di akhir)"

export SF_AUTH_URL="http://127.0.0.1:$AUTH_PORT" SF_REST_URL="http://127.0.0.1:$REST_PORT"
export SF_JWT_SECRET="$JWT_SECRET" SF_PSQL="$PG_BIN_DIR/psql" SF_DB="$DBNAME"
export SF_ANON_KEY="$(node "$HERE/http/lib/jwt_cli.mjs" "$JWT_SECRET" anon)"
export SF_SERVICE_KEY="$(node "$HERE/http/lib/jwt_cli.mjs" "$JWT_SECRET" service_role)"

set +e
node --test --test-concurrency=1 --test-reporter=spec ${SF_HTTP_TESTS:-"$HERE"/http/*.test.mjs} 2>&1 \
  | sed -E "s/eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*/<JWT>/g" | tee "$WORK/http-tests.out"
rc=${PIPESTATUS[0]}
set -e
pass=$(grep -E '^ℹ pass ' "$WORK/http-tests.out" | awk '{print $3}')
fail=$(grep -E '^ℹ fail ' "$WORK/http-tests.out" | awk '{print $3}')
skip=$(grep -E '^ℹ skipped ' "$WORK/http-tests.out" | awk '{print $3}')
todo=$(grep -E '^ℹ todo ' "$WORK/http-tests.out" | awk '{print $3}')
echo "== Ringkasan HTTP stack: lulus=${pass:-0} gagal=${fail:-0} dilewati=${skip:-0} todo=${todo:-0} exit=$rc"
if [ "$rc" -ne 0 ]; then
  echo "-- tail postgrest.log"; tail -15 "$WORK/postgrest.log"
  echo "-- tail auth.log"; tail -15 "$WORK/auth.log" | cut -c1-400
fi
exit "$rc"
