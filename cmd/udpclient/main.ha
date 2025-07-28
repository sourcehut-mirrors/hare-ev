use ev;
use fmt;
use io;
use net::ip;
use net;
use os;

type state = struct {
	loop: *ev::loop,
	sock: *ev::file,
	stdbuf: [os::BUFSZ]u8,
	netbuf: [os::BUFSZ]u8,
	wbuf: []u8,
	sendreq: ev::dgramreq,
	readreq: ev::ioreq,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const sock = ev::connect_udp(&loop, ip::LOCAL_V4, 12345)!;
	defer ev::close(sock);
	const stdin = ev::register(&loop, os::stdin_file)!;
	defer ev::unregister(stdin);

	let state = state {
		loop = &loop,
		sock = sock,
		sendreq = ev::dgramreq_init(sock),
		readreq = ev::ioreq_init(stdin),
		...
	};
	ev::req_setuser(&state.sendreq, &state);
	ev::req_setuser(&state.readreq, &state);
	ev::read(&state.readreq, state.stdbuf, &stdin_on_read);

	let recv = ev::dgramreq_init(sock, &state);
	ev::recv(&recv, state.netbuf, &sock_on_recv);

	ev::run(&loop)!;
};

fn stdin_on_read(
	req: *ev::ioreq,
	result: (size | io::EOF | io::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;

	const n = match (result!) {
	case io::EOF =>
		ev::stop(state.loop);
		return;
	case let z: size =>
		yield z;
	};

	state.wbuf = state.stdbuf[..n];
	ev::send(&state.sendreq, state.wbuf, &sock_on_send);
};

fn sock_on_send(
	req: *ev::dgramreq,
	result: (size | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;
	const n = result!;

	static delete(state.wbuf[..n]);
	if (len(state.wbuf) != 0) {
		ev::send(req, state.wbuf, &sock_on_send);
	} else {
		ev::read(&state.readreq, state.stdbuf, &stdin_on_read);
	};
};

fn sock_on_recv(
	req: *ev::dgramreq,
	result: (size | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;
	const n = result!;
	io::writeall(os::stdout, state.netbuf[..n])!;
	ev::recv(req, state.netbuf, &sock_on_recv);
};
