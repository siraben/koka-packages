import std/os/env
import resource/scope
import fileio/file
import bytes/bytes

fun arguments() : io (int, string)
  val args = get-args()
  val scopes = args.head("").parse-int.default(0)
  val path = args.drop(1).head("")
  if scopes <= 0 then throw("scope count must be positive")
  if path == "" then throw("fixture path is required")
  (scopes, path)

fun run( path : string, scopes : int ) : io int
  fun go( i : int, checksum : int ) : io int
    if i >= scopes then checksum
    else
      val n = with-resource({ open(path) }, close, fn(f) f.read(1).length)
      go(i + 1, checksum + n)
  go(0, 0)

fun main()
  val (scopes, path) = arguments()
  val checksum = run(path, scopes)
  println("scopes=" ++ scopes.show ++
          " bytes=" ++ checksum.show ++
          " checksum=" ++ checksum.show)
