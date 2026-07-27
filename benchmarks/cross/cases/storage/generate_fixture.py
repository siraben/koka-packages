#!/usr/bin/env python3
from pathlib import Path
import os
import sys
import tempfile

SIZE = 64 * 1024 * 1024
BLOCK = bytes(range(256)) * 256  # exactly 64 KiB


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: generate_fixture.py PATH")
    target = Path(sys.argv[1])
    if target.is_file() and target.stat().st_size == SIZE:
        return

    target.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(
        prefix=f".{target.name}.", dir=target.parent
    )
    try:
        with os.fdopen(descriptor, "wb", buffering=len(BLOCK)) as output:
            for _ in range(SIZE // len(BLOCK)):
                output.write(BLOCK)
        os.replace(temporary, target)
    except BaseException:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass
        raise


if __name__ == "__main__":
    main()
