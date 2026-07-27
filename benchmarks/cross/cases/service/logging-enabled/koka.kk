import std/os/env
import logging/log

val max-repetitions : int = 10000000

val fields : list<field> =
  [ ("request-id", "r12345")
  , ("method", "GET")
  , ("path", "/items/42")
  , ("status", "200")
  , ("duration-ms", "3")
  , ("peer", "127.0.0.1:51234")
  , ("service", "notes")
  , ("cached", "true")
  ]

fun repetitions() : <ndet,exn> int
  match get-args()
    Cons(text, Nil) ->
      match text.parse-int
        Just(n) | n >= 0 && n <= max-repetitions -> n
        _ -> throw("repetitions must be an integer from 0 through " ++ max-repetitions.show)
    _ -> throw("usage: logging-enabled-koka REPETITIONS")

fun enabled( reps : int ) : io int
  val emitted = ref(0)
  with-json-logger(fn(line)
    if line.is-notempty then emitted := !emitted + 1
  , fn()
    fun go( remaining : int ) : <logger,io> ()
      if remaining <= 0 then ()
      else
        info("request", fields)
        go(remaining - 1)
    go(reps)
  )
  !emitted

fun main()
  println(enabled(repetitions()))
