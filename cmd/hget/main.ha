use ev;
use ev::dial;
use fmt;
use io;
use net::uri;
use os;
use strings;

type state = struct {
	loop: *ev::loop,
	exit: int,
	buf: []u8,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	let state = state {
		loop = &loop,
		exit = os::status::SUCCESS,
		buf = [],
	};

	const uri = net::uri::parse("http://example.org")!;
	defer uri::finish(&uri);

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
	state.buf = strings::toutf8("GET / HTTP/1.1\r\n"
		"Host: example.org\r\n"
		"Connection: close\r\n\r\n");
	ev::write(file, &writecb, state.buf);
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
	assert(z == len(state.buf));
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
