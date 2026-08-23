use errors;
use net;

// Callback for [[recvmsg]]. The message passed to [[recvmsg]] is populated with
// the received data (in the buffers configured via [[net::addvector]]) and any
// ancillary data (retrievable via [[net::unix::recvfiles]]).
export type recvmsgcb = fn(
	req: *recvmsgreq,
	msg: *net::msghdr,
	r: (size | net::error),
	user: nullable *opaque,
) void;

export type recvmsgreq = struct {
	req,
	// Message to receive into (borrowed from the caller).
	msg: nullable *net::msghdr,
	cb: nullable *recvmsgcb,
};

// Initialises a [[recvmsgreq]]. A single request object may be re-used after it
// is completed or [[cancel]]led, with the same file and user data, or it can be
// reinitialized with a different file and/or user data.
//
// Once submitted to the event loop, a request object is borrowed from the caller
// and must remain stable until the request is cancelled or completed.
export fn recvmsgreq_init(
	file: *file,
	user: nullable *opaque = null,
) recvmsgreq = {
	return recvmsgreq {
		file = file,
		user = user,
		...
	};
};

// Schedules a message to be received from a socket. The provided message, along
// with any buffers and ancillary data storage associated with it (see
// [[net::addvector]] and [[net::unix::allocfiles]]), must remain valid until the
// operation completes or is cancelled. The callback is invoked once, when a
// message has been received.
export fn recvmsg(
	req: *recvmsgreq,
	msg: *net::msghdr,
	cb: *recvmsgcb,
) void = {
	const file = file_req_init(req, &recvmsg_cancel);
	req.msg = msg;
	req.cb = cb;
	file_begin(file, req, op::RECVMSG);
};

fn recvmsg_ready(sock: *file) void = {
	assert(sock.op & op::READ_MASK == op::RECVMSG);
	let req = file_get_request(&sock.readq): *recvmsgreq;
	const cb = req.cb as *recvmsgcb;
	const msg = req.msg as *net::msghdr;

	const r = net::recvmsg(sock.fd, msg);
	match (r) {
	case let err: net::error =>
		if (err is errors::again) {
			file_rearm(sock);
			return;
		};
	case size =>
		void;
	};

	file_req_finish(req, &sock.readq);
	file_end(sock, op::RECVMSG);
	cb(req, msg, r, req.user);
};

fn recvmsg_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::READ_MASK == op::RECVMSG);
	file_req_finish(req, &file.readq);
	file_end(file, op::RECVMSG);
};
