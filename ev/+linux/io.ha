use io;
use rt;

// A callback for a [[read]] or [[readv]] operation.
export type readcb = *fn(file: *file, result: (size | io::EOF | io::error)) void;

// Schedules a read operation on a file object.
export fn read(
	file: *file,
	cb: *readcb,
	buf: []u8,
) req = {
	file.vbuf = io::mkvector(buf);
	// XXX: Bit of a hack to avoid allocating a slice
	const vec = (&file.vbuf: *[*]io::vector)[..1];
	return readv(file, cb, vec...);
};

// Schedules a vectored read operation on a file object.
export fn readv(
	file: *file,
	cb: *readcb,
	vec: io::vector...
) req = {
	assert(file.op == op::NONE);
	file.op = op::READV;
	file.cb = cb;
	file.vec = vec;
	filemod(file, rt::EPOLLOUT);
	return req { ... };
};

fn readv_finish(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op == op::READV && ev.events & rt::EPOLLIN != 0);
	assert(file.cb != null);
	const r = io::readv(file.fd, file.vec...);
	const cb = file.cb: *readcb;
	cb(file, r);
	file.op = op::NONE;
};

// A callback for a [[write]] or [[writev]] operation.
export type writecb = *fn(file: *file, result: (size | io::error)) void;

// Schedules a write operation on a file object.
export fn write(
	file: *file,
	cb: *writecb,
	buf: []u8,
) req = {
	file.vbuf = io::mkvector(buf);
	// XXX: Bit of a hack to avoid allocating a slice
	const vec = (&file.vbuf: *[*]io::vector)[..1];
	return writev(file, cb, vec...);
};

// Schedules a vectored read operation on a file object.
export fn writev(
	file: *file,
	cb: *writecb,
	vec: io::vector...
) req = {
	// XXX: Should we support both pending reads and writes at the same
	// time? (yes)
	assert(file.op == op::NONE);
	file.op = op::WRITEV;
	file.cb = cb;
	file.vec = vec;
	filemod(file, rt::EPOLLOUT);
	return req { ... };
};

fn writev_finish(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op == op::WRITEV && ev.events & rt::EPOLLOUT != 0);
	assert(file.cb != null);
	const r = io::writev(file.fd, file.vec...);
	const cb = file.cb: *writecb;
	cb(file, r);
	file.op = op::NONE;
};
