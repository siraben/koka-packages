import kktest/assert
import kktest/runner
import bytes/bytes
import runtime/loop
import runtime/task
import runtime/net
import runtime/channel

fun collect() : io ref<global, list<string>>
  ref([])

fun note( l : ref<global, list<string>>, s : string ) : io ()
  l := Cons(s, !l)

fun events( l : ref<global, list<string>> ) : io list<string>
  (!l).reverse

// Index of `needle` in `hay`, or -1.  (`index-of` in scope is ambiguous
// between the bytes and list versions.)
fun position-of( hay : string, needle : string ) : div int
  match bytes(hay).bytes/index-of(bytes(needle))
    Just(i) -> i
    Nothing -> -1

fun read-int( r : ref<global,int> ) : io int
  !r

fun bump( r : ref<global,int> ) : io ()
  r := !r + 1

// ---------------------------------------------------------------------------
// An echo server: accept `n` connections, echo one message on each, then stop.
// ---------------------------------------------------------------------------

fun echo-once( s : socket ) : <async|io> ()
  with-socket(s) fn(sock)
    val data = sock.read(4096)
    if data.is-notempty then sock.write(data)

fun serve-echo( l : listener, n : int ) : <async|io> ()
  if n <= 0 then ()
  else
    val s = accept(l)
    spawn(fn() echo-once(s))
    serve-echo(l, n - 1)

fun echo-roundtrip( message : string ) : io string
  with-listener fn(l)
    val p = l.port
    with-task-group fn(_g)
      spawn(fn() serve-echo(l, 1))
      with-connection("127.0.0.1", p) fn(sock)
        sock.write-string(message)
        sock.read(4096).to-string-lossy

fun many-clients( n : int ) : io int
  with-listener fn(l)
    val p = l.port
    with-task-group fn(_g)
      val ok = ref(0)
      spawn(fn() serve-echo(l, n))
      run-clients(n, p, ok)
      read-int(ok)

fun run-clients( n : int, p : int, ok : ref<global,int> ) : <async|io> ()
  if n <= 0 then ()
  else
    with-connection("127.0.0.1", p) fn(sock)
      sock.write-string("ping")
      val r = sock.read(4096)
      if r.to-string-lossy == "ping" then bump(ok)
    run-clients(n - 1, p, ok)

fun disconnect-is-end-of-stream() : io string
  with-listener fn(l)
    val p = l.port
    with-task-group fn(_g)
      val got = ref("")
      spawn(fn()
        val s = accept(l)
        with-socket(s) fn(sock)
          // the client closes without sending, so the read must report end of
          // stream rather than hang
          val d = sock.read(1024)
          val label = if d.is-empty then "eof" else "data"
          got := label
      )
      val c = net/connect("127.0.0.1", p)
      c.close
      sleep(80)
      !got

fun accept-times-out() : io string
  with-listener fn(l)
    with-task-group fn(_g)
      match accept-within(l, 40)
        Nothing -> "timed out"
        Just(s) -> { s.close; "accepted" }

fun read-times-out() : io string
  with-listener fn(l)
    val p = l.port
    with-task-group fn(_g)
      val out = ref("")
      spawn(fn()
        val s = accept(l)
        with-socket(s) fn(_sock)
          // never send anything, so the client's read must time out
          sleep(200)
      )
      with-connection("127.0.0.1", p) fn(c)
        val label = match c.read-within(40, 1024)
                      Nothing -> "timed out"
                      Just(_) -> "read"
        out := label
      !out

fun cancel-during-accept() : io string
  val l = collect()
  match try({ run-cancel-accept(l) })
    Error(ex) -> if is-cancellation(ex) then l.events.join(",") else throw-exn(ex)
    Ok(_)     -> l.events.join(",")

fun run-cancel-accept( l : ref<global, list<string>> ) : io ()
  with-listener fn(lst)
    with-task-group fn(g)
      spawn(fn()
        l.note("accepting")
        defer({ l.note("cleanup") })
        accept(lst)
        ()
      )
      sleep(30)
      g.cancel
      yield()

fun server-shutdown-closes-listener() : io bool
  val p = with-listener(fn(l) l.port)
  // the listener is closed by with-listener; connecting must now fail
  with-task-group fn(_g)
    match try({ net/connect("127.0.0.1", p) })
      Error(_) -> True
      Ok(s)    -> { s.close; False }

// ---------------------------------------------------------------------------
// channels
// ---------------------------------------------------------------------------

fun channel-order() : io string
  with-task-group fn(_g)
    val c : channel<int> = channel(4)
    c.send(1)
    c.send(2)
    c.send(3)
    val a = c.receive.default(-1)
    val b = c.receive.default(-1)
    val d = c.receive.default(-1)
    [a, b, d].show

fun channel-backpressure() : io string
  val l = collect()
  with-task-group fn(_g)
    val c : channel<int> = channel(2)
    spawn(fn()
      // the third send must not *complete* until the consumer drains, so the
      // note goes after the send
      c.send(1); l.note("sent 1")
      c.send(2); l.note("sent 2")
      c.send(3); l.note("sent 3")
    )
    yield()
    l.note("consumer starts")
    c.receive
    c.receive
    c.receive
    sleep(20)
    l.events.join(",")

fun channel-close-drains() : io string
  with-task-group fn(_g)
    val c : channel<int> = channel(4)
    c.send(1)
    c.send(2)
    c.close
    val a = c.receive.default(-1)
    val b = c.receive.default(-1)
    val e = match c.receive
              Nothing -> -99
              Just(x) -> x
    [a, b, e].show

fun channel-send-after-close() : io bool
  with-task-group fn(_g)
    val c : channel<int> = channel(2)
    c.close
    match try({ c.send(1) })
      Error(_) -> True
      Ok(_)    -> False

fun main()
  run-tests([
    group("tcp", [
      test("echo round trip", fn()
        assert-equal(echo-roundtrip("hello"), "hello")
      , timeout-s = 30),
      test("binary payloads survive", fn()
        assert-equal(echo-roundtrip("a\tb c"), "a\tb c")
      , timeout-s = 30),
      test("multiple clients", fn()
        assert-equal(many-clients(20), 20)
      , timeout-s = 60),
      test("a client disconnect reports end of stream", fn()
        assert-equal(disconnect-is-end-of-stream(), "eof")
      , timeout-s = 30),
      test("accept honours a deadline", fn()
        assert-equal(accept-times-out(), "timed out")
      , timeout-s = 30),
      test("read honours a deadline", fn()
        assert-equal(read-times-out(), "timed out")
      , timeout-s = 30),
      test("cancelling during accept runs cleanup", fn()
        val e = cancel-during-accept()
        assert-true(e.contains("accepting"), e)
        assert-true(e.contains("cleanup"), "cleanup did not run: " ++ e)
      , timeout-s = 30),
      test("closing the listener stops new connections", fn()
        assert-true(server-shutdown-closes-listener())
      , timeout-s = 30),
    ]),

    group("channels", [
      test("first in, first out", fn()
        assert-equal(channel-order(), [1,2,3].show)
      , timeout-s = 30),
      test("a full channel blocks the producer", fn()
        val e = channel-backpressure()
        // the third send must not complete before the consumer starts
        val send3 = position-of(e, "sent 3")
        val cons  = position-of(e, "consumer starts")
        assert-true(send3 > cons,
                    "the producer did not wait for the consumer: " ++ e)
      , timeout-s = 30),
      test("closing does not discard buffered items", fn()
        assert-equal(channel-close-drains(), [1,2,-99].show)
      , timeout-s = 30),
      test("sending to a closed channel raises", fn()
        assert-true(channel-send-after-close())
      , timeout-s = 30),
      test("capacity must be positive", fn()
        assert-throws({ val c : channel<int> = channel(0); () },
                      containing = "capacity")
      ),
    ]),
  ])
