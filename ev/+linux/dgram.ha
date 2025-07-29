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
	amt: size,
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
	file_begin(file, req, op::RECVFROM);
};

fn recvfrom_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::RECVFROM != 0);
	let req = file_get_request(&sock.readq): *dgramreq;
	file_req_finish(req, &sock.readq);

	let src: ip::addr = ip::ANY_V4, port = 0u16;
	const cb = req.recvfromcb: *recvfromcb;
	match (udp::recvfrom(sock.fd, req.buf, &src, &port)) {
	case let err: net::error =>
		cb(req, err, req.user);
	case let n: size =>
		cb(req, (n, src, port), req.user);
	};

	file_end(sock, op::RECVFROM);
};

fn recvfrom_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::RECVFROM != 0);
	file_req_finish(req, &file.readq);
	file_end(file, op::RECVFROM);
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
	file_begin(file, req, op::RECV);
};

fn recv_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::RECV != 0);
	let req = file_get_request(&sock.readq): *dgramreq;
	file_req_finish(req, &sock.readq);

	const cb = req.recvcb as *recvcb;
	const r = udp::recv(sock.fd, req.buf);
	cb(req, r, req.user);

	file_end(sock, op::RECV);
};

fn recv_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::RECV != 0);
	file_req_finish(req, &file.readq);
	file_end(file, op::RECV);
};

// Sends a datagram to a socket (connected with e.g. [[connect_udp]]).
//
// The underlying operation will call [[net::send]] as many times as necessary
// to write out the entire buffer before running the callback.
export fn send(
	req: *dgramreq,
	buf: []u8,
	cb: *sendcb,
) void = {
	const file = file_req_init(req, &send_cancel);
	req.buf = buf;
	req.amt = 0;
	req.sendcb = cb;
	file_begin(file, req, op::SEND);
};

fn send_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::SEND != 0);
	let req = file_get_request(&sock.writeq): *dgramreq;

	const cb = req.sendcb as *sendcb;
	const r = match (udp::send(sock.fd, req.buf)) {
	case let n: size =>
		req.amt += n;
		req.buf = req.buf[n..];
		if (len(req.buf) != 0) {
			return;
		};
		yield req.amt;
	case let err: net::error =>
		yield err;
	};

	file_req_finish(req, &sock.writeq);
	cb(req, len(req.buf), req.user);
	file_end(sock, op::SEND);
};

fn send_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::SEND != 0);
	file_req_finish(req, &file.writeq);
	file_end(file, op::SEND);
};

// Schedules a send operation on a socket.
//
// The underlying operation will call [[net::sendto]] as many times as necessary
// to write out the entire buffer before running the callback.
export fn sendto(
	req: *dgramreq,
	buf: []u8,
	dest: ip::addr,
	port: u16,
	cb: *sendcb,
) void = {
	const file = file_req_init(req, &sendto_cancel);
	req.buf = buf;
	req.amt = 0;
	req.dest = dest;
	req.port = port;
	req.sendcb = cb;
	file_begin(file, req, op::SENDTO);
};

fn sendto_ready(
	sock: *file,
	ev: *rt::epoll_event,
) void = {
	assert(sock.op & op::SENDTO != 0);
	let req = file_get_request(&sock.writeq): *dgramreq;

	const cb = req.sendcb as *sendcb;
	const r = match (udp::sendto(sock.fd, req.buf, req.dest, req.port)) {
	case let n: size =>
		req.amt += n;
		req.buf = req.buf[n..];
		if (len(req.buf) != 0) {
			return;
		};
		yield req.amt;
	case let err: net::error =>
		yield err;
	};

	file_req_finish(req, &sock.writeq);
	cb(req, len(req.buf), req.user);
	file_end(sock, op::SENDTO);
};

fn sendto_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::SENDTO != 0);
	file_req_finish(req, &file.writeq);
	file_end(file, op::SENDTO);
};
