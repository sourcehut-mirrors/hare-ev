use errors;
use io;

fn readv_ready(file: *file) void = {
	assert(file.op & op::READ_MASK == op::READV);
	let req = file_get_request(&file.readq): *ioreq;
	file_req_finish(req, &file.readq);

	const cb = req.readcb as *readcb;
	const r = io::readv(file.fd, req.vec...);
	cb(req, r, req.user);

	file_end(file, op::READV);
	if (!req_list_empty(&file.readq)) {
		file_epoll_ctl(file);
	};
};

// Schedules a vectored write operation on a file object. The provided buffer
// must be valid for the duration of the write operation.
//
// The underlying operation will call [[io::writev]] as many times as necessary
// to write out the entire buffer before running the callback.
export fn writev(
	req: *ioreq,
	vec: []io::vector,
	cb: *writecb,
) void = {
	const file = file_req_init(req, &writev_cancel);
	req.vec = vec;
	req.amt = 0;
	req.writecb = cb;

	if (file.flags & fflags::BLOCKING != 0) {
		let r: (size | io::error) = 0z;
		for (len(req.vec) != 0) {
			r = writev_proc(req, file);
			if (r is io::error) break;
		};

		file_req_finish(req, &file.writeq);
		cb(req, r, req.user);
		return;
	};

	file_begin(file, req, op::WRITEV);
};

fn writev_ready(file: *file) void = {
	assert(file.op & op::WRITE_MASK == op::WRITEV);
	let req = file_get_request(&file.writeq): *ioreq;
	for (true) {
		const cb = req.writecb as *writecb;
		const r = match (writev_proc(req, file)) {
		case size =>
			if (len(req.vec) != 0) {
				file_epoll_ctl(file);
				return;
			};
			yield req.amt;
		case let err: io::error =>
			if (err is errors::again) {
				file_epoll_ctl(file);
				return;
			};
			yield err;
		};

		file_req_finish(req, &file.writeq);
		cb(req, r, req.user);
		file_end(file, op::WRITEV);

		if (!req_list_empty(&file.writeq)) {
			req = file_get_request(&file.writeq): *ioreq;
			continue;
		};
		break;
	};
};
