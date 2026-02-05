use ev;
use ev::dial;
use fmt;
use io;
use net::ip;
use net::uri;
use os;
use strings;

type state = struct {
	loop: *ev::loop,
	uri: *uri::uri,
	exit: int,
	buf: [os::BUFSZ]u8,
	ioreq: ev::ioreq,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const uri = uri::parse(os::args[1])!;
	defer uri::finish(&uri);

	let state = state {
		loop = &loop,
		exit = os::status::SUCCESS,
		uri = &uri,
		buf = [0...],
		ioreq = @undefined,
	};

	let req = dial::dialreq_init(&loop, &state);
	match (dial::dial_uri(&req, "tcp", &uri, &on_connected)) {
	case let err: dial::error =>
		fmt::fatal(dial::strerror(err));
	case void => void;
	};

	ev::run(&loop)!;
	os::exit(state.exit);
};

fn on_connected(
	req: *dial::dialreq,
	r: (*ev::file | dial::error),
	user: nullable *opaque,
) void = {
	let state = user: *state;
	const file = match (r) {
	case let file: *ev::file =>
		yield file;
	case let err: dial::error =>
		fmt::errorln(dial::strerror(err))!;
		return;
	};

	const s = fmt::bsprintf(state.buf, "GET {} HTTP/1.1\r\n"
		"Host: {}\r\n"
		"Connection: close\r\n\r\n",
		if (state.uri.path == "") "/" else state.uri.path,
		match (state.uri.host) {
		case let s: str =>
			yield s;
		case let ip: ip::addr =>
			yield ip::string(ip);
		})!;

	state.ioreq = ev::ioreq_init(file, state);
	ev::write(&state.ioreq, state.buf[..len(s)], &on_write);
};

fn on_write(
	req: *ev::ioreq,
	r: (size | io::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;

	match (r) {
	case let err: io::error =>
		fmt::errorln(io::strerror(err))!;
		return;
	case size => void;
	};

	ev::read(&state.ioreq, state.buf, &on_read);
};

fn on_read(
	req: *ev::ioreq,
	r: (size | io::EOF | io::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;
	const n = match (r) {
	case let n: size =>
		yield n;
	case io::EOF =>
		return;
	case let err: io::error =>
		fmt::errorln(io::strerror(err))!;
		return;
	};
	io::writeall(os::stdout, state.buf[..n])!;
	ev::read(req, state.buf, &on_read);
};
