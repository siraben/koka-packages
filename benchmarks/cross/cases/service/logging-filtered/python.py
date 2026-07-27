import logging
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
    fields = {
        "request-id": "r12345",
        "method": "GET",
        "path": "/items/42",
        "status": "200",
        "duration-ms": "3",
        "peer": "127.0.0.1:51234",
        "service": "notes",
        "cached": "true",
    }
    logger = logging.Logger("cross-service", level=logging.ERROR)
    logger.addHandler(logging.NullHandler())

    for _ in range(reps):
        logger.info("request", extra=fields)
    print(reps)


if __name__ == "__main__":
    main()
