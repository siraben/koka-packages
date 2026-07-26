import kktest/assert

fun main()
  assert-true(True)
  assert-false(False)
  assert-equal(1 + 1, 2)
  assert-not-equal("a", "b")
  assert-throws({ throw("boom") }, containing = "boom")
  val x = assert-ok({ 42 })
  assert-equal(x, 42)
  println("assert ok")
