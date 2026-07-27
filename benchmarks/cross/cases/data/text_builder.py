import io
import sys


APPENDS_PER_REPETITION = 80_000
CHECKSUM_MULTIPLIER = 1_000_003
CHECKSUM_MODULUS = 1_000_000_007
CHUNK = "0123456789"


def requested_work() -> int:
    if len(sys.argv) < 2:
        return 1
    try:
        return max(0, int(sys.argv[1]))
    except ValueError:
        return 1


def one_repetition() -> int:
    output = io.StringIO()
    for _ in range(APPENDS_PER_REPETITION):
        output.write(CHUNK)
    n = output.tell()
    result = output.getvalue()
    return n + (0 if not result else 1)


def main() -> None:
    checksum = 0
    for _ in range(requested_work()):
        checksum = (
            checksum * CHECKSUM_MULTIPLIER + one_repetition()
        ) % CHECKSUM_MODULUS
    print(checksum)


if __name__ == "__main__":
    main()
