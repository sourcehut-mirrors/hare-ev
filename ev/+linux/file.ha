use errors;
use io;
use net;
use net::ip;
use rt;
use unix::signal;

export type op = enum u64 {
	NONE     = 0,
	READV    = 1 << 0,
	WRITEV   = 1 << 1,

	READABLE    = 1 << 16,
	WRITABLE    = 2 << 16,
	ACCEPT      = 3 << 16,
	CONNECT_TCP = 4 << 16,
	SIGNAL      = 5 << 16,
	TIMER       = 6 << 16,
	SENDTO      = 7 << 16,
	RECVFROM    = 8 << 16,
	SEND        = 9 << 16,
	RECV        = 10 << 16,
};

export type fflags = enum uint {
	NONE = 0,
	BLOCKING = 1 << 31,
};

export type file = struct {
	fd: io::file,
	ev: *loop,

	flags: fflags,
	op: op,
	cb: nullable *opaque,
	cb2: nullable *opaque,
	user: nullable *opaque,

	// Operation-specific data
	union {
		struct {
			rvbuf: rt::iovec,
			rvec: []rt::iovec,
			wvbuf: rt::iovec,
			wvec: []rt::iovec,
		},
		sockflag: net::sockflag,
		sigmask: signal::sigset,
		sendrecv: struct {
			sbuf: []u8,
			rbuf: []u8,
			dest: ip::addr,
			port: u16,
		},
	},
};

// Registers a file descriptor with an event loop.
export fn register(
	loop: *loop,
	fd: io::file,
) (*file | errors::error) = {
	const file = alloc(file {
		flags = fflags::NONE,
		fd = fd,
		ev = loop,
		op = op::NONE,
		...
	});

	let ev = rt::epoll_event {
		events = 0,
		data = rt::epoll_data {
			fd = 0,
		}
	};
	ev.data.ptr = file;
	match (rt::epoll_ctl(loop.fd, rt::EPOLL_CTL_ADD, fd, &ev)) {
	case void =>
		yield;
	case let err: rt::errno =>
		if (err == rt::EPERM) {
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
	if (file.op == op::SIGNAL) {
		signal_restore(file);
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
export fn setuser(file: *file, user: nullable *opaque) void = {
	file.user = user;
};

// Returns the user data field from this file object. If the field was null, an
// assertion is raised.
export fn getuser(file: *file) *opaque = {
	return file.user as *opaque;
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
	if (file.op & op::READV != 0 || file.op == op::READABLE) {
		events |= rt::EPOLLIN | rt::EPOLLHUP;
	};
	if (file.op & op::WRITEV != 0 || file.op == op::WRITABLE) {
		events |= rt::EPOLLOUT | rt::EPOLLHUP;
	};
	switch (file.op) {
	case op::ACCEPT =>
		events |= rt::EPOLLIN;
	case op::CONNECT_TCP =>
		events |= rt::EPOLLOUT;
	case op::SIGNAL =>
		events |= rt::EPOLLIN;
	case op::TIMER =>
		events &= ~rt::EPOLLONESHOT;
		events |= rt::EPOLLIN;
	case op::SEND, op::SENDTO =>
		events |= rt::EPOLLOUT;
	case op::RECV, op::RECVFROM =>
		events |= rt::EPOLLIN;
	case =>
		yield;
	};

	let ev = rt::epoll_event {
		events = events,
		data = rt::epoll_data {
			fd = 0,
		},
	};
	ev.data.ptr = file;
	// This can only fail under conditions associated with EPOLLEXCLUSIVE,
	// which we do not support.
	rt::epoll_ctl(file.ev.fd, rt::EPOLL_CTL_MOD, file.fd, &ev)!;
};
