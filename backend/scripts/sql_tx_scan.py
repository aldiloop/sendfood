#!/usr/bin/env python3
"""Pemindai kontrol transaksi top-level untuk berkas migrasi SQL (dipakai apply_migration_local.sh).

Keluaran (stdout) satu kata lalu exit 0:
  wrap    -> tidak ada kontrol transaksi top-level; runner membungkus dengan --single-transaction
  own     -> tepat satu BEGIN sebagai statement pertama dan satu COMMIT sebagai statement terakhir,
             tanpa kontrol transaksi lain di antaranya
Ditolak (stderr, exit 65): kontrol transaksi lain (BEGIN/COMMIT ganda, END, ROLLBACK, SAVEPOINT, ...),
psql meta-command (\\...), `BEGIN ATOMIC` (body fungsi SQL-standar yang tidak bisa dipisah aman),
atau literal/komentar/dollar-quote yang tidak tertutup.

Komentar (-- dan /* */ bersarang), string '...' / E'...', identifier "..." dan dollar-quote $tag$...$tag$
dilewati, sehingga BEGIN/END di dalam body fungsi PL/pgSQL tidak salah dibaca.
"""
import re
import sys

TX_WORDS = {"begin", "start", "commit", "end", "rollback", "abort", "savepoint", "release", "prepare"}
DOLLAR = re.compile(r"\$([A-Za-z_][A-Za-z0-9_]*)?\$")


def fail(msg):
    sys.stderr.write(f"DITOLAK: {msg}\n")
    sys.exit(65)


def statements(sql):
    """Memecah teks menjadi statement top-level; isi literal/komentar diganti spasi."""
    out, buf, i, n = [], [], 0, len(sql)
    at_line_start = True
    while i < n:
        c = sql[i]
        if c == "-" and sql.startswith("--", i):
            j = sql.find("\n", i)
            i = n if j < 0 else j
            continue
        if c == "/" and sql.startswith("/*", i):
            depth, i = 1, i + 2
            while i < n and depth:
                if sql.startswith("/*", i):
                    depth, i = depth + 1, i + 2
                elif sql.startswith("*/", i):
                    depth, i = depth - 1, i + 2
                else:
                    i += 1
            if depth:
                fail("komentar /* tidak ditutup")
            buf.append(" ")
            continue
        if c == "'":
            # String standar ('' sebagai escape); E'...' juga mengenal backslash escape.
            escape = i > 0 and sql[i - 1] in "eE" and (i < 2 or not (sql[i - 2].isalnum() or sql[i - 2] == "_"))
            i += 1
            while True:
                if i >= n:
                    fail("string literal tidak ditutup")
                if escape and sql[i] == "\\":
                    i += 2
                    continue
                if sql[i] == "'":
                    if sql.startswith("''", i):
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            buf.append(" ''")
            continue
        if c == '"':
            j = i + 1
            while True:
                j = sql.find('"', j)
                if j < 0:
                    fail("identifier ber-kutip tidak ditutup")
                if sql.startswith('""', j):
                    j += 2
                    continue
                break
            i = j + 1
            buf.append(' "x"')
            continue
        if c == "$":
            m = DOLLAR.match(sql, i)
            prev = sql[i - 1] if i > 0 else " "
            if m and not (prev.isalnum() or prev == "_"):
                tag = m.group(0)
                j = sql.find(tag, m.end())
                if j < 0:
                    fail(f"dollar-quote {tag} tidak ditutup")
                i = j + len(tag)
                buf.append(" $$ ")
                continue
        if c == "\\" and at_line_start:
            fail("psql meta-command (\\...) tidak diizinkan dalam berkas migrasi")
        if c == ";":
            out.append("".join(buf))
            buf = []
            i += 1
            at_line_start = False
            continue
        if c == "\n":
            at_line_start = True
        elif not c.isspace():
            at_line_start = False
        buf.append(c)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        out.append(tail)
    return [s.strip() for s in out if s.strip()]


def main():
    if len(sys.argv) != 2:
        fail("pemakaian: sql_tx_scan.py <berkas.sql>")
    with open(sys.argv[1], encoding="utf-8") as fh:
        stmts = statements(fh.read())
    if not stmts:
        fail("berkas migrasi kosong")
    words = []
    for s in stmts:
        toks = re.findall(r"[A-Za-z_]+", s.lower())
        if re.search(r"\bbegin\s+atomic\b", s, re.I):
            fail("BEGIN ATOMIC tidak didukung runner; gunakan body fungsi dollar-quoted")
        words.append(toks[0] if toks else "")
    ctrl = [k for k, w in enumerate(words) if w in TX_WORDS]
    if not ctrl:
        print("wrap")
        return
    last = len(words) - 1
    if (ctrl == [0, last] and last > 0 and words[0] == "begin" and words[last] == "commit"
            and re.fullmatch(r"begin(\s+(transaction|work))?", stmts[0], re.I)
            and re.fullmatch(r"commit(\s+(transaction|work))?", stmts[last], re.I)):
        print("own")
        return
    detail = ", ".join(f"#{k + 1}:{words[k].upper()}" for k in ctrl)
    fail(f"kontrol transaksi top-level hanya boleh BEGIN pertama + COMMIT terakhir, ditemukan {detail}")


if __name__ == "__main__":
    main()
