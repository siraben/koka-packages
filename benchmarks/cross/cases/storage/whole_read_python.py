#!/usr/bin/env python3
from pathlib import Path
import sys


def arguments() -> tuple[int, Path]:
    if len(sys.argv) != 3:
        raise SystemExit("usage: whole_read_python.py REPETITIONS FIXTURE")
    repetitions = int(sys.argv[1])
    if repetitions <= 0:
        raise SystemExit("repetitions must be positive")
    return repetitions, Path(sys.argv[2])


def main() -> None:
    repetitions, path = arguments()
    total_bytes = 0
    checksum = 0
    for _ in range(repetitions):
        data = path.read_bytes()
        total_bytes += len(data)
        checksum += len(data) + data[0] + data[-1]
    if total_bytes % repetitions:
        raise RuntimeError("inconsistent byte count")
    print(
        f"bytes={total_bytes // repetitions} reps={repetitions} "
        f"checksum={checksum}"
    )


if __name__ == "__main__":
    main()
