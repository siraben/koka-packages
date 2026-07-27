import std/os/env
import runtime/loop
import runtime/task
import runtime/channel

val max-handoffs : int = 10000000

fun handoffs() : <ndet,exn> int
  match get-args()
    Cons(text, Nil) ->
      match text.parse-int
        Just(n) | n >= 0 && n <= max-handoffs -> n
        _ -> throw("handoffs must be an integer from 0 through " ++ max-handoffs.show)
    _ -> throw("usage: channel-koka HANDOFFS")

fun produce( c : channel<int>, next : int, count : int ) : <async|io> ()
  if next >= count then c.close
  else
    c.send(next)
    produce(c, next + 1, count)

fun consume( c : channel<int>, checksum : int ) : <async|io> int
  match c.receive
    Just(value) -> consume(c, checksum + value)
    Nothing    -> checksum

fun run-channel( count : int ) : io int
  with-task-group fn(_group)
    val c : channel<int> = channel(256)
    spawn(fn() produce(c, 0, count))
    consume(c, 0)

fun main()
  println(run-channel(handoffs()))
