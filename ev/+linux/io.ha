use io;
use rt;

// A callback for a [[read]] or [[readv]] operation.
export type readcb = fn(
	req: *ioreq,
	result: (size | io::EOF | io::error),
	user: nullable *opaque,
) void;

// A callback for a [[write]] or [[writev]] operation.
export type writecb = fn(
	req: *ioreq,
	result: (size | io::error),
	user: nullable *opaque,
) void;

export type ioreq = struct {
	req,
	buf: io::vector,
	vec: []io::vector,
	union {
		readcb: nullable *readcb,
		writecb: nullable *writecb,
	},
};

// An uninitialized [[ioreq]] value. This can be used to statically initialize
// [[ioreq]] objects when [[ioreq_init]] is not applicable, for instance when
// storing an [[ioreq]] in a global.
export def IOREQ_INIT = ioreq { ... };

// Initializes an [[ioreq]] with a specified file and optional user data
// pointer. A single I/O request object may be re-used after it is completed or
// [[cancel]]led, with the same file and user data, or it can be reinitialized
// with a different file and/or user data.
//
// Once submitted to the event loop, a request object is borrowed from the
// caller and must remain stable until the request is cancelled or completed.
export fn ioreq_init(
	file: *file,
	user: nullable *opaque = null,
) ioreq = {
	return ioreq {
		file = file,
		user = user,
		...
	};
};

// Schedules a read operation on a file object. The provided buffer must be
// valid for the duration of the read operation.
export fn read(
	req: *ioreq,
	buf: []u8,
	cb: *readcb,
) void = {
	req.buf = io::mkvector(buf);
	const vec = (&req.buf: *[*]io::vector)[..1];
	readv(req, vec, cb);
};

// Schedules a vectored read operation on a file object. The provided vectors
// must be valid for the duration of the read operation.
export fn readv(
	req: *ioreq,
	vec: []io::vector,
	cb: *readcb,
) void = {
	const file = file_req_init(req, &readv_cancel);
	req.vec = vec;
	req.readcb = cb;

	if (file.flags & fflags::BLOCKING != 0) {
		const r = io::readv(file.fd, vec...);
		file_req_finish(req, &file.readq);
		cb(req, r, req.user);
		return;
	};

	file_begin(file, req, op::READV);
};

fn readv_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op & op::READ_MASK == op::READV);
	let req = file_get_request(&file.readq): *ioreq;
	file_req_finish(req, &file.readq);

	const cb = req.readcb as *readcb;
	if (ev.events & rt::EPOLLHUP != 0) {
		cb(req, io::EOF, req.user);
	} else {
		const r = io::readv(file.fd, req.vec...);
		cb(req, r, req.user);
	};

	file_end(file, op::READV);
};

fn readv_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::READ_MASK == op::READV);
	file_req_finish(req, &file.readq);
	file_end(file, op::READV);
};

// Schedules a write operation on a file object. The provided buffer must be
// valid for the duration of the write operation.
export fn write(
	req: *ioreq,
	buf: []u8,
	cb: *writecb,
) void = {
	req.buf = io::mkvector(buf);
	const vec = (&req.buf: *[*]io::vector)[..1];
	writev(req, vec, cb);
};

// Schedules a vectored write operation on a file object. The provided buffer
// must be valid for the duration of the write operation.
export fn writev(
	req: *ioreq,
	vec: []io::vector,
	cb: *writecb,
) void = {
	const file = file_req_init(req, &writev_cancel);
	req.vec = vec;
	req.writecb = cb;

	if (file.flags & fflags::BLOCKING != 0) {
		const r = io::writev(file.fd, vec...);
		file_req_finish(req, &file.writeq);
		cb(req, r, req.user);
		return;
	};

	file_begin(file, req, op::WRITEV);
};

fn writev_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op & op::WRITE_MASK == op::WRITEV);
	let req = file_get_request(&file.writeq): *ioreq;
	file_req_finish(req, &file.writeq);

	const cb = req.writecb as *writecb;
	const r = io::writev(file.fd, req.vec...);
	cb(req, r, req.user);

	file_end(file, op::WRITEV);
};

fn writev_cancel(req: *req) void = {
	const file = req_getfile(req) as *file;
	assert(file.op & op::WRITE_MASK == op::WRITEV);
	file_req_finish(req, &file.writeq);
	file_end(file, op::WRITEV);
};
