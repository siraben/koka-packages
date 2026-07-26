import kktest/assert
import kktest/runner
import kktest/tmp
import fileio/file
import bytes/bytes

fun in-dir( action : (string) -> io a ) : io a
  with-temp-dir(action, "fileio-test")

// A file that is opened and never explicitly closed inside a with- form: the
// point is that the with- form closes it anyway.
fun leaky( path : string ) : io ()
  with-file(path, fn(_f) throw("boom"), write-only)

fun main()
  run-tests([
    group("whole files", [
      test("write then read", fn()
        in-dir fn(d)
          val p = d ++ "/a.txt"
          write-text-file(p, "hello")
          assert-equal(read-text-file(p), "hello")
      ),
      test("binary content survives", fn()
        in-dir fn(d)
          val p = d ++ "/b.bin"
          val data = bytes([0, 1, 255, 128, 0])
          write-file(p, data)
          assert-true(read-file(p) == data)
      ),
      test("empty file", fn()
        in-dir fn(d)
          val p = d ++ "/empty"
          write-text-file(p, "")
          assert-equal(read-file(p).length, 0)
      ),
      test("reading a missing file reports not found", fn()
        in-dir fn(d)
          assert-throws({ read-text-file(d ++ "/nope") }, containing = "cannot open")
      ),
      test("a size limit is enforced", fn()
        in-dir fn(d)
          val p = d ++ "/big"
          write-text-file(p, "0123456789")
          assert-throws({ read-file(p, 5) }, containing = "larger than")
      ),
      test("invalid utf-8 is rejected as text", fn()
        in-dir fn(d)
          val p = d ++ "/bad"
          write-file(p, bytes([0xC3]))
          assert-throws({ read-text-file(p) }, containing = "not valid UTF-8")
      ),
    ]),

    group("handles", [
      test("open, write, seek, read", fn()
        in-dir fn(d)
          val p = d ++ "/h.txt"
          with-file(p, fn(f)
            f.write-string("hello world")
            f.seek(6)
            assert-equal(f.read(5).to-string-lossy, "world")
          , read-write)
      ),
      test("with-file closes even when the body throws", fn()
        in-dir fn(d)
          val p = d ++ "/c.txt"
          assert-throws({ leaky(p) }, containing = "boom")
          // the file was created, so it was really opened, and we can open it
          // again -- which we could not if the descriptor had leaked in a way
          // that mattered
          assert-true(path-exists(p))
          assert-equal(read-text-file(p), "")
      ),
      test("closing twice is reported", fn()
        in-dir fn(d)
          val p = d ++ "/dc.txt"
          write-text-file(p, "x")
          val f = open(p)
          f.close()
          assert-throws({ f.close() }, containing = "cannot close")
      ),
      test("many open/close cycles do not exhaust descriptors", fn()
        in-dir fn(d)
          val p = d ++ "/loop.txt"
          write-text-file(p, "x")
          var i := 0
          while { i < 2000 }
            with-file(p, fn(f) f.read(1))
            i := i + 1
          assert-equal(i, 2000)
      , timeout-s = 60),
      test("streaming reads see the whole file", fn()
        in-dir fn(d)
          val p = d ++ "/s.txt"
          write-text-file(p, "abcdefghij")
          // a global ref, not `var`: the closure crosses into `io`
          val seen = ref(0)
          with-file(p, fn(f) f.stream(fn(b) seen := !seen + b.length, 3))
          assert-equal(!seen, 10)
      ),
      test("append mode adds to the end", fn()
        in-dir fn(d)
          val p = d ++ "/ap.txt"
          write-text-file(p, "a")
          with-file(p, fn(f) f.write-string("b"), append-only)
          assert-equal(read-text-file(p), "ab")
      ),
      test("create-new refuses an existing file", fn()
        in-dir fn(d)
          val p = d ++ "/x.txt"
          write-text-file(p, "a")
          assert-throws({ open(p, create-new) }, containing = "cannot open")
      ),
    ]),

    group("atomic replacement", [
      test("replaces the contents", fn()
        in-dir fn(d)
          val p = d ++ "/r.txt"
          write-text-file(p, "old")
          replace-text-file(p, "new")
          assert-equal(read-text-file(p), "new")
      ),
      test("creates the file when it does not exist", fn()
        in-dir fn(d)
          val p = d ++ "/r2.txt"
          replace-text-file(p, "fresh")
          assert-equal(read-text-file(p), "fresh")
      ),
      test("leaves no temporary files behind", fn()
        in-dir fn(d)
          val p = d ++ "/r3.txt"
          replace-text-file(p, "a")
          replace-text-file(p, "b")
          // the temporary is created as .tmp-XXXXXX in the same directory
          assert-false(path-exists(d ++ "/.tmp-XXXXXX"))
          assert-equal(read-text-file(p), "b")
      ),
      test("the old contents survive a failed replace", fn()
        in-dir fn(d)
          val p = d ++ "/r4.txt"
          write-text-file(p, "keep me")
          // replacing into a directory that does not exist must fail without
          // touching the original
          assert-throws({ replace-text-file(d ++ "/missing/r.txt", "x") })
          assert-equal(read-text-file(p), "keep me")
      ),
    ]),

    group("temporary files", [
      test("created, usable, and removed", fn()
        in-dir fn(d)
          val seen = ref("")
          with-temp-file(fn(path, f)
            f.write-string("temp")
            seen := path
            assert-true(path-exists(path))
          , d)
          assert-false(path-exists(!seen), "the temporary file was not removed")
      ),
      test("removed even when the body throws", fn()
        in-dir fn(d)
          val seen = ref("")
          assert-throws({ with-temp-file(fn(path, _f) { seen := path; throw("boom") }, d) },
                        containing = "boom")
          assert-false(path-exists(!seen), "the temporary file was not removed")
      ),
    ]),

    group("metadata", [
      test("kind", fn()
        in-dir fn(d)
          val p = d ++ "/m.txt"
          write-text-file(p, "abc")
          assert-true(path-exists(p))
          assert-false(path-exists(d ++ "/nope"))
          match p.kind
            RegularFile -> ()
            _ -> assert-fail("expected a regular file")
          match d.kind
            Directory -> ()
            _ -> assert-fail("expected a directory")
      ),
      test("size", fn()
        in-dir fn(d)
          val p = d ++ "/sz.txt"
          write-text-file(p, "12345")
          assert-equal(size(p), 5)
      ),
      test("modification time is plausible", fn()
        in-dir fn(d)
          val p = d ++ "/t.txt"
          write-text-file(p, "x")
          // after 2020-01-01 and before 2100
          assert-true(modified-at(p) > 1577836800)
          assert-true(modified-at(p) < 4102444800)
      ),
      test("remove and rename", fn()
        in-dir fn(d)
          val a = d ++ "/one"
          val b = d ++ "/two"
          write-text-file(a, "x")
          rename(a, b)
          assert-false(path-exists(a))
          assert-true(path-exists(b))
          remove(b)
          assert-false(path-exists(b))
          assert-throws({ remove(b) }, containing = "cannot remove")
      ),
    ]),
  ])
