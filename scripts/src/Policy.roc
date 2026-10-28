## Pure repository policy: which tracked files are compiled artifacts.
Policy := [].{

	## Whether a tracked file is a compiled artifact, by its name or by the
	## first bytes of its contents: ELF, PE, ar archives, WebAssembly, Mach-O
	## and universal binaries.
	compiled : Str, List(U8) -> Bool
	compiled = |path, header|
		suffixes.any(|suffix| path.ends_with(suffix)) or magic.any(|prefix| header.starts_with(prefix))
}

suffixes : List(Str)
suffixes = [".o", ".obj", ".a", ".lib", ".dll", ".so", ".dylib", ".exe", ".wasm"]

magic : List(List(U8))
magic = [
	[0x7f, 'E', 'L', 'F'],
	['M', 'Z'],
	Str.to_utf8("!<arch>\n"),
	Str.to_utf8("!<thin>\n"),
	[0, 'a', 's', 'm'],
	[0xfe, 0xed, 0xfa, 0xce],
	[0xce, 0xfa, 0xed, 0xfe],
	[0xfe, 0xed, 0xfa, 0xcf],
	[0xcf, 0xfa, 0xed, 0xfe],
	[0xca, 0xfe, 0xba, 0xbe],
]

expect Policy.compiled("platform/targets/x64musl/libhost.a", [])
expect Policy.compiled("tool", [0x7f, 'E', 'L', 'F', 2, 1, 1, 0])
expect Policy.compiled("x", Str.to_utf8("!<arch>\nab"))
expect !Policy.compiled("scripts/check_all.roc", Str.to_utf8("#!/usr/"))
expect !Policy.compiled("README.md", Str.to_utf8("# Roc"))
