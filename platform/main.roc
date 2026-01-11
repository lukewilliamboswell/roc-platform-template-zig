platform ""
	requires {
		[Model : model] for program : {
			init! : () => Try(model, [Exit(I64), ..]),
			render! : model, PlatformState => Try(model, [Exit(I64), ..]),
		}
	}
	exposes [Draw, Color, PlatformState]
	packages {}
	provides {
		init_for_host!: "init_for_host",
		render_for_host!: "render_for_host",
	}
	targets: {
		files: "targets/",
		exe: {
			x64mac: ["libhost.a", "libraylib.a", app],
			arm64mac: ["libhost.a", "libraylib.a", app],
		}
	}

import Draw
import Color
import PlatformState

## Internal type for host boundary - kept simple for C compatibility
PlatformStateFromHost : {
	frame_count : U64,
}

init_for_host! : {} => Try(Box(Model), I64)
init_for_host! = |{}| match (program.init!)() {
	Ok(unboxed_model) => Ok(Box.box(unboxed_model))
	Err(Exit(code)) => Err(code)
	Err(_) => Err(-1)
}

render_for_host! : Box(Model), PlatformStateFromHost => Try(Box(Model), I64)
render_for_host! = |boxed_model, host_state| {
	platform_state : PlatformState
	platform_state = {
		frame_count: host_state.frame_count,
	}
	match (program.render!)(Box.unbox(boxed_model), platform_state) {
		Ok(unboxed_model) => Ok(Box.box(unboxed_model))
		Err(Exit(code)) => Err(code)
		Err(_) => Err(-1)
	}
}
