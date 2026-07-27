import json
import sys

MAX_REPETITIONS = 1_000_000


def repetitions() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: python.py REPETITIONS")
    try:
        value = int(sys.argv[1], 10)
    except ValueError as exc:
        raise SystemExit("repetitions must be an integer") from exc
    if not 0 <= value <= MAX_REPETITIONS:
        raise SystemExit("repetitions must be from 0 through 1000000")
    return value


def main() -> None:
    reps = repetitions()
    document = json.dumps(list(range(2000)), separators=(",", ":"))
    checksum = 0
    for _ in range(reps):
        parsed = json.loads(document)
        if not isinstance(parsed, list) or not parsed:
            raise RuntimeError("parsed JSON was not a non-empty array")
        checksum += 1
    print(checksum)


if __name__ == "__main__":
    main()
