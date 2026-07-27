import sys


SEGMENT_SIZE = 32_768
SEGMENT_COUNT = 256
CHECKSUM_MULTIPLIER = 1_000_003
CHECKSUM_MODULUS = 1_000_000_007
DELIMITER = b"|"


def requested_work() -> int:
    if len(sys.argv) < 2:
        return 1
    try:
        return max(0, int(sys.argv[1]))
    except ValueError:
        return 1


def make_input() -> bytes:
    segment = b"a" * (SEGMENT_SIZE - 1) + DELIMITER
    return segment * SEGMENT_COUNT


def scan(input_bytes: bytes) -> int:
    start = 0
    total = 0
    while start < len(input_bytes):
        index = input_bytes.find(DELIMITER, start)
        if index < 0:
            break
        total += index + 1
        start = index + 1
    return total


def main() -> None:
    input_bytes = make_input()
    checksum = 0
    for _ in range(requested_work()):
        checksum = (
            checksum * CHECKSUM_MULTIPLIER + scan(input_bytes)
        ) % CHECKSUM_MODULUS
    print(checksum)


if __name__ == "__main__":
    main()
