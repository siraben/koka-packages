import std/os/env
import json/value
import json/parse

val max-repetitions : int = 1000000

fun repetitions() : <ndet,exn> int
  match get-args()
    Cons(text, Nil) ->
      match text.parse-int
        Just(n) | n >= 0 && n <= max-repetitions -> n
        _ -> throw("repetitions must be an integer from 0 through " ++ max-repetitions.show)
    _ -> throw("usage: json-parse-koka REPETITIONS")

fun parse-loop( document : string, reps : int ) : io int
  fun go( remaining : int, checksum : int ) : io int
    if remaining <= 0 then checksum
    else match parse-string(document)
      Right(JsArray(Cons(_, _))) -> go(remaining - 1, checksum + 1)
      Right(_) -> throw("parsed JSON was not a non-empty array")
      Left(e)  -> throw(e.show)
  go(reps, 0)

fun main()
  val reps = repetitions()
  val document = JsArray(list(0, 1999).map(JsInt)).show
  println(parse-loop(document, reps))
