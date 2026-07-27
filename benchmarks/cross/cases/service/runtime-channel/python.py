import queue
import sys
import threading

MAX_HANDOFFS = 10_000_000
END = object()


def handoffs() -> int:
    if len(sys.argv) != 2:
        raise SystemExit("usage: python.py HANDOFFS")
    try:
        value = int(sys.argv[1], 10)
    except ValueError as exc:
        raise SystemExit("handoffs must be an integer") from exc
    if not 0 <= value <= MAX_HANDOFFS:
        raise SystemExit("handoffs must be from 0 through 10000000")
    return value


def main() -> None:
    count = handoffs()
    channel: queue.Queue[object] = queue.Queue(maxsize=256)

    def produce() -> None:
        for value in range(count):
            channel.put(value)
        channel.put(END)

    producer = threading.Thread(target=produce)
    producer.start()
    checksum = 0
    while True:
        value = channel.get()
        if value is END:
            break
        checksum += int(value)
    producer.join()
    print(checksum)


if __name__ == "__main__":
    main()
