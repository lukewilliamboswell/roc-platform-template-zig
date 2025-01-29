# App stub, used to create a prebuilt surgical host
app [main!] { pf: platform "../platform/main.roc" }

main! : {} => Result {} _
main! = |{}| Ok({})
