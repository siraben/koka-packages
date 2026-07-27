import json
import logging
import sys

MAX_REPETITIONS = 10_000_000

FIELDS = {
    "request-id": "r12345",
    "method": "GET",
    "path": "/items/42",
    "status": "200",
    "duration-ms": "3",
    "peer": "127.0.0.1:51234",
    "service": "notes",
    "cached": "true",
}


class CompactJSONFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        value = {
            "level": record.levelname.lower(),
            "ts": int(record.created * 1000),
            "msg": record.getMessage(),
        }
        value.update((name, getattr(record, name)) for name in FIELDS)
        return json.dumps(value, separators=(",", ":"))


class CountingHandler(logging.Handler):
    def __init__(self) -> None:
        super().__init__(logging.INFO)
        self.records = 0
        self.setFormatter(CompactJSONFormatter())

    def emit(self, record: logging.LogRecord) -> None:
        if self.format(record):
            self.records += 1


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
    handler = CountingHandler()
    logger = logging.Logger("cross-service", level=logging.INFO)
    logger.addHandler(handler)
    logger.propagate = False

    for _ in range(reps):
        logger.info("request", extra=FIELDS)
    print(handler.records)


if __name__ == "__main__":
    main()
