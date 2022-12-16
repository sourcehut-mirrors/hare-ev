use rt;

// A callback for a [[readable]] operation.
export type readablecb = fn(file: *file) void;

// Executes the callback when a given file is readable. Cannot be combined with
// [[read]] or [[readv]].
export fn readable(
	file: *file,
	cb: *readablecb,
) req = {
	assert(file.op & op::READABLE == 0 && file.op & op::READV == 0);
	if (file.flags & fflags::BLOCKING != 0) {
		cb(file);
		return req { ... };
	};

	file.op |= op::READABLE;
	file.cb = cb;
	file_epoll_ctl(file);
	return req { ... };
};

fn readable_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op & op::READABLE != 0);
	assert(file.cb != null);
	const cb = file.cb: *readablecb;
	file.op &= ~op::READABLE;
	file_epoll_ctl(file);
	cb(file);
};

// A callback for a [[writable]] operation.
export type writablecb = fn(file: *file) void;

// Executes the callback when a given file is writable. Cannot be combined with
// [[write]] or [[writev]].
export fn writable(
	file: *file,
	cb: *writablecb,
) req = {
	assert(file.op & op::WRITABLE == 0 && file.op & op::WRITEV == 0);
	if (file.flags & fflags::BLOCKING != 0) {
		cb(file);
		return req { ... };
	};

	file.op |= op::WRITABLE;
	file.cb = cb;
	file_epoll_ctl(file);
	return req { ... };
};

fn writable_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op & op::WRITABLE != 0);
	assert(file.cb != null);
	const cb = file.cb: *writablecb;
	file.op &= ~op::WRITABLE;
	file_epoll_ctl(file);
	cb(file);
};
