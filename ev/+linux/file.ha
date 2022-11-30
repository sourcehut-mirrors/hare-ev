use errors;
use io;
use rt;

export type file = struct {
	fd: io::file,
};

// Registers a file descriptor with an event loop.
export fn register(
	loop: *loop,
	fd: io::file,
) (*file | errors::error) = {
	const file = alloc(file {
		fd = fd,
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
