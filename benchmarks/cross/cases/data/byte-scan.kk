import std/os/env
import bytes/bytes

val segment-size : int = 32768
val segment-count : int = 256
val input-size : int = 8388608
val checksum-multiplier : int = 1000003
val checksum-modulus : int = 1000000007

fun requested-work() : ndet int
  match get-args()
    Cons(s, _) -> max(0, s.parse-int.default(1))
    Nil -> 1

fun scan( input : bytes, delimiter : bytes, from : int = 0,
          total : int = 0 ) : div int
  match input.index-of(delimiter, from)
    Nothing -> total
    Just(i) -> scan(input, delimiter, i + 1, total + i + 1)

fun main()
  val segment = bytes/replicate(97, segment-size - 1) ++ bytes("|")
  var input-builder := builder-empty(input-size)
  var segment-index := 0
  while { segment-index < segment-count }
    input-builder := input-builder.snoc(segment)
    segment-index := segment-index + 1
  val input = input-builder.finish
  val delimiter = bytes("|")

  var checksum := 0
  var rep := 0
  val work = requested-work()
  while { rep < work }
    checksum := (checksum * checksum-multiplier + input.scan(delimiter)) %
                checksum-modulus
    rep := rep + 1
  println(checksum)
