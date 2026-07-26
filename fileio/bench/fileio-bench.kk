/* What this measures, and why.

   These numbers are dominated by the operating system and the filesystem, not
   by Koka, and that is the point: the package's claim is that it adds handles
   and streaming *without* adding a copy, so what should show up is close to
   what the kernel can do.

   `replace-file` is reported separately and is expected to be far slower per
   call than `write-file`, because it fsyncs before renaming.  That is the
   durability it promises, and it is worth knowing what it costs before putting
   it on a request path.

   Everything runs under `/tmp`, so the numbers describe whatever filesystem
   that is on the machine doing the measuring -- which may be a tmpfs, and may
   be a real disk with a real fsync.  Check before quoting an absolute number.
   The portable result is the *ratio* between `write-file` and `replace-file`,
   not either of them on its own.
*/
import kktest/bench
import bytes/bytes
import fileio/file

val payload-one-mib : bytes = bytes/replicate(65, 1024 * 1024)

fun scratch( name : string ) : string
  "/tmp/kk-fileio-bench-" ++ name

// Write `mib` MiB, `reps` times.
fun write-loop( path : string, reps : int, mib : int ) : io int
  val data = build-payload(mib, builder-empty(mib * 1024 * 1024))
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else
      write-file(path, data)
      go(i + 1, seen + data.length)
  go(0, 0)

// Written once so the read rows below have something to read.
fun seed( path : string, mib : int ) : io ()
  write-file(path, build-payload(mib, builder-empty(mib * 1024 * 1024)))

fun build-payload( mib : int, acc : builder ) : io bytes
  if mib <= 0 then acc.finish else build-payload(mib - 1, acc.snoc(payload-one-mib))

fun read-only-loop( path : string, reps : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen else go(i + 1, seen + read-file(path).length)
  go(0, 0)

// Streaming: the whole file passes through `action` in chunks and is never
// held in one piece.
fun stream-loop( path : string, reps : int, chunk : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else
      val counted = ref(0)
      with-file(path, fn(f) f.stream(fn(b) counted := !counted + b.length, chunk))
      go(i + 1, seen + !counted)
  go(0, 0)

fun replace-loop( path : string, reps : int, data : bytes ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else
      replace-file(path, data)
      go(i + 1, seen + data.length)
  go(0, 0)

fun open-close-loop( path : string, reps : int ) : io int
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else go(i + 1, seen + with-file(path, fn(f) f.fd))
  go(0, 0)

fun main()
  val one = scratch("1m.dat")
  val eight = scratch("8m.dat")
  val small = scratch("small.dat")
  write-file(small, bytes("x".repeat(4096)))
  seed(one, 1)
  seed(eight, 8)
  val rows = [
    measure("write-file, 1 MiB at a time (n = MiB)", 64, fn() write-loop(one, 64, 1) / (1024 * 1024)),
    measure("write-file, 8 MiB at a time (n = MiB)", 64, fn() write-loop(eight, 8, 8) / (1024 * 1024)),
    measure("read-file, 1 MiB (n = MiB)",           64, fn() read-only-loop(one, 64) / (1024 * 1024)),
    measure("read-file, 8 MiB (n = MiB)",           64, fn() read-only-loop(eight, 8) / (1024 * 1024)),
    measure("stream 8 MiB in 64 KiB chunks (n=MiB)", 64, fn() stream-loop(eight, 8, 65536) / (1024 * 1024)),
    measure("stream 8 MiB in 4 KiB chunks (n=MiB)", 64, fn() stream-loop(eight, 8, 4096) / (1024 * 1024)),
    measure("open + close a handle",             20000, fn() open-close-loop(small, 20000)),
    measure("write-file, 4 KiB",                  5000, fn() replace-through-write(small, 5000)),
    measure("replace-file, 4 KiB (fsync+rename)",  500, fn() replace-loop(small, 500, bytes("x".repeat(4096))) / 4096),
  ]
  remove(one)
  remove(eight)
  remove(small)
  report("fileio", rows)

// The same 4 KiB payload as `replace-loop`, without the fsync and the rename,
// so the two rows differ in exactly the durability step.
fun replace-through-write( path : string, reps : int ) : io int
  val data = bytes("x".repeat(4096))
  fun go( i : int, seen : int ) : io int
    if i >= reps then seen
    else
      write-file(path, data)
      go(i + 1, seen + 1)
  go(0, 0)
