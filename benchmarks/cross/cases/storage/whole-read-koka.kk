import std/os/env
import bytes/bytes
import fileio/file

fun arguments() : io (int, string)
  val args = get-args()
  val reps = args.head("").parse-int.default(0)
  val path = args.drop(1).head("")
  if reps <= 0 then throw("repetitions must be positive")
  if path == "" then throw("fixture path is required")
  (reps, path)

fun run( path : string, reps : int ) : io (int, int)
  fun go( i : int, bytes-read : int, checksum : int ) : io (int, int)
    if i >= reps then (bytes-read, checksum)
    else
      val data = read-file(path, 64 * 1024 * 1024)
      val sum = data.length + data.at(0).default(0) +
                data.at(data.length - 1).default(0)
      go(i + 1, bytes-read + data.length, checksum + sum)
  go(0, 0, 0)

fun main()
  val (reps, path) = arguments()
  val (total-bytes, checksum) = run(path, reps)
  if total-bytes % reps != 0 then throw("inconsistent byte count")
  println("bytes=" ++ (total-bytes / reps).show ++
          " reps=" ++ reps.show ++
          " checksum=" ++ checksum.show)
