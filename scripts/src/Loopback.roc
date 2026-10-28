# Vendored from lukewilliamboswell/roc-automation, formatted by roc-stable, at
# a25b5129340b9b2ad1744d20330b8ee4d38a1849/scripts/src/Loopback.roc.
import cli.Cmd
import cli.Path
import cli.Tcp

## Serves a release's bundles from 127.0.0.1.
##
## Roc fetches a package dependency by URL while it compiles. Serving the exact
## archives a release would publish lets the archived examples be tested against
## them, with `--replace-dep`, before any release exists.
Loopback := [].{

	## A running server: the files `run!` answers requests with, and the base
	## of the URLs that stand in for the release URLs while it runs.
	Server : { listener : Tcp.Listener, files : List({ name : Str, bytes : List(U8) }), base : Str }

	## Read each bundle and start listening on a free port.
	start! : List(Path) => Try(Server, Str)
	start! = |bundles| {
		files = bundles.map_try!(
			|bundle| {
				bytes = Path.read_bytes!(bundle).map_err(|_| "cannot read ${Path.display(bundle)} to serve it")?
				name = Path.filename(bundle).map_ok(Path.display).map_err(|_| "${Path.display(bundle)} has no file name")?
				Ok({ name, bytes })
			},
		)?
		if files.is_empty() {
			return Err("nothing to serve")
		}
		listener = Tcp.listen!("127.0.0.1", 0, 5_000).map_err(|_| "cannot listen on a loopback port")?
		port = listener.local_port!().map_err(|_| "cannot read the loopback port")?
		Ok({ listener, files, base: "http://127.0.0.1:${port.to_str()}" })
	}

	## The URL the server answers for the bundle named `name`.
	url : Server, Str -> Str
	url = |server, name| "${server.base}/${name}"

	## Run `command` to completion with captured output, answering every
	## connection made in the meantime. The command's own timeout and output
	## limit still apply, and end the run as they would under `Cmd.run!`; a
	## failure of the server itself is `Serve`.
	run! = |server, command| {
		child = command.stdout(Capture).stderr(Capture).spawn!().map_err(|err| IO(err))?
		serve_until_exit!(child, server)
	}

	## Stop listening.
	stop! : Server => Try({}, Str)
	stop! = |server| server.listener.close!().map_err(|_| "cannot close the loopback listener")
}

# This process must answer the child's request and notice the child exiting,
# without threads. A short accept timeout alternates between the two.
serve_until_exit! = |child, server|
	match child.try_wait!() {
		Ok([output, ..]) => Ok(output)
		Ok([]) =>
			match server.listener.accept!(100) {
				Ok(stream) => {
					request = stream.read_until!('\n', 65_536, 5_000).map_err(|_| Serve("cannot read the request"))?
					match server.files.keep_if(|file| file.name == requested(Str.from_utf8_lossy(request))) {
						[file] => {
							stream.write_utf8!(response_headers(file.bytes.len()), 5_000).map_err(|_| Serve("cannot write the response headers"))?
							stream.write!(file.bytes, 30_000).map_err(|_| Serve("cannot write the bundle"))?
						}
						_ => stream.write_utf8!(not_found, 5_000).map_err(|_| Serve("cannot write the response headers"))?
					}
					serve_until_exit!(child, server)
				}
				Err(TcpListenErr(TimedOut)) => serve_until_exit!(child, server)
				Err(_) => Err(Serve("cannot accept a connection"))
			}
		Err(Timeout(partial)) => Err(Timeout(partial))
		Err(OutputLimit(partial)) => Err(OutputLimit(partial))
		Err(IO(err)) => Err(IO(err))
	}

# The file a request line such as `GET /Abc.tar.zst HTTP/1.1` asks for.
requested = |line|
	match Str.split_on(line.trim(), " ") {
		[_, path, ..] => path.drop_prefix("/")
		_ => ""
	}

# HTTP separates header lines with CRLF.
response_headers = |content_length|
	Str.join_with(
		[
			"HTTP/1.1 200 OK",
			"Content-Type: application/octet-stream",
			"Content-Length: ${content_length.to_str()}",
			"Connection: close",
			"",
			"",
		],
		"\r\n",
	)

not_found = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

expect response_headers(12) == "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: 12\r\nConnection: close\r\n\r\n"
expect requested("GET /Abc.tar.zst HTTP/1.1\r\n") == "Abc.tar.zst" and requested("") == ""
