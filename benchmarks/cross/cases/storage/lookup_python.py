#!/usr/bin/env python3
import sqlite3
import sys

FIXTURE_ROWS = 100_000


def arguments() -> tuple[int, str]:
    if len(sys.argv) != 3:
        raise SystemExit("usage: lookup_python.py LOOKUPS DATABASE")
    lookups = int(sys.argv[1])
    if lookups <= 0:
        raise SystemExit("lookup count must be positive")
    return lookups, sys.argv[2]


def main() -> None:
    lookups, path = arguments()
    database = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    try:
        cursor = database.cursor()
        sum_i = 0
        text_bytes = 0
        for n in range(lookups):
            key = (n * 48_271) % FIXTURE_ROWS
            row = cursor.execute(
                "SELECT i, text_value FROM bench WHERE i = ?", (key,)
            ).fetchone()
            if row is None:
                raise RuntimeError(f"indexed lookup missed key {key}")
            found, text = row
            sum_i += found
            text_bytes += len(text.encode("utf-8"))
        print(
            f"lookups={lookups} sum_i={sum_i} text_bytes={text_bytes}"
        )
    finally:
        database.close()


if __name__ == "__main__":
    main()
