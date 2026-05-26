#!/usr/bin/env python3
"""
bizzymod-stats migration runner.

Discovers numbered .sql files under schema/migrations/mysql/ and applies any
that have not yet been recorded in the `schema_migrations` table.

Usage:
    python migrate.py --host HOST --user USER --password PASS --database DB \
        [--migrations DIR] [--dry-run]

Or via environment variables:
    BIZZY_DB_HOST, BIZZY_DB_PORT, BIZZY_DB_USER, BIZZY_DB_PASSWORD, BIZZY_DB_NAME

The runner is intentionally minimal: no rollback, no down-migrations.
Forward-only migrations match how SourceMod plugins evolve.
"""

from __future__ import annotations

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path

try:
    import pymysql
except ImportError:
    sys.stderr.write(
        "error: pymysql not installed. Run: pip install pymysql\n"
    )
    sys.exit(2)


VERSION_RE = re.compile(r"^(\d{3,})_.*\.sql$")


def discover_migrations(directory: Path) -> list[tuple[str, Path]]:
    items: list[tuple[str, Path]] = []
    for entry in sorted(directory.iterdir()):
        if not entry.is_file():
            continue
        m = VERSION_RE.match(entry.name)
        if not m:
            continue
        items.append((m.group(1), entry))
    return items


def checksum(path: Path) -> str:
    h = hashlib.sha256()
    h.update(path.read_bytes())
    return h.hexdigest()


def ensure_migrations_table(cur) -> None:
    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS `schema_migrations` (
            `version`    VARCHAR(64) NOT NULL,
            `applied_at` DATETIME    NOT NULL DEFAULT CURRENT_TIMESTAMP,
            `checksum`   CHAR(64)    NOT NULL,
            PRIMARY KEY (`version`)
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci
        """
    )


def applied_versions(cur) -> dict[str, str]:
    cur.execute("SELECT `version`, `checksum` FROM `schema_migrations`")
    return {row[0]: row[1] for row in cur.fetchall()}


def split_statements(sql: str) -> list[str]:
    """Naive SQL statement splitter.

    Splits on top-level semicolons. Good enough for our migrations (no
    stored procedures, no DELIMITER directives).
    """
    out: list[str] = []
    buf: list[str] = []
    in_single = False
    in_double = False
    in_backtick = False
    in_line_comment = False
    in_block_comment = False
    i = 0
    while i < len(sql):
        c = sql[i]
        nxt = sql[i + 1] if i + 1 < len(sql) else ""
        if in_line_comment:
            if c == "\n":
                in_line_comment = False
            buf.append(c)
            i += 1
            continue
        if in_block_comment:
            if c == "*" and nxt == "/":
                in_block_comment = False
                buf.append("*/")
                i += 2
                continue
            buf.append(c)
            i += 1
            continue
        if not (in_single or in_double or in_backtick):
            if c == "-" and nxt == "-":
                in_line_comment = True
                buf.append("--")
                i += 2
                continue
            if c == "/" and nxt == "*":
                in_block_comment = True
                buf.append("/*")
                i += 2
                continue
        if c == "\\" and (in_single or in_double):
            buf.append(c)
            if nxt:
                buf.append(nxt)
                i += 2
                continue
        if c == "'" and not (in_double or in_backtick):
            in_single = not in_single
        elif c == '"' and not (in_single or in_backtick):
            in_double = not in_double
        elif c == "`" and not (in_single or in_double):
            in_backtick = not in_backtick
        if c == ";" and not (in_single or in_double or in_backtick):
            stmt = "".join(buf).strip()
            if stmt:
                out.append(stmt)
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    tail = "".join(buf).strip()
    if tail:
        out.append(tail)
    return out


def apply_migration(cur, version: str, path: Path, checksum_hex: str) -> None:
    sql = path.read_text(encoding="utf-8")
    for stmt in split_statements(sql):
        cur.execute(stmt)
    cur.execute(
        "INSERT INTO `schema_migrations` (`version`, `checksum`) VALUES (%s, %s)",
        (version, checksum_hex),
    )


def main() -> int:
    parser = argparse.ArgumentParser(description="Apply bizzymod-stats migrations")
    parser.add_argument("--host", default=os.environ.get("BIZZY_DB_HOST", "127.0.0.1"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("BIZZY_DB_PORT", "3306")))
    parser.add_argument("--user", default=os.environ.get("BIZZY_DB_USER", "root"))
    parser.add_argument("--password", default=os.environ.get("BIZZY_DB_PASSWORD", ""))
    parser.add_argument("--database", default=os.environ.get("BIZZY_DB_NAME", "bizzymod_stats"))
    parser.add_argument(
        "--migrations",
        default=str(Path(__file__).resolve().parent.parent / "migrations" / "mysql"),
    )
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    mig_dir = Path(args.migrations)
    if not mig_dir.is_dir():
        sys.stderr.write(f"error: migrations dir not found: {mig_dir}\n")
        return 1

    discovered = discover_migrations(mig_dir)
    if not discovered:
        print(f"No migrations found under {mig_dir}")
        return 0

    print(f"Connecting to mysql://{args.user}@{args.host}:{args.port}/{args.database}")
    conn = pymysql.connect(
        host=args.host,
        port=args.port,
        user=args.user,
        password=args.password,
        database=args.database,
        charset="utf8mb4",
        autocommit=False,
    )
    try:
        with conn.cursor() as cur:
            ensure_migrations_table(cur)
            conn.commit()
            applied = applied_versions(cur)

        pending = [
            (version, path)
            for version, path in discovered
            if version not in applied
        ]
        if not pending:
            print("Database is up to date.")
            return 0

        print(f"Pending migrations: {len(pending)}")
        for version, path in pending:
            csum = checksum(path)
            print(f"  -> {version} ({path.name})  sha256={csum[:12]}")
            if args.dry_run:
                continue
            with conn.cursor() as cur:
                apply_migration(cur, version, path, csum)
            conn.commit()
            print(f"     applied.")

        # Warn on drift: previously-applied files whose checksum changed.
        for version, path in discovered:
            if version in applied and applied[version] != checksum(path):
                sys.stderr.write(
                    f"warning: migration {version} has been modified since apply "
                    f"(stored checksum != current). This is not corrected.\n"
                )
    finally:
        conn.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
