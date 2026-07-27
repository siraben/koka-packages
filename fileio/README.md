# fileio

Real file handles: open, read, write, seek, stream, stat, rename, remove, plus
an atomic replace and temporary files, all integrated with `resource/scope` so
a descriptor is closed on success, on failure, and on cancellation.  It exists
because `std/os/file` offers whole-file read and write only, and the reference
service needs to stream from a handle, to replace its configuration file
atomically, and to make temporary files in its tests.  It is deliberately *not*
a filesystem library: there is no directory listing (that is `std/os/dir`), no
path manipulation (`std/os/path`), no globbing, no ownership or ACL API, no
file locking, no memory mapping, and no watching.

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

Permission values must be between 0 and 4095 (07777). Custom modes reject
`exclusive` without `create`, and `trunc` or `append` without write access.

### Reading

| declaration | signature | what it is |
| --- | --- | --- |
| `read` | `(f : file, max : int = 65536) : io bytes` | At most `max` octets; empty means end of file, a failed read throws.  Retries interrupted syscalls; rejects a negative maximum |
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
| `set-permissions` | `(f : file, perms : int) : io ()` | Change an open descriptor's permission bits |
| `write-file` | `(path : string, data : bytes, perms : int = default-perms) : io ()` | |
| `write-text-file` | `(path : string, text : string, perms : int = default-perms) : io ()` | |
| `replace-file` | `(path : string, data : bytes, perms : int = default-perms) : io ()` | Write to a same-directory temporary, apply `perms`, fsync it, rename, then fsync the directory |
| `replace-text-file` | `(path : string, text : string, perms : int = default-perms) : io ()` | |

### Seeking, metadata, and temporary files

| declaration | signature | what it is |
| --- | --- | --- |
| `whence` | `type { FromStart; FromCurrent; FromEnd }` | |
| `seek` | `(f : file, offset : int, from : whence = FromStart) : io int` | The new offset |
| `path-kind` | `type { Missing; RegularFile; Directory; Other }` | |
| `kind` | `(path : string) : io path-kind` | `Missing` only when the path really is not there (ENOENT, ENOTDIR); a stat that fails for any other reason throws |
| `path-exists` | `(path : string) : io bool` | `False` means "not there", not "could not tell" — see `kind` |
| `size` | `(path : string) : io int` | |
| `modified-at` | `(path : string) : io int` | Whole seconds since the epoch, negative for a file older than 1970 |
| `permissions` | `(path : string) : io int` | Permission and special bits |
| `set-path-permissions` | `(path : string, perms : int) : io ()` | Change a path's permission bits |
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
| `replace-file` | one write, chmod, file fsync, rename, directory fsync |

`replace-file` performs two durability barriers, so its latency is dominated by
the filesystem rather than the number of bytes for small files. It belongs on
configuration, checkpoint, and migration paths, not on a hot request path.
Measure the actual target filesystem with `./run-benchmarks.sh fileio`.

### Across languages

![64 MiB streaming in Koka, C++, Go, and Python](../benchmarks/cross/figures/storage-stream-64m-64k.svg)

![Whole-file reads in Koka, C++, Go, and Python](../benchmarks/cross/figures/storage-read-whole-file.svg)

The suite reads and checksums the same generated file as both a stream of
64 KiB chunks and a complete value. See the
[ten-run time/RSS methodology](../benchmarks/cross/README.md).

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
  // half-written file. Costs a file fsync plus a directory fsync.
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

* **`read-all` and `read-file` are bounded at 64 MiB by default** and throw
  past it.  That is deliberate — reading an unexpectedly huge file should fail
  loudly rather than exhaust memory — but it means a caller that really wants a
  larger file has to say so.
* **A directory-sync failure is reported after the rename has happened.**
  At that point the new contents are visible and cannot be rolled back safely;
  the exception means durability of the directory entry is uncertain, not
  that the old file is still present.
* **The implementation is POSIX-only.** Error classification uses the host's
  errno constants rather than Linux numbers, but the native layer still relies
  on `open`, `read`, `mkstemp`, `fchmod`, `fsync`, and directory descriptors.
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
