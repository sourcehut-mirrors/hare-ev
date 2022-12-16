// TODO: Update me when we can send/recv in parallel
use ev;
use fmt;
use io;
use net::ip;
use net;
use os;

type state = struct {
	loop: *ev::loop,
	stdin: *ev::file,
	stdout: *ev::file,
	sock: *ev::file,
	stdbuf: [os::BUFSIZ]u8,
	netbuf: [os::BUFSIZ]u8,
	wbuf: []u8,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const sock = ev::connect_udp(&loop, ip::LOCAL_V4, 12345)!;
	defer ev::close(sock);

	let state = state {
		loop = &loop,
		stdin = ev::register(&loop, os::stdin_file)!,
		stdout = ev::register(&loop, os::stdout_file)!,
		sock = sock,
		...
	};
	ev::setuser(state.stdin, &state);
	ev::setuser(state.stdout, &state);
	ev::setuser(state.sock, &state);

	ev::readable(state.stdin, &stdin_readable);

	for (ev::dispatch(&loop, -1)!) void;
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
	ev::send(state.sock, &sock_send, state.wbuf);
};

fn sock_recv(file: *ev::file, r: (size | net::error)) void = {
	const state = ev::getuser(file): *state;
	const n = match (r) {
	case let n: size =>
		yield n;
	case let err: net::error =>
		fmt::errorln("Error: recv:", net::strerror(err))!;
		ev::stop(state.loop);
		return;
	};
	io::write(os::stdout_file, state.netbuf[..n])!;
};

fn sock_send(file: *ev::file, r: (size | net::error)) void = {
	const state = ev::getuser(file): *state;
	const n = match (r) {
	case let n: size =>
		yield n;
	case let err: net::error =>
		fmt::errorln("Error: send:", net::strerror(err))!;
		ev::stop(state.loop);
		return;
	};
	static delete(state.wbuf[..n]);
	if (len(state.wbuf) != 0) {
		ev::send(state.sock, &sock_send, state.wbuf);
	} else {
		ev::recv(state.sock, &sock_recv, state.netbuf);
		ev::readable(state.stdin, &stdin_readable);
	};
};
