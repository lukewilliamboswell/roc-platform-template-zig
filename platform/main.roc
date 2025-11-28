platform ""
    requires {} { main! : List(Str) => I32 }
    exposes [Stdout, Stderr, Stdin]
    packages {}
    provides { main_for_host! }

import Stdout
import Stderr
import Stdin

main_for_host! : List(Str) => I32
main_for_host! = |args| main!(args)
