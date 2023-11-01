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
	};

	dial::dial_uri(&loop, "tcp", &uri, &dialcb, &state)!;

	for (ev::dispatch(&loop, -1)!) void;

	os::exit(state.exit);
};

fn error(state: *state, details: str) void = {
	fmt::errorfln("Error: {}", details)!;
	state.exit = os::status::FAILURE;
	ev::stop(state.loop);
};

fn dialcb(user: nullable *opaque, r: (*ev::file | dial::error)) void = {
	let state = user: *state;
	const file = match (r) {
	case let file: *ev::file =>
		yield file;
	case let err: dial::error =>
		error(state, dial::strerror(err));
		return;
	};
	ev::setuser(file, state);
	const s = fmt::bsprintf(state.buf, "GET {} HTTP/1.1\r\n"
		"Host: {}\r\n"
		"Connection: close\r\n\r\n",
		if (state.uri.path == "") "/" else state.uri.path,
		match (state.uri.host) {
		case let s: str =>
			yield s;
		case let ip: ip::addr =>
			yield ip::string(ip);
		});

	ev::write(file, &writecb, state.buf[..len(s)]);
};

fn writecb(file: *ev::file, r: (size | io::error)) void = {
	const state = ev::getuser(file): *state;
	const z = match (r) {
	case let z: size =>
		yield z;
	case let err: io::error =>
		error(state, io::strerror(err));
		return;
	};
	ev::read(file, &readcb, state.buf);
};

fn readcb(file: *ev::file, r: (size | io::EOF | io::error)) void = {
	const state = ev::getuser(file): *state;
	const z = match (r) {
	case let z: size =>
		yield z;
	case io::EOF =>
		ev::stop(state.loop);
		return;
	case let err: io::error =>
		error(state, io::strerror(err));
		return;
	};
	io::writeall(os::stdout, state.buf[..z])!;
	ev::read(file, &readcb, state.buf);
};
