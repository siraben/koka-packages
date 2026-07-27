import sys


APPENDS_PER_REPETITION = 80_000
OUTPUT_SIZE = 800_000
CHECKSUM_MULTIPLIER = 1_000_003
CHECKSUM_MODULUS = 1_000_000_007
CHUNK = b"0123456789"


def requested_work() -> int:
    if len(sys.argv) < 2:
        return 1
    try:
        return max(0, int(sys.argv[1]))
    except ValueError:
        return 1


def one_repetition() -> int:
    output = bytearray()
    for _ in range(APPENDS_PER_REPETITION):
        output.extend(CHUNK)
    return len(output) + (0 if not output else 1)


def main() -> None:
    checksum = 0
    for _ in range(requested_work()):
        checksum = (
            checksum * CHECKSUM_MULTIPLIER + one_repetition()
        ) % CHECKSUM_MODULUS
    print(checksum)


if __name__ == "__main__":
    main()
