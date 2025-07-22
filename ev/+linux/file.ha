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
	SENDTO   = 1 << 2,
	RECVFROM = 1 << 3,
	SEND     = 1 << 4,
	RECV     = 1 << 5,

	READABLE     = 1 << 16,
	WRITABLE     = 2 << 16,
	ACCEPT       = 3 << 16,
	CONNECT_TCP  = 4 << 16,
	CONNECT_UNIX = 5 << 16,
	SIGNAL       = 6 << 16,
	TIMER        = 7 << 16,
	WAIT         = 12 << 16,
};

export type fflags = enum uint {
	NONE = 0,
	PAUSED = 1 << 30,
	BLOCKING = 1 << 31,
};

export type file = struct {
	fd: io::file,
	ev: *loop,

	flags: fflags,
	op: op,
	cb: nullable *opaque,
	user: nullable *opaque,

	prio: int,

	// In-flight request lists
	//
	// XXX: Not all of these are straightforwardly compatible, perhaps we
	// can deduplicate them. It doesn't make sense to have read and recv in
	// flight on the same file at once. In any case they aren't
	// distinguishable on our end so it will almost certainly cause
	// problems when the events come in.
	readv: req_list,
	writev: req_list,
	connect: nullable *sockreq, // only one at a time
	accept: req_list,
	recv: req_list,
	recvfrom: req_list,
	send: req_list,
	sendto: req_list,

	// Operation-specific data
	sigmask: signal::sigset,
};

// Initializes a file [[req]]est.
fn file_req_init(req: *req, cancel: *cancelfn) *file = {
	const file = match (req.file) {
	case let f: *file =>
		yield f;
	case null =>
		abort("Uninitialized file request, use e.g. ev::ioreq_init first");
	};
	req.cancel = cancel;
	file.ev.nrequest += 1;
	return file;
};

// Finishes a file [[req]]uest which has been completed or cancelled.
fn file_req_finish(req: *req, list: *req_list) void = {
	const file = req.file as *file;
	assert(file.ev.nrequest != 0);
	file.ev.nrequest -= 1;
	req_unlink(list, &req.link);
	req.cancel = null;
};

fn file_get_request(head: *req_list) *req = {
	const tail = match (head.tail) {
	case let req: *req_list =>
		yield req;
	case null =>
		abort("Invalid request list");
	};
	const offs = offset((null: *req).link): uintptr;
	return (tail: uintptr - offs): *req;
};

// Pauses a file object such that the loop will not listen to any events of
// the object. Use [[resume]] to enable events for this file object again.
export fn pause(file: *file) void = {
	assert(file.flags & fflags::PAUSED == 0);

	const loop = file.ev;
	if (file.flags & fflags::BLOCKING == 0) {
		// The only way that this could fail is in the event of a
		// use-after-free or if the user fucks around and constructs a
		// custom [[file]] which was never registered, so assert on
		// error.
		rt::epoll_ctl(loop.fd, rt::EPOLL_CTL_DEL, file.fd, null)!;
	};

	for (let ev &.. loop.events) {
		if (file != ev.data.ptr) {
			continue;
		};
		ev.events = 0;
		ev.data.ptr = null: *opaque;
		ev.data.fd = 0;
		break;
	};

	file.flags |= fflags::PAUSED;
};

// Continues to listen for events on the 'file' object.
export fn resume(file: *file) (void | errors::error) = {
	assert(file.flags & fflags::PAUSED == fflags::PAUSED);

	if (file.flags & fflags::BLOCKING != 0) {
		file.flags &= ~fflags::PAUSED;
		return;
	};

	let fd = file.fd;
	let ev = rt::epoll_event {
		events = 0,
		data = rt::epoll_data {
			fd = 0,
			ptr = file,
		}
	};
	match (rt::epoll_ctl(file.ev.fd, rt::EPOLL_CTL_ADD, fd, &ev)) {
	case void =>
		yield;
	case let err: rt::errno =>
		if (err != rt::EPERM) {
			return errors::errno(err);
		};
		// epoll(2) does not support regular files, use blocking
		// I/O instead
		file.flags = fflags::BLOCKING;
	};

	file.flags &= ~fflags::PAUSED;
};

// Registers a file descriptor with an event loop.
export fn register(
	loop: *loop,
	fd: io::file,
	user: nullable *opaque = null,
) (*file | errors::error | nomem) = {
	const file = alloc(file {
		flags = fflags::PAUSED,
		fd = fd,
		ev = loop,
		op = op::NONE,
		user = user,
		...
	})?;
	resume(file)?;
	return file;
};

// Unregisters a file object with an event loop and frees resources associated
// with it. Does not close the underlying file descriptor.
export fn unregister(file: *file) void = {
	pause(file);
	if (file.op == op::SIGNAL) {
		signal_restore(file);
	};
	free(file);
};

// Unregisters a file object with an event loop, frees resources associated with
// it, and closes the underlying file descriptor.
export fn close(file: *file) void = {
	const fd = file.fd;
	if (file.flags & fflags::PAUSED == 0) {
		pause(file);
	};
	if (file.op == op::SIGNAL) {
		signal_restore(file);
	};
	free(file);
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

// Sets the priority on this file object. Used to priorize concurrent events,
// starting on the next dispatch. The lowest run first.
export fn setprio(file: *file, prio: int) void = {
	file.prio = prio;
};

fn sort_events(a: const *opaque, b: const *opaque) int = {
	const a = a: *rt::epoll_event;
	const b = b: *rt::epoll_event;

	if (a.data.fd == 0 || b.data.fd == 0) {
		return 0;
	};

	const a = a.data.ptr: *file;
	const b = b.data.ptr: *file;

	return a.prio - b.prio;
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
	if (file.op & op::RECV != 0 || file.op & op::RECVFROM != 0) {
		events |= rt::EPOLLIN;
	};
	if (file.op & op::SEND != 0 || file.op & op::SENDTO != 0) {
		events |= rt::EPOLLOUT;
	};

	switch (file.op) {
	case op::ACCEPT =>
		events |= rt::EPOLLIN;
	case op::CONNECT_TCP, op::CONNECT_UNIX =>
		events |= rt::EPOLLOUT;
	case op::SIGNAL =>
		events |= rt::EPOLLIN;
	case op::TIMER =>
		events &= ~rt::EPOLLONESHOT;
		events |= rt::EPOLLIN;
	case op::WAIT =>
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
