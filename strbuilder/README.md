# strbuilder

An O(n) string builder with JSON escaping, over `bytes/builder`.  It exists for
one reason: `s := s ++ x` in a loop copies everything built so far at every
step, so building an n-character string that way is O(n²).  This appends into a
growable buffer instead.  The accumulated text stays UTF-8 the whole way, so
`finish-bytes` can hand it to a socket without a decode and a re-encode.  It is
deliberately *not* a formatting library: there is no template syntax, no
padding or alignment beyond what `std/core/string` already offers, no
locale-aware number formatting, and no escaping scheme other than JSON's.  It
is the thing the JSON generator, the HTTP response writer and the logger are
built on, and nothing more.

## Public API

| declaration | signature | what it is |
| --- | --- | --- |
| `strbuilder` | `(capacity : int = 256) : strbuilder` | A builder with room for `capacity` octets before its first growth |
| `strbuilder` | `value struct { buf : builder }` | The type; a `bytes/builder` underneath |
| `length` | `(b : strbuilder) : int` | Octets accumulated so far, not characters |
| `is-empty` | `(b : strbuilder) : bool` | |
| `append` | `(b : strbuilder, s : string) : strbuilder` | |
| `append-char` | `(b : strbuilder, c : char) : strbuilder` | |
| `append-int` | `(b : strbuilder, i : int) : strbuilder` | |
| `append-bytes` | `(b : strbuilder, x : bytes) : strbuilder` | Octets straight through, no decode |
| `append-line` | `(b : strbuilder, s : string = "") : strbuilder` | `s` then `"\n"` |
| `append-join` | `(b : strbuilder, parts : list<string>, sep : string = "") : div strbuilder` | Each part with `sep` between |
| `append-json-escaped` | `(b : strbuilder, s : string) : div strbuilder` | RFC 8259 escaping, without the surrounding quotes |
| `append-json-string` | `(b : strbuilder, s : string) : div strbuilder` | The same, with the quotes |
| `finish` | `(b : strbuilder) : strbuilder-result` | The accumulated text.  The builder is left empty and can be reused |
| `finish-bytes` | `(b : strbuilder) : bytes` | The accumulated octets, without decoding |
| `build` | `(action : (strbuilder) -> e strbuilder, capacity : int = 256) : e string` | Build a string with `action`; the common shape |
| `strbuilder-result` | `alias = string` | What `finish` returns |

JSON escaping follows RFC 8259: the two mandatory escapes (`"` and `\`), the
short forms `\n \r \t \b \f`, and `\uXXXX` for the remaining characters below
U+0020.  `/` is not escaped, because escaping it is optional, and non-ASCII
characters are emitted as UTF-8 rather than as `\u` sequences, which is valid
JSON and much smaller.

## Complexity

| operation | cost |
| --- | --- |
| `append`, `append-bytes`, `append-char`, `append-int` | amortized O(1) in the appended length, so building an n-octet string is **O(n)** |
| `length`, `is-empty` | O(1) |
| `append-join` over `k` parts of total length `n` | O(n + k) |
| `append-json-escaped` over an m-character string | O(m), one pass |
| `finish`, `finish-bytes` | O(n) — one copy out of the buffer |
| `s := s ++ x` in a loop, the thing this replaces | **O(n²)** |

Measured on this machine (AMD Ryzen 9 5950X, 32 threads, 126 GiB, Linux 7.0.1
x86_64, Koka 3.2.7, `--release`, fastest of 3):

| what | n | ms | units/s |
| --- | ---: | ---: | ---: |
| builder `append` of a 10-char chunk | 2 000 000 | 60 | 33 333 333 |
| builder `append` of a 10-char chunk | 8 000 000 | 221 | 36 199 095 |
| naive `++` of a 10-char chunk | 20 000 | 30 | 666 666 |
| naive `++` of a 10-char chunk | 80 000 | 654 | 122 324 |
| `append-json-string`, 41-char value | 50 000 | 66 | 757 575 |
| `append-json-string`, 41-char value | 200 000 | 221 | 904 977 |

Four times the appends cost the builder 3.7x and naive `++` 22x.  That is the
whole claim, and it is why an absolute threshold is not enough to check it: at
n = 20 000 the quadratic version takes 30 ms, which any timeout would accept.

Reproduce with `./run-benchmarks.sh strbuilder` from the repository root.

## Worked example

```koka
import strbuilder/strbuilder

fun main()
  // The common shape: `build` hands you a builder and takes the string back.
  val csv = build fn(b)
    b.append-line("name,count")
     .append-join(["widget", "7"], ",").append-line()
     .append-join(["gadget", "12"], ",").append-line()
  print(csv)

  // Escaping, for a JSON writer.
  val line = build fn(b)
    b.append("{\"msg\":").append-json-string("he said \"hi\"\n").append("}")
  println(line)                  // {"msg":"he said \"hi\"\n"}

  // Threading the builder by hand, when the shape is not a single expression.
  var acc := strbuilder(64)
  var i := 0
  while { i < 3 }
    acc := acc.append-int(i).append(" ")
    i := i + 1
  println(acc.finish.trim)       // 0 1 2
```

## Limits

* **A builder is linear by convention, not by type.**  Every operation returns
  the builder and the previous value must not be used again; the buffer is
  mutated in place.  Writing

  ```koka
  val b1 = b.append("a")
  val b2 = b.append("b")     // WRONG: b was already consumed
  ```

  appends both to the same buffer.  Nothing detects this.  Thread the builder
  through, as every example here does.
* **`length` counts octets, not characters.**  `strbuilder().append("é").length`
  is 2.
* **`finish` empties the builder.**  That is deliberate — it makes reuse
  possible without another allocation — but it means calling `finish` twice
  gives you the text and then the empty string.
* **The only escaping is JSON's.**  No HTML, no URL, no shell, no CSV quoting.
  A caller that needs one of those should not reach for
  `append-json-escaped` because it is nearby.
* **`append-json-escaped` walks the string as a character list**, which
  allocates.  It is the reason a log record with eight escaped fields costs
  around 4 µs; see `logging`'s numbers.  Fixing it means an octet-level escape
  in `bytes`, which has not been done.
* **`finish` never produces invalid UTF-8**, because everything appended was
  either a `:string` or an escape sequence this module produced.  That holds
  only as long as `append-bytes` is fed valid UTF-8; it is the one door through
  which arbitrary octets enter, and `finish` decodes lossily rather than
  failing.
