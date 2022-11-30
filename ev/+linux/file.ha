use errors;
use io;
use rt;

export type op = enum {
	NONE,
	READV,
	WRITEV,
};

export type file = struct {
	fd: io::file,
	ev: *loop,
	// Pending operation on this file object
	op: op,
	cb: nullable *void,

	// Operation-specific data
	vbuf: rt::iovec,
	union {
		vec: []rt::iovec,
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
		return errors::errno(err);
	};

	return file;
};

// Unregisters a file object with an event loop and frees resources associated
// with it. Does not close the underlying file descriptor.
export fn unregister(loop: *loop, file: *file) void = {
	// The only way that this could fail is in the event of a use-after-free
	// or if the user fucks around and constructs a custom [[file]] which
	// was never registered, so assert on error.
	rt::epoll_ctl(loop.fd, rt::EPOLL_CTL_DEL, file.fd, null)!;
	free(file);
};

// Modifies the epoll events for a given file. For internal use.
fn filemod(file: *file, events: u32) void = {
	let ev = rt::epoll_event {
		events = events,
		...
	};
	ev.data.ptr = file;
	// This can only fail under conditions associated with EPOLLEXCLUSIVE,
	// which we do not support.
	rt::epoll_ctl(file.ev.fd, rt::EPOLL_CTL_MOD, file.fd, &ev)!;
};
