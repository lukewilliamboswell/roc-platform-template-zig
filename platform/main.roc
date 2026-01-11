platform ""
	requires {
		[Model : model] for program : {
			init! : () => Try(model, [Exit(I64), ..]),
			render! : model => Try(model, [Exit(I64), ..]),
		}
	}
	exposes []
	packages {}
	provides {
		init_for_host!: "init_for_host",
		render_for_host!: "render_for_host",
	}
	targets: {
		files: "targets/",
		exe: {
			x64linux: ["libhost.a", "libraylib.a", app],
			arm64linux: ["libhost.a", "libraylib.a", app],
			x64mac: ["libhost.a", "libraylib.a", app],
			arm64mac: ["libhost.a", "libraylib.a", app],
			x64win: ["libhost.a", "libraylib.a", app],
			arm64win: ["libhost.a", "libraylib.a", app],
		}
	}

init_for_host! : {} => Try(Box(Model), I64)
init_for_host! = |{}| match (program.init!)() {
	Ok(unboxed_model) => Ok(Box.box(unboxed_model))
	Err(Exit(code)) => Err(code)
	Err(_) => Err(-1)
}

render_for_host! : Box(Model) => Try(Box(Model), I64)
render_for_host! = |boxed_model| match (program.render!)(Box.unbox(boxed_model)) {
	Ok(unboxed_model) => Ok(Box.box(unboxed_model))
	Err(Exit(code)) => Err(code)
	Err(_) => Err(-1)
}
