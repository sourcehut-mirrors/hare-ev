use errors;
use ev;
use fmt;
use io;
use net;
use net::ip;
use os;

type state = struct {
	loop: *ev::loop,
	sock: *ev::file,
	stdbuf: [os::BUFSZ]u8,
	netbuf: [os::BUFSZ]u8,
	wbuf: []u8,
	read: ev::ioreq,
	write: ev::ioreq,
	readable: ev::pollreq,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	let state = state {
		loop = &loop,
		sock = null: *ev::file, // populated by [[connected]]
		read = ev::IOREQ_INIT,
		write = ev::IOREQ_INIT,
		readable = ev::POLLREQ_INIT,
		...
	};
	const stdin = ev::register(&loop, os::stdin_file)!;
	defer ev::unregister(stdin);
	state.readable = ev::pollreq_init(stdin, &state);

	const req = ev::connect_init(&loop, &state);
	match (ev::connect_tcp(&req, ip::LOCAL_V4, 12345, &connected)) {
	case let err: net::error =>
		fmt::fatal("Error: connect:", net::strerror(err));
	case let err: errors::error =>
		fmt::fatal("Error: connect:", errors::strerror(err));
	case =>
		yield;
	};

	ev::run(&loop)!;
};

fn connected(
	req: *ev::sockreq,
	result: (*ev::file | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;
	const sock = match (result) {
	case let err: net::error =>
		fmt::fatal("Error: connect:", net::strerror(err));
	case let sock: *ev::file =>
		yield sock;
	};
	ev::setuser(sock, state);
	state.sock = sock;

	state.read = ev::ioreq_init(state.sock, state);
	state.write = ev::ioreq_init(state.sock, state);
	ev::read(&state.read, state.netbuf, &sock_read);
	ev::readable(&state.readable, &stdin_readable);
};

fn stdin_readable(req: *ev::pollreq, user: nullable *opaque) void = {
	const state = user: *state;

	const n = match (io::read(os::stdin_file, state.stdbuf)) {
	case let n: size =>
		yield n;
	case io::EOF =>
		ev::stop(state.loop);
		return;
	case let err: io::error =>
		fmt::errorln("Error: read:", io::strerror(err))!;
		ev::stop(state.loop);
		return;
	};
	state.wbuf = state.stdbuf[..n];

	ev::write(&state.write, state.wbuf, &sock_write);
};

fn sock_read(
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
		fmt::errorln("Error: read:", io::strerror(err))!;
		ev::stop(state.loop);
		return;
	};
	io::write(os::stdout, state.netbuf[..n])!;
	ev::read(&state.read, state.netbuf, &sock_read);
};

fn sock_write(
	req: *ev::ioreq,
	r: (size | io::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;
	const n = match (r) {
	case let n: size =>
		yield n;
	case let err: io::error =>
		fmt::errorln("Error: read:", io::strerror(err))!;
		ev::stop(state.loop);
		return;
	};
	static delete(state.wbuf[..n]);
	if (len(state.wbuf) != 0) {
		ev::write(&state.write, state.wbuf, &sock_write);
	} else {
		ev::readable(&state.readable, &stdin_readable);
	};
};
