use errors;
use net;
use net::ip;
use net::tcp;
use net::udp;
use net::unix;
use rt;

// Callback for a connect operation, e.g. [[connect_tcp]].
export type connectcb = fn(
	req: *sockreq,
	result: (*file | net::error),
	user: nullable *opaque,
) void;

// A callback for an [[accept]] operation.
export type acceptcb = fn(
	req: *sockreq,
	result: (*file | net::error),
	user: nullable *opaque,
) void;

export type sockreq = struct {
	req,
	union {
		connectcb: nullable *connectcb,
		acceptcb: nullable *acceptcb,
	},
};

// An uninitialized [[sockreq]] value. This can be used to statically initialize
// [[sockreq]] objects when [[connect_init]] or [[accept_init]] is not
// applicable, for instance when storing a [[sockreq]] in a global.
export def SOCKREQ_INIT = sockreq { ... };

// Initializes a [[sockreq]] for use with [[connect_tcp]] et al.
//
// A single I/O request object may be re-used after it is completed or
// [[cancel]]led, with the same event loop and user data, or it can be
// reinitialized with a different event loop and/or user data, or with
// [[accept_init]] to use the request for accepting clients.
//
// Once submitted, e.g. via [[connect_tcp]], the request object is borrowed from
// the caller and must remain stable until the request is cancelled or
// completed.
export fn connect_init(loop: *loop, user: nullable *opaque = null) sockreq = {
	return sockreq {
		loop = loop,
		user = user,
		...
	};
};

// Initializes a [[sockreq]] for use with [[accept]].
//
// A single I/O request object may be re-used after it is completed or
// [[cancel]]led, with the same event loop and user data, or it can be
// reinitialized with a different event loop and/or user data, or with
// [[connect_init]] to use the request object for connecting to a server.
//
// Once submitted with [[accept_tcp]], the request object is borrowed from the
// caller and must remain stable until the request is cancelled or completed.
export fn accept_init(socket: *file, user: nullable *opaque = null) sockreq = {
	return sockreq {
		file = socket,
		user = user,
		...
	};
};

// Creates a socket which listens for incoming TCP connections on the given IP
// address and port.
export fn listen_tcp(
	loop: *loop,
	addr: ip::addr,
	port: u16,
	opts: tcp::listen_option...
) (*file | net::error | errors::error | nomem) = {
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
) (*file | net::error | errors::error | nomem) = {
	const sock = udp::listen(addr, port, opts...)?;
	return register(loop, sock)?;
};

// Creates a UNIX domain socket at the given path.
export fn listen_unix(
	loop: *loop,
	addr: unix::addr,
	opts: unix::listen_option...
) (*file | net::error | errors::error | nomem) = {
	const sock = unix::listen(addr, opts...)?;
	return register(loop, sock)?;
};

// Creates a UDP socket on this event loop and sets the default destination to
// the given address.
export fn connect_udp(
	loop: *loop,
	dest: ip::addr,
	port: u16,
	opts: udp::connect_option...
) (*file | net::error | errors::error | nomem) = {
	const sock = udp::connect(dest, port, opts...)?;
	return register(loop, sock)?;
};

// Creates a socket and connects to a given IP address and port over TCP.
//
// See [[connect_init]] for preparing the [[sockreq]].
export fn connect_tcp(
	req: *sockreq,
	addr: ip::addr,
	port: u16,
	cb: *connectcb,
	opts: net::sockflag = 0,
) (void | net::error | errors::error | nomem) = {
	const loop = loop_req_init(req, &connect_tcp_cancel);
	const sock = tcp::connect(addr, port, opts | net::sockflag::NONBLOCK)?;

	let file = register(loop, sock)?;
	req.file = file;
	req.connectcb = cb;

	file.op = op::CONNECT_TCP;
	file_epoll_ctl(file);
	file.connect = req;
};

fn connect_tcp_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op == op::CONNECT_TCP);
	assert(ev.events & rt::EPOLLOUT != 0);
	let req = sock.connect as *sockreq;
	loop_req_finish(req);

	const cb = req.connectcb as *connectcb;
	sock.op &= ~op::CONNECT_TCP;
	file_epoll_ctl(sock);

	let errno = 0i, optsz = size(int): u32;
	rt::getsockopt(sock.fd, rt::SOL_SOCKET, rt::SO_ERROR, &errno, &optsz)!;
	if (errno != 0) {
		cb(req, errors::errno(errno), req.user);
		close(sock);
	} else {
		// XXX: If the user puts NONBLOCK into the opts provided at
		// [[connect_tcp]] we could try to preserve that here
		const fl = rt::fcntl(sock.fd, rt::F_GETFL, void)!;
		rt::fcntl(sock.fd, rt::F_SETFL, fl & ~rt::O_NONBLOCK)!;
		cb(req, sock, req.user);
	};
};

// Connects to a UNIX domain socket.
//
// See [[connect_init]] for preparing the [[sockreq]].
export fn connect_unix(
	req: *sockreq,
	addr: unix::addr,
	cb: *connectcb,
	opts: net::sockflag = 0,
) (void | net::error | errors::error | nomem) = {
	const loop = loop_req_init(req, &connect_tcp_cancel);
	const sock = unix::connect(addr, opts | net::sockflag::NONBLOCK)?;

	let file = register(loop, sock)?;
	req.file = file;
	req.connectcb = cb;

	file.op = op::CONNECT_UNIX;
	file_epoll_ctl(file);
	file.connect = req;
};

fn connect_unix_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op == op::CONNECT_UNIX);
	assert(ev.events & rt::EPOLLOUT != 0);
	let req = sock.connect as *sockreq;
	loop_req_finish(req);

	const cb = req.connectcb as *connectcb;
	sock.op &= ~op::CONNECT_UNIX;
	file_epoll_ctl(sock);

	let errno = 0i, optsz = size(int): u32;
	rt::getsockopt(sock.fd, rt::SOL_SOCKET, rt::SO_ERROR, &errno, &optsz)!;
	if (errno != 0) {
		cb(req, errors::errno(errno), req.user);
		close(sock);
	} else {
		// XXX: If the user puts NONBLOCK into the opts provided at
		// [[connect_unix]] we could try to preserve that here
		const fl = rt::fcntl(sock.fd, rt::F_GETFL, void)!;
		rt::fcntl(sock.fd, rt::F_SETFL, fl & ~rt::O_NONBLOCK)!;
		cb(req, sock, req.user);
	};
};

fn connect_tcp_cancel(req: *req) void = {
	const sock = req.user: *file;
	assert(sock.op == op::CONNECT_TCP);
	sock.op = op::NONE;
	file_epoll_ctl(sock);

	const file = req_getfile(req) as *file;
	assert(file.op & op::ACCEPT != 0);
	file_req_finish(req, &file.accept);

	if (req_list_empty(&file.accept)) {
		file.op &= ~op::ACCEPT;
		file_epoll_ctl(file);
	};
};

fn connect_unix_cancel(req: *req) void = {
	const sock = req.user: *file;
	assert(sock.op == op::CONNECT_UNIX);
	sock.op = op::NONE;
	file_epoll_ctl(sock);
};

// Accepts an incoming connection on a listening socket, which was set up with
// e.g. [[listen_tcp]].
//
// See [[accept_init]] for preparing the [[sockreq]].
export fn accept(
	req: *sockreq,
	cb: *acceptcb,
	flags: net::sockflag = 0,
) void = {
	const file = file_req_init(req, &accept_cancel);
	req.acceptcb = cb;

	file.op |= op::ACCEPT;
	file_epoll_ctl(file);
	req_link(&file.accept, &req.link);
};

fn accept_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::ACCEPT != 0);
	assert(ev.events & rt::EPOLLIN != 0);
	let req = file_get_request(&sock.accept): *sockreq;
	file_req_finish(req, &sock.accept);

	const cb = req.acceptcb as *acceptcb;
	const r = tcp::accept(sock.fd, sock.sockflag);
	match (r) {
	case let fd: net::socket =>
		// TODO: Bubble up errors from here?
		const file = register(sock.ev, fd)!;
		cb(req, file, req.user);
	case let err: net::error =>
		cb(req, err, req.user);
	};

	if (req_list_empty(&sock.accept)) {
		sock.op &= ~op::ACCEPT;
		file_epoll_ctl(sock);
	};
};

fn accept_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::ACCEPT != 0);
	file_req_finish(req, &file.accept);

	if (req_list_empty(&file.accept)) {
		file.op &= ~op::ACCEPT;
		file_epoll_ctl(file);
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
	return mkreq(sock, &recvfrom_cancel);
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

fn recvfrom_cancel(req: *req) void = {
	const sock = req.user: *file;
	assert(sock.op == op::RECVFROM);
	sock.op = op::NONE;
	file_epoll_ctl(sock);
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
	return mkreq(sock, &recv_cancel);
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

fn recv_cancel(req: *req) void = {
	const sock = req.user: *file;
	assert(sock.op == op::RECV);
	sock.op = op::NONE;
	file_epoll_ctl(sock);
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
	return mkreq(sock, &send_cancel);
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

fn send_cancel(req: *req) void = {
	const sock = req.user: *file;
	assert(sock.op == op::SEND);
	sock.op = op::NONE;
	file_epoll_ctl(sock);
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
	return mkreq(sock, &sendto_cancel);
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

fn sendto_cancel(req: *req) void = {
	const sock = req.user: *file;
	assert(sock.op == op::SENDTO);
	sock.op = op::NONE;
	file_epoll_ctl(sock);
};
