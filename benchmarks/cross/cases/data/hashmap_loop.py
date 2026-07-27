import sys


VALUE_MODULUS = 1_000_003


def requested_work() -> int:
    if len(sys.argv) < 2:
        return 1
    try:
        return max(0, int(sys.argv[1]))
    except ValueError:
        return 1


def main() -> None:
    work = requested_work()
    entries: dict[int, int] = {}
    for key in range(work):
        entries[key] = (17 * key + 3) % VALUE_MODULUS

    checksum = 0
    for key in range(work - 1, -1, -1):
        value = entries.get(key)
        if value is not None:
            checksum += value
    print(checksum)


if __name__ == "__main__":
    main()
