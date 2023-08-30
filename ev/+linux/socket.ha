use errors;
use net;
use net::ip;
use net::tcp;
use net::udp;
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

// Creates a socket which listens for incoming UDP packets on the given IP
// address and port.
export fn listen_udp(
	loop: *loop,
	addr: ip::addr,
	port: u16,
	opts: udp::listen_option...
) (*file | net::error | errors::error) = {
	const sock = udp::listen(addr, port, opts...)?;
	return register(loop, sock)?;
};

// Creates a UDP socket on this event loop and sets the default destination to
// the given address.
export fn connect_udp(
	loop: *loop,
	dest: ip::addr,
	port: u16,
	opts: udp::connect_option...
) (*file | net::error | errors::error) = {
	const sock = udp::connect(dest, port, opts...)?;
	const file = register(loop, sock)?;
	return file;
};

export type connectcb = fn(result: (*file | net::error), user: nullable *opaque) void;

// Creates a socket and connects to a given IP address and port over TCP.
//
// The variadic arguments accept [[net::sockflag]] and/or no more than one user
// data pointer. If the user data pointer is provided, it will be passed to the
// callback. This allows the user to pass a state object through the connection
// process:
//
//	let user: state = // ...
// 	ev::connect_tcp(&loop, &connected, addr, port, &user);
//
// 	fn connected(result: (*ev::file | net::error), user: nullable *opaque) void = {
// 		let user = user: *state;
// 	};
//
// The user data object provided will be assigned to the [[file]] which is
// provided to the callback after the connection is established.
//
// If you don't need a user data object you can just omit it:
//
// 	ev::connect_tcp(&loop, &connected, addr, port, &user);
export fn connect_tcp(
	loop: *loop,
	cb: *connectcb,
	addr: ip::addr,
	port: u16,
	opts: (net::sockflag | *opaque)...
) (void | net::error | errors::error) = {
	// XXX: This doesn't let us set keepalive
	let opt: net::sockflag = 0;
	let user: nullable *opaque = null;
	for (let i = 0z; i < len(opts); i += 1) {
		match (opts[i]) {
		case let o: net::sockflag =>
			opt |= o;
		case let u: *opaque =>
			assert(user == null);
			user = u;
		};
	};
	const sock = tcp::connect(addr, port, opt | net::sockflag::NONBLOCK)?;
	let file = register(loop, sock)?;
	file.user = user;
	file.cb = cb;
	file.op = op::CONNECT_TCP;
	file_epoll_ctl(file);
};

fn connect_tcp_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op == op::CONNECT_TCP);
	assert(ev.events & rt::EPOLLOUT != 0);
	assert(sock.cb != null);
	const cb = sock.cb: *connectcb;
	sock.op = op::NONE;
	file_epoll_ctl(sock);

	let errno = 0i, optsz = size(int): u32;
	rt::getsockopt(sock.fd, rt::SOL_SOCKET, rt::SO_ERROR, &errno, &optsz)!;
	if (errno != 0) {
		cb(errors::errno(errno), sock.user);
		close(sock);
	} else {
		// XXX: If the user puts NONBLOCK into the opts provided at
		// [[connect_tcp]] we could try to preserve that here
		const fl = rt::fcntl(sock.fd, rt::F_GETFL, void)!;
		rt::fcntl(sock.fd, rt::F_SETFL, fl & ~rt::O_NONBLOCK)!;
		cb(sock, sock.user);
	};
};

// A callback for an [[accept]] operation.
export type acceptcb = fn(file: *file, result: (*file | net::error)) void;

// Schedules an accept operation on a socket.
export fn accept(
	sock: *file,
	cb: *acceptcb,
	flags: net::sockflag...
) req = {
	assert(sock.op == op::NONE);
	let fl: net::sockflag = 0;
	for (let i = 0z; i < len(flags); i += 1) {
		fl |= flags[i];
	};
	sock.op = op::ACCEPT;
	sock.cb = cb;
	sock.sockflag = fl;
	file_epoll_ctl(sock);
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
	file_epoll_ctl(sock);

	const r = tcp::accept(sock.fd, sock.sockflag);
	match (r) {
	case let fd: net::socket =>
		// TODO: Bubble up errors from here?
		const file = register(sock.ev, fd)!;
		cb(sock, file);
	case let err: net::error =>
		cb(sock, err);
	};
};

// TODO: Support recv & send in parallel

// Callback for a [[recvfrom]] operation. The second parameter is either an
// error or a tuple of the number of bytes received and the IP address and port
// of the sender.
export type recvfromcb = fn(
	file: *file,
	r: ((size, ip::addr, u16) | net::error),
) void;

// Schedules a receive operation on a socket.
export fn recvfrom(
	sock: *file,
	cb: *recvfromcb,
	buf: []u8,
) req = {
	assert(sock.op == op::NONE);
	sock.op = op::RECVFROM;
	sock.cb = cb;
	sock.sendrecv.rbuf = buf;
	file_epoll_ctl(sock);
	return req { ... };
};

fn recvfrom_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op == op::RECVFROM);
	assert(sock.cb != null);
	const cb = sock.cb: *recvfromcb;
	sock.op = op::NONE;
	file_epoll_ctl(sock);

	let src: ip::addr = ip::ANY_V4, port = 0u16;
	match (udp::recvfrom(sock.fd, sock.sendrecv.rbuf, &src, &port)) {
	case let err: net::error =>
		cb(sock, err);
	case let n: size =>
		cb(sock, (n, src, port));
	};
};

// Callback for a [[recv]] operation.
export type recvcb = fn(file: *file, r: (size | net::error)) void;

// Schedules a receive operation on a (connected) socket.
export fn recv(
	sock: *file,
	cb: *recvcb,
	buf: []u8,
) req = {
	assert(sock.op == op::NONE);
	sock.op = op::RECV;
	sock.cb = cb;
	sock.sendrecv.rbuf = buf;
	file_epoll_ctl(sock);
	return req { ... };
};

fn recv_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op == op::RECV);
	assert(sock.cb != null);
	const cb = sock.cb: *recvcb;
	sock.op = op::NONE;
	file_epoll_ctl(sock);

	const r = udp::recv(sock.fd, sock.sendrecv.rbuf);
	cb(sock, r);
};

// Callback for a [[send]] or [[sendto]] operation.
export type sendtocb = fn(file: *file, r: (size | net::error)) void;

// Schedules a send operation on a (connected) socket.
export fn send(
	sock: *file,
	cb: *sendtocb,
	buf: []u8,
) req = {
	assert(sock.op == op::NONE);
	sock.op = op::SEND;
	sock.cb = cb;
	sock.sendrecv.sbuf = buf;
	file_epoll_ctl(sock);
	return req { ... };
};

fn send_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op == op::SEND);
	assert(sock.cb != null);
	const cb = sock.cb: *sendtocb;
	sock.op = op::NONE;
	file_epoll_ctl(sock);

	const r = udp::send(sock.fd, sock.sendrecv.sbuf);
	cb(sock, r);
};

// Schedules a send operation on a socket.
export fn sendto(
	sock: *file,
	cb: *sendtocb,
	buf: []u8,
	dest: ip::addr,
	port: u16,
) req = {
	assert(sock.op == op::NONE);
	sock.op = op::SENDTO;
	sock.cb = cb;
	sock.sendrecv.sbuf = buf;
	sock.sendrecv.dest = dest;
	sock.sendrecv.port = port;
	file_epoll_ctl(sock);
	return req { ... };
};

fn sendto_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op == op::SENDTO);
	assert(sock.cb != null);
	const cb = sock.cb: *sendtocb;
	sock.op = op::NONE;
	file_epoll_ctl(sock);

	const r = udp::sendto(
		sock.fd,
		sock.sendrecv.sbuf,
		sock.sendrecv.dest,
		sock.sendrecv.port,
	);
	cb(sock, r);
};
