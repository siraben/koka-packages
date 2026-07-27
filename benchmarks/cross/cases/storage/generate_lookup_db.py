#!/usr/bin/env python3
from pathlib import Path
import os
import sqlite3
import sys
import tempfile

ROWS = 100_000


def valid_database(path: Path) -> bool:
    if not path.is_file():
        return False
    try:
        with sqlite3.connect(f"file:{path}?mode=ro", uri=True) as database:
            row = database.execute(
                "SELECT count(*), min(i), max(i) FROM bench"
            ).fetchone()
            return row == (ROWS, 0, ROWS - 1)
    except sqlite3.Error:
        return False


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_lookup_db.py PATH")
    target = Path(sys.argv[1])
    if valid_database(target):
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{target.name}.", dir=target.parent
    )
    os.close(descriptor)
    temporary = Path(temporary_name)
    try:
        database = sqlite3.connect(temporary)
        try:
            database.execute(
                "CREATE TABLE bench "
                "(i INTEGER PRIMARY KEY, text_value TEXT NOT NULL)"
            )
            database.executemany(
                "INSERT INTO bench (i, text_value) VALUES (?, ?)",
                ((i, f"row-{i}") for i in range(ROWS)),
            )
            database.commit()
        finally:
            database.close()
        os.replace(temporary, target)
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise


if __name__ == "__main__":
    main()
