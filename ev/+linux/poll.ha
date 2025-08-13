use rt;
use unix::poll;

// A callback for a [[readable]] or [[writable]] operation.
export type pollcb = fn(req: *pollreq, user: nullable *opaque) void;

export type pollreq = struct {
	req,
	cb: nullable *pollcb,
};

// An uninitialized [[pollreq]] value. This can be used to statically
// initialize [[pollreq]] objects when [[pollreq_init]] is not applicable, for
// instance when storing an [[pollreq]] in a global.
export def POLLREQ_INIT = pollreq { ... };

// Initializes a [[pollreq]] with a specified file and optional user data
// pointer. A single request object may be re-used after it is completed or
// [[cancel]]led, with the same file and user data, or it can be reinitialized
// with a different file and/or user data.
//
// Once submitted to the event loop, a request object is borrowed from the
// caller and must remain stable until the request is cancelled or completed.
export fn pollreq_init(
	file: *file,
	user: nullable *opaque = null,
) pollreq = {
	return pollreq {
		file = file,
		user = user,
		...
	};
};

// Executes the callback when a given file is readable. Cannot be combined with
// [[read]] or [[readv]].
export fn readable(
	req: *pollreq,
	cb: *pollcb,
) void = {
	const file = file_req_init(req, &readable_cancel);
	req.cb = cb;
	file_begin(file, req, op::READABLE);
};

fn readable_ready(file: *file) void = {
	assert(file.op & op::READABLE != 0);
	let req = file_get_request(&file.readq): *pollreq;
	file_req_finish(req, &file.readq);

	const cb = req.cb as *pollcb;
	cb(req, req.user);

	file_end(file, op::READABLE);
};

fn readable_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::READABLE != 0);
	file_req_finish(req, &file.readq);
	file_end(file, op::READABLE);
};

// Executes the callback when a given file is writable. Cannot be combined with
// [[write]] or [[writev]].
export fn writable(
	req: *pollreq,
	cb: *pollcb,
) void = {
	const file = file_req_init(req, &writable_cancel);
	req.cb = cb;
	file_begin(file, req, op::WRITABLE);
};

fn writable_ready(file: *file) void = {
	assert(file.op & op::WRITABLE != 0);
	let req = file_get_request(&file.writeq): *pollreq;
	file_req_finish(req, &file.writeq);

	const cb = req.cb as *pollcb;
	cb(req, req.user);

	file_end(file, op::WRITABLE);
};

fn writable_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::WRITABLE != 0);
	file_req_finish(req, &file.writeq);
	file_end(file, op::WRITABLE);
};
