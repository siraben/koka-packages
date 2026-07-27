import std/os/env
import bytes/bytes
import http/message

val max-repetitions : int = 10000000

val request-wire : bytes = bytes(
  "POST /items/42?verbose=1 HTTP/1.1\r\n" ++
  "host: example.test\r\n" ++
  "content-type: text/plain\r\n" ++
  "content-length: 11\r\n" ++
  "connection: close\r\n\r\n" ++
  "hello world")

fun repetitions() : <ndet,exn> int
  match get-args()
    Cons(text, Nil) ->
      match text.parse-int
        Just(n) | n >= 0 && n <= max-repetitions -> n
        _ -> throw("repetitions must be an integer from 0 through " ++ max-repetitions.show)
    _ -> throw("usage: http-koka REPETITIONS")

fun exchange-loop( reps : int ) : io int
  fun go( remaining : int, checksum : int ) : io int
    if remaining <= 0 then checksum
    else match parse(request-wire)
      Parsed(req, rest) ->
        if rest.is-notempty then throw("request parser left trailing input")
        val response-body = bytes("accepted")
        val rendered = response(201, response-body,
          [("content-type", "text/plain"), ("x-request-id", "r12345")]).render(False)
        val marker = if rendered.is-notempty then 1 else 0
        val item = req.method.count + req.path.count + req.query.count +
                   req.body.length + 201 + response-body.length + marker
        go(remaining - 1, checksum + item)
      Incomplete -> throw("complete request parsed as incomplete")
      Failed(e)  -> throw(e.message)
  go(reps, 0)

fun main()
  println(exchange-loop(repetitions()))
