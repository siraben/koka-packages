#!/usr/bin/env python3
import sqlite3
import sys


def positive_work() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: sqlite_python.py ROWS")
    rows = int(sys.argv[1])
    if rows <= 0:
        raise SystemExit("row count must be positive")
    return rows


def parameters(rows: int):
    for i in range(rows):
        yield i, f"row-{i}"


def main() -> None:
    rows = positive_work()
    db = sqlite3.connect(":memory:", isolation_level=None)
    try:
        db.execute(
            "CREATE TABLE bench (i INTEGER NOT NULL, text_value TEXT NOT NULL)"
        )
        cursor = db.cursor()
        db.execute("BEGIN IMMEDIATE")
        try:
            cursor.executemany(
                "INSERT INTO bench (i, text_value) VALUES (?, ?)",
                parameters(rows),
            )
            db.execute("COMMIT")
        except BaseException:
            db.execute("ROLLBACK")
            raise
        count, sum_i, text_bytes = db.execute(
            "SELECT count(*), sum(i), "
            "sum(length(CAST(text_value AS BLOB))) FROM bench"
        ).fetchone()
        print(f"rows={count} sum_i={sum_i} text_bytes={text_bytes}")
    finally:
        db.close()


if __name__ == "__main__":
    main()
