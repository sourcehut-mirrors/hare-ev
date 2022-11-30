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
	file.callback = cb;
	file.vec = vec;
	filemod(file, rt::EPOLLOUT);
	return req { ... };
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
	file.callback = cb;
	file.vec = vec;
	filemod(file, rt::EPOLLOUT);
	return req { ... };
};
