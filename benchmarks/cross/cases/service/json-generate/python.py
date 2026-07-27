import json
import sys

MAX_REPETITIONS = 10_000_000


def repetitions() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: python.py REPETITIONS")
    try:
        value = int(sys.argv[1], 10)
    except ValueError as exc:
        raise SystemExit("repetitions must be an integer") from exc
    if not 0 <= value <= MAX_REPETITIONS:
        raise SystemExit("repetitions must be from 0 through 10000000")
    return value


def main() -> None:
    reps = repetitions()
    values = list(range(2000))
    checksum = 0
    for _ in range(reps):
        encoded = json.dumps(values, separators=(",", ":"))
        checksum += len(encoded)
    print(checksum)


if __name__ == "__main__":
    main()
