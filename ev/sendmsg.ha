use errors;
use net;
use sys;

// Callback for [[sendmsg]]. Called once, when the message has been fully sent
// or has failed.
export type sendmsgcb = fn(
	req: *sendmsgreq,
	r: (size | net::error),
	user: nullable *opaque,
) void;

export type sendmsgreq = struct {
	req,
	// Message to send (borrowed from the caller).
	msg: nullable *net::msghdr,
	// Bytes of the in-flight message already sent.
	amt: size,
	cb: nullable *sendmsgcb,
};

// Initialises a [[sendmsgreq]]. A single request object may be re-used after it
// is completed or [[cancel]]led, with the same file and user data, or it can be
// reinitialized with a different file and/or user data.
//
// Once submitted to the event loop, a request object is borrowed from the caller
// and must remain stable until the request is cancelled or completed.
export fn sendmsgreq_init(
	file: *file,
	user: nullable *opaque = null,
) sendmsgreq = {
	return sendmsgreq {
		file = file,
		user = user,
		...
	};
};

// Schedules a message to be sent on a socket. The provided message, along with
// any buffers and ancillary data associated with it, must remain valid until
// the operation completes or is cancelled. The callback is invoked once, when
// the message has been fully sent or has failed. Users should free the message
// and close any file descriptors as necessary.
//
// File descriptors attached to the message (see [[net::unix::addfiles]]) are
// sent together with the first bytes of the message.
export fn sendmsg(
	req: *sendmsgreq,
	msg: *net::msghdr,
	cb: *sendmsgcb,
) void = {
	const file = file_req_init(req, &sendmsg_cancel);
	req.msg = msg;
	req.amt = 0;
	req.cb = cb;
	file_begin(file, req, op::SENDMSG);
};

fn sendmsg_ready(sock: *file) void = {
	assert(sock.op & op::WRITE_MASK == op::SENDMSG);
	let req = file_get_request(&sock.writeq): *sendmsgreq;
	const msg = req.msg as *net::msghdr;  // Cannot be null if we're in callback.
	const total = msg_len(msg);
	const cb = req.cb as *sendmsgcb;

	const r = if (req.amt == 0) {
		// The first send carries the ancillary data (e.g. file
		// descriptors) alongside the leading message bytes.
		yield net::sendmsg(sock.fd, msg);
	} else {
		yield sendmsg_resume(sock, msg, req.amt);
	};

	match (r) {
	case let n: size =>
		req.amt += n;
		if (req.amt < total) {
			file_rearm(sock);
			return;
		};

		req.amt = 0;
		file_req_finish(req, &sock.writeq);
		file_end(sock, op::SENDMSG);
		cb(req, total, req.user);
	case let err: net::error =>
		if (err is errors::again) {
			file_rearm(sock);
			return;
		};
		file_req_finish(req, &sock.writeq);
		file_end(sock, op::SENDMSG);
		cb(req, err, req.user);
	};
};

// Sends the unsent tail of a partially-sent message.
fn sendmsg_resume(sock: *file, msg: *net::msghdr, amt: size) (size | net::error) = {
	// Send a copy of the message header without the ancillary, since that's
	// delivered with the first bytes and must not be sent again. The
	// caller's full message is left unchanged.

	let skip = amt;
	let i = 0z;
	for (i < len(msg.vectors); i += 1) {
		if (skip < msg.vectors[i].iov_len) {
			break;
		};
		skip -= msg.vectors[i].iov_len;
	};

	const save = msg.vectors[i];
	const base = (save.iov_base as *opaque): *[*]u8;
	const buf = base[skip..save.iov_len];
	msg.vectors[i] = sys::iovec {
		iov_base = &buf[0],
		iov_len = len(buf),
	};

	let hdr = *msg;
	hdr.vectors = msg.vectors[i..];
	// net::msg_to_native only writes the native control fields when the
	// control buffer is non-empty. Clear them explicitly.
	hdr.control = hdr.control[..0];
	hdr.native.msg_control = null;
	hdr.native.msg_controllen = 0;
	const r = net::sendmsg(sock.fd, &hdr);

	msg.vectors[i] = save;
	return r;
};

fn sendmsg_cancel(reqp: *req) void = {
	const req = reqp: *sendmsgreq;
	const file = req_getfile(reqp) as *file;
	assert(file.op & op::WRITE_MASK == op::SENDMSG);
	file_req_finish(reqp, &file.writeq);
	file_end(file, op::SENDMSG);
	req.amt = 0;
};

fn msg_len(msg: *net::msghdr) size = {
	let total = 0z;
	for (let vec.. msg.vectors) {
		total += vec.iov_len;
	};
	return total;
};
