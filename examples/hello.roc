# example application
app [main] { pf: platform "main.roc" }

import pf.Stdout

main = Stdout.line "Roc loves Zig"
