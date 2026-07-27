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
| `is-empty` / `is-notempty` | `(b : strbuilder) : bool` | |
| `reserve` | `(b : strbuilder, n : int) : strbuilder` | Ensure capacity for `n` more octets |
| `append` | `(b : strbuilder, s : string) : strbuilder` | |
| `append-char` | `(b : strbuilder, c : char) : strbuilder` | |
| `append-int` | `(b : strbuilder, i : int) : strbuilder` | |
| `append-show` | `(b : strbuilder, x : a, ?show) : div strbuilder` | Append any showable value |
| `append-bytes` | `(b : strbuilder, x : bytes) : strbuilder` | Octets straight through, no decode |
| `append-line` | `(b : strbuilder, s : string = "") : strbuilder` | `s` then `"\n"` |
| `append-lines` | `(b : strbuilder, parts : list<string>) : div strbuilder` | Every part followed by `"\n"` |
| `append-join` | `(b : strbuilder, parts : list<string>, sep : string = "") : div strbuilder` | Each part with `sep` between |
| `append-repeat` | `(b : strbuilder, s : string, n : int) : div strbuilder` | Repeat `s`; non-positive counts do nothing |
| `append-if` | `(b : strbuilder, condition : bool, s : string) : strbuilder` | Conditional append |
| `append-json-escaped` | `(b : strbuilder, s : string) : div strbuilder` | RFC 8259 escaping, without the surrounding quotes |
| `append-json-string` | `(b : strbuilder, s : string) : div strbuilder` | The same, with the quotes |
| `finish` | `(b : strbuilder) : strbuilder-result` | The accumulated text.  The builder is left empty and can be reused |
| `finish-checked` | `(b : strbuilder) : maybe<string>` | Strict UTF-8 decode; rejects invalid `append-bytes` input |
| `finish-bytes` | `(b : strbuilder) : bytes` | The accumulated octets, without decoding |
| `build` | `(action : (strbuilder) -> e strbuilder, capacity : int = 256) : e string` | Build a string with `action`; the common shape |
| `build-bytes` | `(action : (strbuilder) -> e strbuilder, capacity : int = 256) : e bytes` | Build without decoding |
| `strbuilder-result` | `alias = string` | What `finish` returns |

JSON escaping follows RFC 8259: the two mandatory escapes (`"` and `\`), the
short forms `\n \r \t \b \f`, and `\uXXXX` for the remaining characters below
U+0020.  `/` is not escaped, because escaping it is optional, and non-ASCII
characters are emitted as UTF-8 rather than as `\u` sequences, which is valid
JSON and much smaller.

## Complexity

| operation | cost |
| --- | --- |
| `append`, `append-bytes`, `append-char`, `append-int`, `append-show` | amortized O(1) in the appended length, so building an n-octet string is **O(n)** |
| `length`, `is-empty` | O(1) |
| `append-join`, `append-lines`, `append-repeat` over total output `n` | O(n) |
| `append-json-escaped` over an m-character string | O(m), one pass |
| `finish`, `finish-bytes` | O(n) — one copy out of the buffer |
| `s := s ++ x` in a loop, the thing this replaces | **O(n²)** |

Measured on this machine (AMD Ryzen 9 5950X, 32 threads, 126 GiB, Linux 7.0.1
x86_64, Koka 3.2.7, `--release`, fastest of 3):

| what | n | ms | units/s |
| --- | ---: | ---: | ---: |
| builder `append` of a 10-char chunk | 2 000 000 | 48 | 41 666 666 |
| builder `append` of a 10-char chunk | 8 000 000 | 188 | 42 553 191 |
| naive `++` of a 10-char chunk | 20 000 | 28 | 714 285 |
| naive `++` of a 10-char chunk | 80 000 | 553 | 144 665 |
| `append-json-string`, 41-char value | 50 000 | 36 | 1 388 888 |
| `append-json-string`, 41-char value | 200 000 | 145 | 1 379 310 |

Four times the appends cost the builder 3.9x and naive `++` 20x.  That is the
whole claim, and it is why an absolute threshold is not enough to check it: at
n = 20 000 the quadratic version takes 28 ms, which any timeout would accept.

The escaping row is a value of which a quarter needs escaping.  Characters that
do not are appended a run at a time rather than one at a time, because each
append crosses into C: that is worth about 25% here and more on a value that
needs no escaping at all, which is the common one.

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
  allocates a cell per character even though it now crosses into C once per
  run of unescaped characters rather than once per character.  Removing the
  character list means an octet-level escape in `bytes`, which has not been
  done — `bytes` has no per-octet primitive a Koka loop could drive without
  paying for a call per octet, and adding a JSON escaper to it would put a
  text-format concern in a package that deliberately has none.  `logging`'s
  README quotes a cost per log record that was measured before this change.
* **`finish` can produce U+FFFD.**  Everything `append`, `append-char`,
  `append-int`, `append-show`, `append-line`, `append-lines`, `append-join` and
  the escapers put in the buffer is a `:string` or an escape sequence this
  module produced, so it is valid UTF-8.  `append-bytes` is the exception: it
  takes arbitrary octets and does not check them, and `finish` decodes
  lossily.  Use `finish-checked` to reject invalid text, or `finish-bytes` when
  every octet must survive.
