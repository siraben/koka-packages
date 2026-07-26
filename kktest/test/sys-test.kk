import kktest/sys

fun main()
  val t0 = mono-ms()
  val d = make-temp-dir("kktest-selftest")
  if !path-exists(d) then throw("temp dir was not created")
  remove-tree(d)
  if path-exists(d) then throw("temp dir was not removed")
  val t1 = mono-ms()
  if t1 < t0 then throw("monotonic clock went backwards")
  println("sys ok")
