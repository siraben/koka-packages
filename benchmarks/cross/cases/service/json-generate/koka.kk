import std/os/env
import json/value

val max-repetitions : int = 10000000

fun repetitions() : <ndet,exn> int
  match get-args()
    Cons(text, Nil) ->
      match text.parse-int
        Just(n) | n >= 0 && n <= max-repetitions -> n
        _ -> throw("repetitions must be an integer from 0 through " ++ max-repetitions.show)
    _ -> throw("usage: json-koka REPETITIONS")

fun generate( value : json, reps : int ) : io int
  fun go( remaining : int, checksum : int ) : io int
    if remaining <= 0 then checksum
    else go(remaining - 1, checksum + value.show.count)
  go(reps, 0)

fun main()
  val reps = repetitions()
  val value = JsArray(list(0, 1999).map(JsInt))
  println(generate(value, reps))
