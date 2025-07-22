use net;
use net::ip;
use net::udp;
use rt;

// Callback for a [[recvfrom]] operation. The second parameter is either an
// error or a tuple of the number of bytes received and the IP address and port
// of the sender.
export type recvfromcb = fn(
	req: *dgramreq,
	r: ((size, ip::addr, u16) | net::error),
	user: nullable *opaque,
) void;

// Callback for a [[recv]] operation.
export type recvcb = fn(
	req: *dgramreq,
	r: (size | net::error),
	user: nullable *opaque,
) void;

// Callback for a [[send]] or [[sendto]] operation.
export type sendcb = fn(
	req: *dgramreq,
	r: (size | net::error),
	user: nullable *opaque,
) void;

export type dgramreq = struct {
	req,
	buf: []u8,
	dest: ip::addr,
	port: u16,
	union {
		recvfromcb: nullable *recvfromcb,
		recvcb: nullable *recvcb,
		sendcb: nullable *sendcb,
	},
};

// An uninitialized [[dgramreq]] value. This can be used to statically
// initialize [[dgramreq]] objects when [[dgramreq_init]] is not applicable, for
// instance when storing an [[dgramreq]] in a global.
export def DGRAMREQ_INIT = dgramreq {
	dest = [0, 0, 0, 0]: ip::addr4: ip::addr,
	...
};

// Initializes a [[dgramreq]] with a specified file and optional user data
// pointer. A single request object may be re-used after it is completed or
// [[cancel]]led, with the same file and user data, or it can be reinitialized
// with a different file and/or user data.
//
// Once submitted to the event loop, a request object is borrowed from the
// caller and must remain stable until the request is cancelled or completed.
export fn dgramreq_init(
	file: *file,
	user: nullable *opaque = null,
) dgramreq = {
	return dgramreq {
		file = file,
		user = user,
		dest = ip::ANY_V4,
		...
	};
};

// Returns the buffer used for this [[dgramreq]].
export fn dgramreq_getbuf(req: *dgramreq) []u8 = {
	return req.buf;
};

// Returns the destination IP address and port specified when this [[dgramreq]]
// was passed to [[sendto]]. The results are undefined if this [[dgramreq]] was
// not last used for a [[sendto]] operation.
export fn dgramreq_getdest(req: *dgramreq) (ip::addr, u16) = {
	return (req.dest, req.port);
};

// Receive a datagram from a socket, recording the (presumed) origin of the
// packet.
export fn recvfrom(
	req: *dgramreq,
	buf: []u8,
	cb: *recvfromcb,
) void = {
	const file = file_req_init(req, &recvfrom_cancel);
	req.buf = buf;
	req.recvfromcb = cb;

	file.op |= op::RECVFROM;
	file_epoll_ctl(file);
	req_link(&file.recvfrom, &req.link);
};

fn recvfrom_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::RECVFROM != 0);
	let req = file_get_request(&sock.recvfrom): *dgramreq;
	file_req_finish(req, &sock.recvfrom);

	let src: ip::addr = ip::ANY_V4, port = 0u16;
	const cb = req.recvfromcb: *recvfromcb;
	match (udp::recvfrom(sock.fd, req.buf, &src, &port)) {
	case let err: net::error =>
		cb(req, err, req.user);
	case let n: size =>
		cb(req, (n, src, port), req.user);
	};

	if (req_list_empty(&sock.recvfrom)) {
		sock.op &= ~op::RECVFROM;
		file_epoll_ctl(sock);
	};
};

fn recvfrom_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::RECVFROM != 0);
	file_req_finish(req, &file.recvfrom);

	if (req_list_empty(&file.recvfrom)) {
		file.op &= ~op::RECVFROM;
		file_epoll_ctl(file);
	};
};

// Receive a datagram from a socket (connected with e.g. [[connect_udp]]).
export fn recv(
	req: *dgramreq,
	buf: []u8,
	cb: *recvcb,
) void = {
	const file = file_req_init(req, &recv_cancel);
	req.buf = buf;
	req.recvcb = cb;

	file.op |= op::RECV;
	file_epoll_ctl(file);
	req_link(&file.recv, &req.link);
};

fn recv_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::RECV != 0);
	let req = file_get_request(&sock.recv): *dgramreq;
	file_req_finish(req, &sock.recv);

	const cb = req.recvcb as *recvcb;
	const r = udp::recv(sock.fd, req.buf);
	cb(req, r, req.user);

	if (req_list_empty(&sock.recv)) {
		sock.op &= ~op::RECV;
		file_epoll_ctl(sock);
	};
};

fn recv_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::RECV != 0);
	file_req_finish(req, &file.recv);

	if (req_list_empty(&file.recv)) {
		file.op &= ~op::RECV;
		file_epoll_ctl(file);
	};
};

// Sends a datagram to a socket (connected with e.g. [[connect_udp]]).
export fn send(
	req: *dgramreq,
	buf: []u8,
	cb: *sendcb,
) void = {
	const file = file_req_init(req, &send_cancel);
	req.buf = buf;
	req.sendcb = cb;

	file.op |= op::SEND;
	file_epoll_ctl(file);
	req_link(&file.send, &req.link);
};

fn send_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::SEND != 0);
	let req = file_get_request(&sock.send): *dgramreq;
	file_req_finish(req, &sock.send);

	const cb = req.sendcb as *sendcb;
	const r = udp::send(sock.fd, req.buf);
	cb(req, r, req.user);

	if (req_list_empty(&sock.send)) {
		sock.op &= ~op::SEND;
		file_epoll_ctl(sock);
	};
};

fn send_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::SEND != 0);
	file_req_finish(req, &file.send);

	if (req_list_empty(&file.send)) {
		file.op &= ~op::SEND;
		file_epoll_ctl(file);
	};
};

// Schedules a send operation on a socket.
export fn sendto(
	req: *dgramreq,
	buf: []u8,
	dest: ip::addr,
	port: u16,
	cb: *sendcb,
) void = {
	const file = file_req_init(req, &sendto_cancel);
	req.buf = buf;
	req.dest = dest;
	req.port = port;
	req.sendcb = cb;

	file.op |= op::SENDTO;
	file_epoll_ctl(file);
	req_link(&file.sendto, &req.link);
};

fn sendto_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::SENDTO != 0);
	let req = file_get_request(&sock.sendto): *dgramreq;
	file_req_finish(req, &sock.sendto);

	const cb = req.sendcb as *sendcb;
	const r = udp::sendto(sock.fd, req.buf, req.dest, req.port);
	cb(req, r, req.user);

	if (req_list_empty(&sock.sendto)) {
		sock.op &= ~op::SENDTO;
		file_epoll_ctl(sock);
	};
};

fn sendto_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::SENDTO != 0);
	file_req_finish(req, &file.sendto);

	if (req_list_empty(&file.sendto)) {
		file.op &= ~op::SENDTO;
		file_epoll_ctl(file);
	};
};
