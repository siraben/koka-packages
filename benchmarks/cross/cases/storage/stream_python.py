#!/usr/bin/env python3
import sys

CHUNK_SIZE = 65_536


def arguments() -> tuple[int, str]:
    if len(sys.argv) != 3:
        raise SystemExit("usage: stream_python.py REPETITIONS FIXTURE")
    repetitions = int(sys.argv[1])
    if repetitions <= 0:
        raise SystemExit("repetitions must be positive")
    return repetitions, sys.argv[2]


def one_pass(path: str) -> tuple[int, int]:
    seen = 0
    checksum = 0
    with open(path, "rb", buffering=CHUNK_SIZE) as source:
        while chunk := source.read(CHUNK_SIZE):
            seen += len(chunk)
            checksum += len(chunk) + chunk[0] + chunk[-1]
    return seen, checksum


def main() -> None:
    repetitions, path = arguments()
    total_bytes = 0
    checksum = 0
    for _ in range(repetitions):
        seen, partial = one_pass(path)
        total_bytes += seen
        checksum += partial
    if total_bytes % repetitions:
        raise RuntimeError("inconsistent byte count")
    print(
        f"bytes={total_bytes // repetitions} reps={repetitions} "
        f"checksum={checksum}"
    )


if __name__ == "__main__":
    main()
