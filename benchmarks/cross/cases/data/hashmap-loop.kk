import std/os/env
import hashmap/map

val value-modulus : int = 1000003

fun int/hash( i : int ) : int
  i

fun requested-work() : ndet int
  match get-args()
    Cons(s, _) -> max(0, s.parse-int.default(1))
    Nil -> 1

fun main()
  val work = requested-work()
  var entries : hmap<int,int> := map/empty()
  var i := 0
  while { i < work }
    entries := entries.insert(i, (17 * i + 3) % value-modulus)
    i := i + 1

  var checksum := 0
  i := work - 1
  while { i >= 0 }
    match entries.lookup(i)
      Just(value) -> checksum := checksum + value
      Nothing -> ()
    i := i - 1
  println(checksum)
