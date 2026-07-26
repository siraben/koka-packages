# fileio

Real file handles: open, read, write, seek, stream, stat, rename, remove, plus
an atomic replace and temporary files, all integrated with `resource/scope` so
a descriptor is closed on success, on failure, and on cancellation.  It exists
because `std/os/file` offers whole-file read and write only, and the reference
service needs to stream from a handle, to replace its configuration file
atomically, and to make temporary files in its tests.  It is deliberately *not*
a filesystem library: there is no directory listing (that is `std/os/dir`), no
path manipulation (`std/os/path`), no globbing, no permissions API beyond the
mode passed at creation, no file locking, no memory mapping, and no watching.

## Public API

### Opening and closing

| declaration | signature | what it is |
| --- | --- | --- |
| `file` | `value struct { fd : int }` | An open descriptor |
| `open-mode` | `struct { read; write; create; trunc; append; exclusive }` | |
| `read-only`, `write-only`, `read-write`, `append-only`, `create-new` | `: open-mode` | The five combinations this tree uses.  `create-new` is create-exclusively |
| `default-perms` | `: int` | 420, which is 0644.  Koka has no octal literals |
| `open` | `(path : string, mode : open-mode = read-only, perms : int = default-perms) : io file` | The caller must `close`; prefer `with-file` |
| `close` | `(f : file) : io ()` | Reports a failing close |
| `with-file` | `(path : string, action : (file) -> io a, mode : open-mode = read-only, perms : int = default-perms) : io a` | Closes on every exit path, ignoring close errors |

### Reading

| declaration | signature | what it is |
| --- | --- | --- |
| `read` | `(f : file, max : int = 65536) : io bytes` | At most `max` octets; empty means end of file.  Retries on `EINTR`/`EAGAIN` |
| `read-all` | `(f : file, chunk : int = 65536, max-bytes : int = 64 MiB) : io bytes` | The whole file, in chunks, bounded |
| `read-file` | `(path : string, max-bytes : int = 64 MiB) : io bytes` | |
| `read-text-file` | `(path : string, max-bytes : int = 64 MiB) : io string` | Throws if the contents are not valid UTF-8 |
| `stream` | `(f : file, action : (bytes) -> io (), chunk : int = 65536) : io ()` | Each chunk as it arrives, without holding the whole file |

### Writing

| declaration | signature | what it is |
| --- | --- | --- |
| `write` | `(f : file, data : bytes) : io ()` | Loops over short writes |
| `write-string` | `(f : file, s : string) : io ()` | |
| `sync` | `(f : file) : io ()` | fsync |
| `write-file` | `(path : string, data : bytes, perms : int = default-perms) : io ()` | |
| `write-text-file` | `(path : string, text : string, perms : int = default-perms) : io ()` | |
| `replace-file` | `(path : string, data : bytes, perms : int = default-perms) : io ()` | Write to a temporary file in the same directory, fsync it, rename over the target |
| `replace-text-file` | `(path : string, text : string, perms : int = default-perms) : io ()` | |

### Seeking, metadata, and temporary files

| declaration | signature | what it is |
| --- | --- | --- |
| `whence` | `type { FromStart; FromCurrent; FromEnd }` | |
| `seek` | `(f : file, offset : int, from : whence = FromStart) : io int` | The new offset |
| `path-kind` | `type { Missing; RegularFile; Directory; Other }` | |
| `kind` | `(path : string) : io path-kind` | |
| `path-exists` | `(path : string) : io bool` | |
| `size` | `(path : string) : io int` | |
| `modified-at` | `(path : string) : io int` | Whole seconds since the epoch |
| `remove` | `(path : string) : io ()` | |
| `rename` | `(from : string, to : string) : io ()` | |
| `with-temp-file` | `(action : (string, file) -> io a, dir : string = "/tmp", pre : string = "kk") : io a` | Creates it, hands over the path and an open handle, closes and unlinks on every exit path |

### Errors

Failures throw with the operating system's message and the path, carrying
`ExnSystem(errno)`.  `file-error-kind(errno) : file-error` turns the common
cases into `NotFound`, `PermissionDenied`, `AlreadyExists`, `IsDirectory`, and
`OtherError(errno)` for everything else.

## Complexity

| operation | cost |
| --- | --- |
| `open`, `close`, `seek`, `size`, `kind`, `modified-at`, `rename`, `remove` | one syscall |
| `read` | one syscall, plus one copy of what it returned |
| `read-all` / `read-file` over an n-octet file | O(n) — accumulated through `bytes/builder`, so not O(n²) |
| `stream` | O(n) time, O(chunk) live memory |
| `write` | one syscall per short write; `kk_fio_write_all` loops in C |
| `replace-file` | one write, **one fsync**, one rename |

Measured on this machine (AMD Ryzen 9 5950X, 32 threads, 126 GiB, Linux 7.0.1
x86_64, Koka 3.2.7, `--release`, fastest of 3), against `/tmp`, which on this
machine is a real on-disk filesystem and not a tmpfs:

| what | n | ms | units/s |
| --- | ---: | ---: | ---: |
| `write-file`, 1 MiB at a time (n = MiB) | 64 | 135 | 474 |
| `write-file`, 8 MiB at a time (n = MiB) | 64 | 119 | 537 |
| `read-file`, 1 MiB (n = MiB) | 64 | 8 | 8 000 |
| `read-file`, 8 MiB (n = MiB) | 64 | 12 | 5 333 |
| `stream` 8 MiB in 64 KiB chunks (n = MiB) | 64 | 5 | 12 800 |
| `stream` 8 MiB in 4 KiB chunks (n = MiB) | 64 | 15 | 4 266 |
| open + close a handle | 20 000 | 44 | 454 545 |
| `write-file`, 4 KiB | 5 000 | 265 | 18 867 |
| `replace-file`, 4 KiB (fsync + rename) | 500 | 2 415 | 207 |

Reads come out of the page cache at 4–12 GiB/s, so what those rows measure is
the copy out of the kernel and into a `:bytes`, not the disk.  The row worth
carrying away is the last pair: writing 4 KiB costs about 53 µs and *replacing*
4 KiB costs about 4.8 ms — **91 times more**, and all of it the fsync.  That is
the price of the durability `replace-file` promises, and it is why it does not
belong on a request path.

The absolute numbers are this filesystem's, not this package's; only the ratio
travels.  Reproduce with `./run-benchmarks.sh fileio` from the repository root.

## Worked example

```koka
import bytes/bytes
import fileio/file

fun main()
  val path = "/tmp/fileio-example.txt"

  // Whole-file write and read.
  write-text-file(path, "one\ntwo\nthree\n")
  println(read-text-file(path))

  // A handle, streamed in chunks, without holding the file in memory.
  val octets = ref(0)
  with-file(path) fn(f)
    f.stream(fn(chunk) octets := !octets + chunk.length, 4)
  println("streamed " ++ (!octets).show ++ " octets")

  // Atomic replace: a reader sees the old contents or the new ones, never a
  // half-written file.  Costs an fsync.
  replace-text-file(path, "replaced\n")
  println(read-text-file(path))

  // Metadata, then clean up.
  val what = match path.kind
               RegularFile -> "file"
               Directory   -> "directory"
               Missing     -> "missing"
               Other       -> "other"
  println("size " ++ size(path).show ++ ", kind " ++ what)
  remove(path)
```

## Limits

* **`replace-file` ignores its `perms` argument.**  `mkstemp` creates the
  temporary file with 0600 and nothing changes it before the rename, so the
  replaced file ends up 0600 regardless of what was asked for.  This is a real
  gap: a configuration file replaced through this call comes out
  owner-only-readable.  Fixing it means an `fchmod` before the rename, which
  changes observable behaviour, so it is recorded here rather than changed
  quietly.
* **`replace-file` does not fsync the containing directory.**  The file's
  contents are durable before the rename, but the rename itself may not survive
  a power loss on every filesystem.
* **`read-all` and `read-file` are bounded at 64 MiB by default** and throw
  past it.  That is deliberate — reading an unexpectedly huge file should fail
  loudly rather than exhaust memory — but it means a caller that really wants a
  larger file has to say so.
* **`read` retries only `EINTR` (4) and `EAGAIN` (11)**, and treats any other
  empty result as end of file.  The errno numbers are Linux's.
* **`file-error-kind` hardcodes Linux errno values** (2, 13, 17, 21).  On
  another platform those constants are wrong, and everything falls through to
  `OtherError`.
* **Everything blocks the process.**  This package is for startup, migrations,
  configuration and tests.  A request handler that wants file I/O without
  stalling the event loop does not have a way to do it here; `runtime` covers
  sockets and timers, not files.
* **The raw `open` leaves the lifetime to the caller**, and a double `close`
  is reported rather than ignored.  The `with-` forms take the opposite line
  and swallow close failures, so that a close during unwinding cannot replace
  the original error.
* **`with-temp-file` defaults to `/tmp`**, which may not be where the caller
  wants it, and creates the file with `mkstemp`'s 0600.
