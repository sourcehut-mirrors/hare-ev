use sys;

export type pollcb = fn(req: *pollreq, user: nullable *opaque) void;

export type pollreq = struct {
	req,
	cb: nullable *pollcb,
};

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
