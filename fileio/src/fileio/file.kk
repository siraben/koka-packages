/* File I/O with real handles, integrated with scoped resources.

   `std/os/file` only offers whole-file read and write.  The reference service
   needs handles it can stream from, an atomic replace for its configuration
   and migration bookkeeping, and temporary files for its tests.

   ## Resource behaviour

   Every function that opens a descriptor comes in a `with-` form that closes
   it on success, on failure, and on cancellation, via `resource/scope`.  The
   raw `open` is available for callers that manage the lifetime themselves;
   they are responsible for the matching `close`, and double close is
   reported rather than ignored.

   ## Errors

   Failures throw with the operating system's message and the path, and carry
   `ExnSystem(errno)` so a caller can classify them.  `file-error-kind`
   turns the common cases into a small enumeration; everything else is
   `OtherError`.
*/
module fileio/file

import std/num/int32
import std/num/int64
import bytes/bytes
import resource/scope

extern import
  c file "file-inline.c"

// An open file descriptor.
pub value struct file( fd : int )

// How a file is opened.
pub struct open-mode
  read   : bool
  write  : bool
  create : bool
  trunc  : bool
  append : bool
  // Fail if the file already exists.  Combined with `create` this is the
  // standard "create exclusively" idiom.
  exclusive : bool

pub val read-only  : open-mode = Open-mode(True, False, False, False, False, False)
pub val write-only : open-mode = Open-mode(False, True, True, True, False, False)
pub val read-write : open-mode = Open-mode(True, True, True, False, False, False)
pub val append-only: open-mode = Open-mode(False, True, True, False, True, False)
pub val create-new : open-mode = Open-mode(False, True, True, False, False, True)

fun mode-flags( m : open-mode ) : int
  (if m.read then 1 else 0) +
  (if m.write then 2 else 0) +
  (if m.create then 4 else 0) +
  (if m.trunc then 8 else 0) +
  (if m.append then 16 else 0) +
  (if m.exclusive then 32 else 0)

// 0644: owner read/write, everyone else read.  Koka has no octal literals.
pub val default-perms : int = 420

// A classification of the common failures, so callers do not match on
// numbers.
pub type file-error
  NotFound
  PermissionDenied
  AlreadyExists
  IsDirectory
  OtherError( errno : int )

pub fun file-error-kind( errno : int ) : file-error
  match errno
    2  -> NotFound            // ENOENT
    13 -> PermissionDenied    // EACCES
    17 -> AlreadyExists       // EEXIST
    21 -> IsDirectory         // EISDIR
    _  -> OtherError(errno)

fun fail( op : string, path : string, err : int ) : exn a
  val e = if err < 0 then 0 - err else err
  throw(op ++ " " ++ path.show ++ ": " ++ prim-strerror(e.int32), ExnSystem(e))

// ----------------------------------------------------------------------------
// open and close
// ----------------------------------------------------------------------------

// Open a file.  The caller must `close` the result; prefer `with-file`.
pub fun open( path : string, mode : open-mode = read-only, perms : int = default-perms ) : io file
  val fd = prim-open(path, mode.mode-flags.int32, perms.int32).int
  if fd < 0 then fail("cannot open", path, fd)
  File(fd)

pub fun close( f : file ) : io ()
  val r = prim-close(f.fd.int32).int
  if r < 0 then fail("cannot close", "descriptor " ++ f.fd.show, r)

// Open a file, run `action`, and close it on every exit path.
pub fun with-file( path : string, action : (file) -> io a,
                   mode : open-mode = read-only, perms : int = default-perms ) : io a
  with-resource({ open(path, mode, perms) }, close-quietly, action)

// Closing during unwinding must not replace the original error, so the
// `with-` forms ignore close failures.  A close that fails on a descriptor we
// are abandoning anyway tells the caller nothing useful.
fun close-quietly( f : file ) : io ()
  prim-close(f.fd.int32)
  ()

// ----------------------------------------------------------------------------
// reading
// ----------------------------------------------------------------------------

// Read at most `max` octets.  An empty result means end of file; a read that
// fails throws, like every other call here.
pub fun read( f : file, max : int = 65536 ) : io bytes
  val b = unsafe-bytes-from-raw(prim-read(f.fd.int32, max.ssize_t))
  if b.is-notempty then b
  else
    // Empty is end of file only when the read did not fail.  `prim-read-error`
    // answers for *that* call and is 0 on success; the process-wide `errno` is
    // no use because nothing clears it.  Only the empty path pays the second
    // call into C.
    match prim-read-error().int
      0  -> b               // a real end of file
      // EINTR.  `kk_fio_read` already retries it, so this is belt and braces.
      4  -> read(f, max)
      // EAGAIN, from a descriptor someone else made non-blocking: retrying is
      // the right response rather than reporting end of file.
      11 -> read(f, max)
      e  -> fail("cannot read from", "descriptor " ++ f.fd.show, e)

// Read the whole file, in `chunk`-sized steps, up to `max-bytes`.
//
// The bound exists so that reading an unexpectedly huge file fails loudly
// instead of exhausting memory.  Pass a larger `max-bytes` deliberately.
pub fun read-all( f : file, chunk : int = 65536, max-bytes : int = 64 * 1024 * 1024 ) : io bytes
  read-loop(f, chunk, max-bytes, builder-empty(chunk), 0)

fun read-loop( f : file, chunk : int, max-bytes : int, acc : builder, sofar : int ) : io bytes
  val b = read(f, chunk)
  if b.is-empty then acc.finish
  else
    val total = sofar + b.length
    if total > max-bytes then
      throw("file is larger than the " ++ max-bytes.show ++ " byte limit")
    read-loop(f, chunk, max-bytes, acc.snoc(b), total)

// Read a whole file by path.
pub fun read-file( path : string, max-bytes : int = 64 * 1024 * 1024 ) : io bytes
  with-file(path, fn(f) read-all(f, 65536, max-bytes))

// Read a whole file as text, failing if it is not valid UTF-8.
pub fun read-text-file( path : string, max-bytes : int = 64 * 1024 * 1024 ) : io string
  match read-file(path, max-bytes).to-string
    Just(s)  -> s
    Nothing  -> throw(path.show ++ " is not valid UTF-8")

// Call `action` with each chunk as it is read, without holding the whole file.
pub fun stream( f : file, action : (bytes) -> io (), chunk : int = 65536 ) : io ()
  val b = read(f, chunk)
  if b.is-notempty then
    action(b)
    stream(f, action, chunk)

// ----------------------------------------------------------------------------
// writing
// ----------------------------------------------------------------------------

// Write every octet, looping over short writes.
pub fun write( f : file, data : bytes ) : io ()
  val n = prim-write-all(f.fd.int32, data.unsafe-bytes-raw).int
  if n < 0 then fail("cannot write to", "descriptor " ++ f.fd.show, n)

pub fun write-string( f : file, s : string ) : io ()
  f.write(bytes(s))

// Force buffered data to stable storage.
pub fun sync( f : file ) : io ()
  val r = prim-fsync(f.fd.int32).int
  if r < 0 then fail("cannot sync", "descriptor " ++ f.fd.show, r)

pub fun write-file( path : string, data : bytes, perms : int = default-perms ) : io ()
  with-file(path, fn(f) f.write(data), write-only, perms)

pub fun write-text-file( path : string, text : string, perms : int = default-perms ) : io ()
  write-file(path, bytes(text), perms)

// ----------------------------------------------------------------------------
// seeking
// ----------------------------------------------------------------------------

pub type whence
  FromStart
  FromCurrent
  FromEnd

pub fun seek( f : file, offset : int, from : whence = FromStart ) : io int
  val w = match from
            FromStart   -> 0
            FromCurrent -> 1
            FromEnd     -> 2
  val r = prim-seek(f.fd.int32, offset.int64, w.int32).int
  if r < 0 then fail("cannot seek in", "descriptor " ++ f.fd.show, r)
  r

// ----------------------------------------------------------------------------
// atomic replacement
// ----------------------------------------------------------------------------

// Replace `path` with `data`, atomically as far as any reader is concerned.
//
// Writes to a temporary file in the *same directory* (rename is only atomic
// within one filesystem), fsyncs it so the contents are durable before the
// name is swapped, then renames over the target.  A reader either sees the
// old file or the new one, never a half-written one.  If anything fails the
// temporary file is removed and `path` is untouched.
//
// KNOWN GAP: `perms` is accepted and **not applied**.  `mkstemp` creates the
// temporary file with 0600 and nothing changes it before the rename, so a file
// replaced through here comes out owner-only-readable whatever was asked for.
// Verified by measurement, not by reading: `replace-file(p, d, 420)` leaves `p`
// at 0600.  The fix is an `fchmod` before the rename; it changes observable
// behaviour, so it is recorded here and in the README rather than slipped in.
pub fun replace-file( path : string, data : bytes, perms : int = default-perms ) : io ()
  val dir  = prim-dirname(path)
  val tmpl = dir ++ "/.tmp-XXXXXX"
  val fd   = prim-mkstemp(tmpl).int
  if fd < 0 then fail("cannot create a temporary file in", dir, fd)
  val tmp  = prim-temp-name()
  val f    = File(fd)
  match try({ f.write(data); f.sync(); close-quietly(f) })
    Error(ex) ->
      close-quietly(f)
      prim-unlink(tmp)
      throw-exn(ex)
    Ok(_) ->
      val r = prim-rename(tmp, path).int
      if r < 0 then
        prim-unlink(tmp)
        fail("cannot replace", path, r)
      ()

pub fun replace-text-file( path : string, text : string, perms : int = default-perms ) : io ()
  replace-file(path, bytes(text), perms)

// ----------------------------------------------------------------------------
// temporary files
// ----------------------------------------------------------------------------

// Create a temporary file in `dir`, run `action` with its path and an open
// handle, then close and remove it -- on every exit path.
pub fun with-temp-file( action : (string, file) -> io a,
                        dir : string = "/tmp", pre : string = "kk" ) : io a
  val fd = prim-mkstemp(dir ++ "/" ++ pre ++ "-XXXXXX").int
  if fd < 0 then fail("cannot create a temporary file in", dir, fd)
  val path = prim-temp-name()
  val f    = File(fd)
  finally({ close-quietly(f); prim-unlink(path); () }, { action(path, f) })

// ----------------------------------------------------------------------------
// metadata
// ----------------------------------------------------------------------------

pub type path-kind
  Missing
  RegularFile
  Directory
  Other

pub fun kind( path : string ) : io path-kind
  match prim-kind(path).int
    1 -> RegularFile
    2 -> Directory
    3 -> Other
    // 0 is not "missing", it is "the stat did not succeed"; which of those it
    // is takes asking.
    _ -> stat-failed(path)

// A `stat` that fails is not the same as a path that is not there.  ENOENT and
// ENOTDIR do say it is not there.  EACCES, ELOOP, ENAMETOOLONG and EIO say we
// could not find out, and answering `Missing` to those tells the caller the
// opposite of the truth -- so they throw, as every other failure here does.
fun stat-failed( path : string ) : io path-kind
  match prim-stat-error().int
    0  -> Missing
    2  -> Missing    // ENOENT: no such file or directory
    20 -> Missing    // ENOTDIR: a component of the path is not a directory
    e  -> fail("cannot stat", path, e)

pub fun path-exists( path : string ) : io bool
  match path.kind
    Missing -> False
    _       -> True

pub fun size( path : string ) : io int
  val n = prim-size(path).int
  if n < 0 then fail("cannot stat", path, n)
  n

// Modification time in whole seconds since the epoch.
//
// The sign carries no error: `st_mtime` is signed and a file older than 1970
// has a negative one.  `prim-mtime` answers 0 for a failed stat, and 0 is also
// the epoch itself, so that single value is the one worth asking about.
pub fun modified-at( path : string ) : io int
  val t = prim-mtime(path).int
  if t != 0 then t
  else
    match prim-stat-error().int
      0 -> 0
      e -> fail("cannot stat", path, e)

pub fun remove( path : string ) : io ()
  val r = prim-unlink(path).int
  if r < 0 then fail("cannot remove", path, r)

pub fun rename( from : string, to : string ) : io ()
  val r = prim-rename(from, to).int
  if r < 0 then fail("cannot rename", from, r)

// ----------------------------------------------------------------------------
// primitives
// ----------------------------------------------------------------------------

extern prim-open( path : string, flags : int32, mode : int32 ) : io int32
  c "kk_fio_open"
extern prim-close( fd : int32 ) : io int32
  c "kk_fio_close"
extern prim-read( fd : int32, max : ssize_t ) : io any
  c "kk_fio_read"
// Why the last `prim-read` came back empty; 0 if it did not fail.
extern prim-read-error() : io int32
  c "kk_fio_read_error"
extern prim-write-all( fd : int32, data : any ) : io ssize_t
  c "kk_fio_write_all"
extern prim-fsync( fd : int32 ) : io int32
  c "kk_fio_fsync"
extern prim-seek( fd : int32, off : int64, whence : int32 ) : io int64
  c "kk_fio_seek"
extern prim-size( path : string ) : io int64
  c "kk_fio_size"
extern prim-kind( path : string ) : io int32
  c "kk_fio_kind"
extern prim-mtime( path : string ) : io int64
  c "kk_fio_mtime"
// Why the last `prim-kind` or `prim-mtime` gave up; 0 if the stat succeeded.
extern prim-stat-error() : io int32
  c "kk_fio_stat_error"
extern prim-rename( from : string, to : string ) : io int32
  c "kk_fio_rename"
extern prim-unlink( path : string ) : io int32
  c "kk_fio_unlink"
extern prim-mkstemp( templ : string ) : io int32
  c "kk_fio_mkstemp"
extern prim-temp-name() : io string
  c "kk_fio_temp_name"
extern prim-strerror( err : int32 ) : string
  c "kk_fio_strerror"
extern prim-dirname( path : string ) : string
  c "kk_fio_dirname"
