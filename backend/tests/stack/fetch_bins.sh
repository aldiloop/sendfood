#!/usr/bin/env bash
# Mengunduh biner resmi PostgREST dan Supabase Auth (GoTrue) dari GitHub Releases ke .pgtools/svc
# (diabaikan git) dan memverifikasi SHA256 terhadap backend/tests/stack/VERSIONS. Hanya untuk stack lokal.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
V="$ROOT/backend/tests/stack/VERSIONS"
DEST="${STACK_BIN:-$ROOT/.pgtools/svc}"
mkdir -p "$DEST"
get() { # get <nama> <url> <sha256>
  local f="$DEST/$1"
  if [ ! -f "$f" ] || [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$3" ]; then
    curl -sSLf -o "$f.part" "$2"
    mv "$f.part" "$f"
  fi
  echo "$3  $f" | sha256sum -c - >/dev/null || { echo "SHA256 tidak cocok: $1" >&2; exit 1; }
}
read -r _ PGRST_VER PGRST_URL PGRST_SHA < <(grep '^postgrest ' "$V")
read -r _ AUTH_VER AUTH_URL AUTH_SHA < <(grep '^auth ' "$V")
get postgrest.tar.xz "$PGRST_URL" "$PGRST_SHA"
get auth.tar.xz "$AUTH_URL" "$AUTH_SHA"
tar -xJf "$DEST/postgrest.tar.xz" -C "$DEST"
tar -xJf "$DEST/auth.tar.xz" -C "$DEST"
"$DEST/postgrest" --version
echo "Supabase Auth $AUTH_VER siap di $DEST"
