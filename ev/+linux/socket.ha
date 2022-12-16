use errors;
use net;
use net::ip;
use net::tcp;
use rt;

// Creates a socket which listens for incoming TCP connections on the given
// IP address and port.
export fn listen_tcp(
	loop: *loop,
	addr: ip::addr,
	port: u16,
	opts: tcp::listen_option...
) (*file | net::error | errors::error) = {
	const sock = tcp::listen(addr, port, opts...)?;
	return register(loop, sock)?;
};

// A callback for an [[accept]] operation.
export type acceptcb = fn(file: *file, result: (*file | net::error)) void;

// Schedules an accept operation on a socket.
export fn accept(
	sock: *file,
	cb: *acceptcb,
	flags: net::sockflags...
) req = {
	assert(sock.op == op::NONE);
	let fl: net::sockflags = 0;
	for (let i = 0z; i < len(flags); i += 1) {
		fl |= flags[i];
	};
	sock.op = op::ACCEPT;
	sock.cb = cb;
	sock.sockflags = fl;
	filemod(sock, rt::EPOLLIN);
	return req { ... };
};

fn accept_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op == op::ACCEPT);
	assert(ev.events & rt::EPOLLIN != 0);
	assert(sock.cb != null);
	const cb = sock.cb: *acceptcb;
	sock.op = op::NONE;
	filemod(sock, 0);

	const r = tcp::accept(sock.fd, sock.sockflags);
	match (r) {
	case let fd: net::socket =>
		// TODO: Bubble up errors from here?
		const file = register(sock.ev, fd)!;
		cb(sock, file);
	case let err: net::error =>
		cb(sock, err);
	};
};
