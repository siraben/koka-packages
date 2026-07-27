import std/os/env
import bytes/bytes

val appends-per-repetition : int = 80000
val output-size : int = 800000
val checksum-multiplier : int = 1000003
val checksum-modulus : int = 1000000007

fun requested-work() : ndet int
  match get-args()
    Cons(s, _) -> max(0, s.parse-int.default(1))
    Nil -> 1

fun one-repetition() : div int
  val chunk = bytes("0123456789")
  var out := builder-empty(output-size)
  var i := 0
  while { i < appends-per-repetition }
    out := out.snoc(chunk)
    i := i + 1
  val n = out.length
  val result = out.finish
  n + (if result.is-empty then 0 else 1)

fun main()
  val work = requested-work()
  var checksum := 0
  var rep := 0
  while { rep < work }
    checksum := (checksum * checksum-multiplier + one-repetition()) %
                checksum-modulus
    rep := rep + 1
  println(checksum)
