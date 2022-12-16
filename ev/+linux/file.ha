use errors;
use io;
use net;
use rt;

export type op = enum u64 {
	NONE    = 0,
	READV   = 1 << 0,
	WRITEV  = 1 << 1,
	ACCEPT  = 1 << 2,
	CONNECT = 1 << 3,
};

export type fflags = enum uint {
	BLOCKING = 1 << 31,
};

export type file = struct {
	fd: io::file,
	ev: *loop,

	flags: fflags,
	op: op,
	cb: nullable *void,
	cb2: nullable *void,
	user: nullable *void,

	// Operation-specific data
	union {
		struct {
			rvbuf: rt::iovec,
			rvec: []rt::iovec,
			wvbuf: rt::iovec,
			wvec: []rt::iovec,
		},
		sockflags: net::sockflags,
	},
};

// Registers a file descriptor with an event loop.
export fn register(
	loop: *loop,
	fd: io::file,
) (*file | errors::error) = {
	const file = alloc(file {
		fd = fd,
		ev = loop,
		op = op::NONE,
		...
	});

	let ev = rt::epoll_event {
		events = 0,
		...
	};
	ev.data.ptr = file;
	match (rt::epoll_ctl(loop.fd, rt::EPOLL_CTL_ADD, fd, &ev)) {
	case void =>
		yield;
	case let err: rt::errno =>
		if (err: int == rt::EPERM) {
			// epoll(2) does not support regular files, use blocking
			// I/O instead
			file.flags = fflags::BLOCKING;
			return file;
		};
		return errors::errno(err);
	};

	return file;
};

// Unregisters a file object with an event loop and frees resources associated
// with it. Does not close the underlying file descriptor.
export fn unregister(file: *file) void = {
	const loop = file.ev;
	if (file.flags & fflags::BLOCKING == 0) {
		// The only way that this could fail is in the event of a
		// use-after-free or if the user fucks around and constructs a
		// custom [[file]] which was never registered, so assert on
		// error.
		rt::epoll_ctl(loop.fd, rt::EPOLL_CTL_DEL, file.fd, null)!;
	};
	free(file);
};

// Unregisters a file object with an event loop, frees resources associated with
// it, and closes the underlying file descriptor.
export fn close(file: *file) void = {
	const fd = file.fd;
	unregister(file);
	io::close(fd)!;
};

// Sets the user data field on this file object to the provided object.
export fn setuser(file: *file, user: nullable *void) void = {
	file.user = user;
};

// Returns the user data field from this file object. If the field was null, an
// assertion is raised.
export fn getuser(file: *file) *void = {
	return file.user as *void;
};

// Returns the file descriptor for a given file. Note that ev assumes that it
// will be responsible for all I/O on the file and any user modifications may
// cause the event loop to enter an invalid state.
export fn getfd(file: *file) io::file = {
	return file.fd;
};

// Returns the event loop for a given file.
export fn getloop(file: *file) *loop = {
	return file.ev;
};

// Updates epoll events for a given file. For internal use.
fn file_epoll_ctl(file: *file) void = {
	let events = rt::EPOLLONESHOT;
	if (file.op & op::READV != 0) {
		events |= rt::EPOLLIN | rt::EPOLLHUP;
	};
	if (file.op & op::WRITEV != 0) {
		events |= rt::EPOLLOUT | rt::EPOLLHUP;
	};
	if (file.op & op::ACCEPT != 0) {
		events |= rt::EPOLLIN;
	};
	if (file.op & op::CONNECT != 0) {
		events |= rt::EPOLLOUT;
	};

	let ev = rt::epoll_event {
		events = events,
		...
	};
	ev.data.ptr = file;
	// This can only fail under conditions associated with EPOLLEXCLUSIVE,
	// which we do not support.
	rt::epoll_ctl(file.ev.fd, rt::EPOLL_CTL_MOD, file.fd, &ev)!;
};
