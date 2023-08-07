use io;
use rt;

// A callback for a [[read]] or [[readv]] operation.
export type readcb = fn(file: *file, result: (size | io::EOF | io::error)) void;

// Schedules a read operation on a file object. The provided buffer must be
// valid for the duration of the read operation.
export fn read(
	file: *file,
	cb: *readcb,
	buf: []u8,
) req = {
	file.rvbuf = io::mkvector(buf);
	// XXX: Bit of a hack to avoid allocating a slice
	const vec = (&file.rvbuf: *[*]io::vector)[..1];
	return readv(file, cb, vec...);
};

// Schedules a vectored read operation on a file object. The provided vectors
// must be valid for the duration of the read operation.
export fn readv(
	file: *file,
	cb: *readcb,
	vec: io::vector...
) req = {
	assert(file.op & op::READV == 0);
	if (file.flags & fflags::BLOCKING != 0) {
		const r = io::readv(file.fd, vec...);
		cb(file, r);
		return req { ... };
	};

	file.op |= op::READV;
	file.cb = cb;
	file.rvec = vec: []rt::iovec;
	file_epoll_ctl(file);
	return req { ... };
};

fn readv_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op & op::READV != 0);
	assert(file.cb != null);
	const cb = file.cb: *readcb;
	file.op &= ~op::READV;
	file_epoll_ctl(file);

	if (ev.events & rt::EPOLLHUP != 0) {
		cb(file, io::EOF);
	} else {
		const vec = file.rvec: []io::vector;
		const r = io::readv(file.fd, vec...);
		cb(file, r);
	};
};

// A callback for a [[write]] or [[writev]] operation.
export type writecb = fn(file: *file, result: (size | io::error)) void;

// Schedules a write operation on a file object. The provided buffer must be
// valid for the duration of the write operation.
export fn write(
	file: *file,
	cb: *writecb,
	buf: []u8,
) req = {
	file.wvbuf = io::mkvector(buf);
	// XXX: Bit of a hack to avoid allocating a slice
	const vec = (&file.wvbuf: *[*]io::vector)[..1];
	return writev(file, cb, vec...);
};

// Schedules a vectored read operation on a file object. The provided buffer
// must be valid for the duration of the write operation.
export fn writev(
	file: *file,
	cb: *writecb,
	vec: io::vector...
) req = {
	assert(file.op & op::WRITEV == 0);
	if (file.flags & fflags::BLOCKING != 0) {
		const r = io::writev(file.fd, vec...);
		cb(file, r);
		return req { ... };
	};

	file.op |= op::WRITEV;
	file.cb2 = cb;
	file.wvec = vec: []rt::iovec;
	file_epoll_ctl(file);
	return req { ... };
};

fn writev_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op & op::WRITEV != 0);
	assert(file.cb != null);
	const vec = file.wvec: []io::vector;
	const r = io::writev(file.fd, vec...);
	const cb = file.cb2: *writecb;
	file.op &= ~op::WRITEV;
	file_epoll_ctl(file);
	cb(file, r);
};
