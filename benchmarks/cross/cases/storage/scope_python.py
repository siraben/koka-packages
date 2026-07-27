#!/usr/bin/env python3
import sys


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: scope_python.py SCOPES FIXTURE")
    scopes = int(sys.argv[1])
    if scopes <= 0:
        raise SystemExit("scope count must be positive")
    checksum = 0
    for _ in range(scopes):
        with open(sys.argv[2], "rb") as source:
            checksum += len(source.read(1))
    print(f"scopes={scopes} bytes={checksum} checksum={checksum}")


if __name__ == "__main__":
    main()
