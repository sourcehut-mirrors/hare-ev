use errors;
use net;
use net::ip;
use net::tcp;
use net::udp;
use net::unix;
use sys;

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
	flags: net::sockflag,
	union {
		connectcb: nullable *connectcb,
		acceptcb: nullable *acceptcb,
	},
};

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
		flags = 0,
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
		flags = 0,
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
	const loop = req.loop as *loop;
	const sock = tcp::connect(addr, port, opts | net::sockflag::NONBLOCK)?;
	req.file = register(loop, sock)?;
	req.connectcb = cb;

	let file = file_req_init(req, &connect_cancel);
	file.op = op::CONNECT_TCP;
	file_kevent_ctl(file);
	file.connect = req;
};

fn connect_tcp_ready(
	sock: *file,
	ev: *sys::kevent,
) void = {
	assert(sock.op & ~op::RW_MASK == op::CONNECT_TCP);
	let req = sock.connect as *sockreq;
	sock.connect = null;
	sock.op &= ~op::CONNECT_TCP;

	const loop = sock.ev;
	loop.nrequest -= 1;
	req.cancel = null;

	const cb = req.connectcb as *connectcb;
	file_kevent_ctl(sock);

	let errno = 0i, optsz = size(int): u32;
	sys::getsockopt(sock.fd, sys::SOL_SOCKET, sys::SO_ERROR, &errno, &optsz)!;
	if (errno != 0) {
		cb(req, errors::errno(errno), req.user);
		close(sock);
	} else {
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
	const loop = req.loop as *loop;
	const sock = unix::connect(addr, opts | net::sockflag::NONBLOCK)?;
	req.file = register(loop, sock)?;
	req.connectcb = cb;

	let file = file_req_init(req, &connect_cancel);
	file.op = op::CONNECT_UNIX;
	file_kevent_ctl(file);
	file.connect = req;
};

fn connect_unix_ready(
	sock: *file,
	ev: *sys::kevent,
) void = {
	assert(sock.op & ~op::RW_MASK == op::CONNECT_UNIX);
	let req = sock.connect as *sockreq;
	sock.connect = null;
	sock.op &= ~op::CONNECT_UNIX;

	const loop = sock.ev;
	loop.nrequest -= 1;
	req.cancel = null;

	const cb = req.connectcb as *connectcb;
	file_kevent_ctl(sock);

	let errno = 0i, optsz = size(int): u32;
	sys::getsockopt(sock.fd, sys::SOL_SOCKET, sys::SO_ERROR, &errno, &optsz)!;
	if (errno != 0) {
		cb(req, errors::errno(errno), req.user);
		close(sock);
	} else {
		cb(req, sock, req.user);
	};
};

fn connect_cancel(req: *req) void = {
	const sock = req_getfile(req) as *file;
	assert(sock.op & ~op::RW_MASK == op::CONNECT_TCP
		|| sock.op & ~op::RW_MASK == op::CONNECT_UNIX);
	sock.connect = null;
	sock.op &= ~(op::CONNECT_TCP | op::CONNECT_UNIX);
	sock.ev.nrequest -= 1;
	req.cancel = null;
	close(sock);
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
	req.flags = flags;
	req.acceptcb = cb;

	file_begin(file, req, op::ACCEPT);
	req_link(&file.acceptq, &req.link);
};

fn accept_ready(
	sock: *file,
	ev: *sys::kevent,
) void = {
	assert(sock.op & ~op::RW_MASK == op::ACCEPT);
	let req = file_get_request(&sock.acceptq): *sockreq;
	file_req_finish(req, &sock.acceptq);

	const cb = req.acceptcb as *acceptcb;
	const r = tcp::accept(sock.fd, req.flags);
	match (r) {
	case let fd: net::socket =>
		// TODO: Bubble up errors from here.
		const file = register(sock.ev, fd)!;
		cb(req, file, req.user);
	case let err: net::error =>
		cb(req, err, req.user);
	};

	if (req_list_empty(&sock.acceptq)) {
		sock.op &= op::RW_MASK;
		file_kevent_ctl(sock);
	};
};

fn accept_cancel(req: *req) void = {
	const sock = req_getfile(req) as *file;
	file_req_finish(req, &sock.acceptq);

	if (req_list_empty(&sock.acceptq)) {
		sock.op &= op::RW_MASK;
		file_kevent_ctl(sock);
	};
};
