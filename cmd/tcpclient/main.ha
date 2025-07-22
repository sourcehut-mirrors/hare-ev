use errors;
use ev;
use fmt;
use io;
use net;
use net::ip;
use os;

type state = struct {
	loop: *ev::loop,
	stdin: *ev::file,
	stdout: *ev::file,
	sock: *ev::file,
	stdbuf: [os::BUFSZ]u8,
	netbuf: [os::BUFSZ]u8,
	wbuf: []u8,
	read: ev::ioreq,
	write: ev::ioreq,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	let state = state {
		loop = &loop,
		stdin = ev::register(&loop, os::stdin_file)!,
		stdout = ev::register(&loop, os::stdout_file)!,
		sock = null: *ev::file, // populated by [[connected]]
		read = ev::IOREQ_INIT,
		write = ev::IOREQ_INIT,
		...
	};
	ev::setuser(state.stdin, &state);
	ev::setuser(state.stdout, &state);

	const req = ev::connect_init(&loop, &state);
	match (ev::connect_tcp(&req, ip::LOCAL_V4, 12345, &connected)) {
	case let err: net::error =>
		fmt::fatal("Error: connect:", net::strerror(err));
	case let err: errors::error =>
		fmt::fatal("Error: connect:", errors::strerror(err));
	case =>
		yield;
	};

	for (ev::dispatch(&loop, -1)!) void;
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

	ev::readable(state.stdin, &stdin_readable);

	state.read = ev::ioreq_init(state.sock, state);
	state.write = ev::ioreq_init(state.sock, state);
	ev::read(&state.read, state.netbuf, &sock_read);
};

fn stdin_readable(file: *ev::file) void = {
	const state = ev::getuser(file): *state;
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
		ev::stop(state.loop);
		return;
	case let err: io::error =>
		fmt::errorln("Error: read:", io::strerror(err))!;
		ev::stop(state.loop);
		return;
	};
	io::write(os::stdout_file, state.netbuf[..n])!;
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
		ev::readable(state.stdin, &stdin_readable);
	};
};
