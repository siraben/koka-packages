/* Temporary files and directories for tests.

   Cleanup runs on the success path, on an exception, and when the test
   framework's watchdog is *not* involved -- a killed process obviously cannot
   run cleanup, which is why the directories live under the system temporary
   directory where the OS will reclaim them.
*/
module kktest/tmp

import kktest/sys

// Run `action` with a fresh empty directory, removing it afterwards whether
// or not the action throws.
pub fun with-temp-dir( action : (string) -> io a, pre : string = "kktest" ) : io a
  val dir = make-temp-dir(pre)
  finally({ remove-tree(dir) }, { action(dir) })

// Run `action` with the path of a file inside a fresh temporary directory.
// The file itself is not created; the action decides whether to.
pub fun with-temp-file( action : (string) -> io a,
                        name : string = "tmp.dat", pre : string = "kktest" ) : io a
  with-temp-dir(fn(dir) action(dir ++ "/" ++ name), pre)
