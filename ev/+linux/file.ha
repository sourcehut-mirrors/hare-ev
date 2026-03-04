use errors;
use io;
use net;
use net::ip;
use sys;
use unix::signal;

export type op = enum u32 {
	NONE     = 0,

	READV     = 1 << 0,
	RECV      = 1 << 1,
	RECVFROM  = 1 << 2,
	READABLE  = 1 << 3,
	READ_MASK = 0xFF,

	WRITEV     = 1 << 8,
	SEND       = 1 << 9,
	SENDTO     = 1 << 10,
	WRITABLE   = 2 << 11,
	WRITE_MASK = 0xFF00,

	RW_MASK = 0xFFFF,

	ACCEPT       = 1 << 16,
	CONNECT_TCP  = 2 << 16,
	CONNECT_UNIX = 3 << 16,
	SIGNAL       = 4 << 16,
	TIMER        = 5 << 16,
	WAIT         = 6 << 16,
};

export type fflags = enum u32 {
	NONE = 0,
	CLOSING = 1 << 28,
	CLOSE = 1 << 29,
	PAUSED = 1 << 30,
	BLOCKING = 1 << 31,
};

export type file = struct {
	fd: io::file,
	ev: *loop,
	prio: int,

	op: op,
	flags: fflags,
	user: nullable *opaque,
	link: file_list,

	// Request queues
	readq: req_list,
	writeq: req_list,
	acceptq: req_list,

	// Serialized requests
	union {
		connect: nullable *sockreq,
		timer: nullable *timer,
		wait: nullable *child,
		signal: nullable *signal,
	},
};

// Enables the desired operation on a file and links the given request into the
// appropriate request queue.
fn file_begin(file: *file, req: *req, kind: op) void = {
	const read = kind & op::READ_MASK != 0;
	const write = kind & op::WRITE_MASK != 0;
	const mask: op =
		if (read) op::READ_MASK
		else if (write) op::WRITE_MASK
		else ~op::RW_MASK;

	const prev = file.op & mask;
	assert(prev == op::NONE || prev == kind,
		"Attempted to schedule incompatible I/O requests in parallel, "
		"e.g. read and recv");

	file.op |= kind;

	if (file.flags & fflags::BLOCKING == 0) {
		file_epoll_ctl(file);
	} else if (file_list_empty(&file.link)) {
		file_link(&file.ev.blockq, &file.link);
	};

	if (read) {
		req_link(&file.readq, &req.link);
	} else if (write) {
		req_link(&file.writeq, &req.link);
	};
};

fn file_end(file: *file, kind: op) void = {
	const read = kind & op::READ_MASK != 0;
	const write = kind & op::WRITE_MASK != 0;
	const mask: op =
		if (read) op::READ_MASK
		else if (write) op::WRITE_MASK
		else ~op::RW_MASK;

	const prev = file.op & mask;
	const paused = file.flags & fflags::PAUSED != 0;
	assert(prev == kind || prev == op::NONE || paused); // Invariant

	let reconfigure = false;
	if (read && req_list_empty(&file.readq)) {
		reconfigure = true;
		file.op &= ~op::READ_MASK;
	} else if (write && req_list_empty(&file.writeq)) {
		reconfigure = true;
		file.op &= ~op::WRITE_MASK;
	};

	if (!paused && reconfigure && file.flags & fflags::BLOCKING == 0) {
		file_epoll_ctl(file);
	};
};

// Initializes a file [[req]]est.
fn file_req_init(req: *req, cancel: nullable *cancelfn) *file = {
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
	req.cancel = null;
	req_unlink(list, &req.link);

	if (file.flags & fflags::BLOCKING != 0) {
		file_unlink(&file.ev.blockq, &file.link);
	};
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
		sys::epoll_ctl(loop.fd, sys::EPOLL_CTL_DEL, file.fd, null)!;
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
	let ev = sys::epoll_event {
		events = 0,
		data = sys::epoll_data {
			fd = 0,
			ptr = file,
		}
	};
	match (sys::epoll_ctl(file.ev.fd, sys::EPOLL_CTL_ADD, fd, &ev)) {
	case void =>
		yield;
	case let err: sys::errno =>
		if (err != sys::EPERM) {
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
//
// File closures requested during event callbacks are deferred until the end of
// the current [[dispatch]] call.
export fn unregister(file: *file) void = _unregister(file);

fn _unregister(file: *file) void = {
	const loop = file.ev;
	if (loop.flags & loop_flag::DISPATCH != 0) {
		file.flags |= fflags::CLOSING;
		file_link(&loop.closeq, &file.link);
		return;
	};

	const fd = file.fd;
	if (file.flags & fflags::PAUSED == 0) {
		pause(file);
	};
	if (file.flags & fflags::CLOSE != 0) {
		io::close(fd)!;
	};
	free(file);
};

// Unregisters a file object with an event loop, frees resources associated with
// it, and closes the underlying file descriptor.
//
// File closures requested during event callbacks are deferred until the end of
// the current [[dispatch]] call.
export fn close(file: *file) void = {
	file.flags |= fflags::CLOSE;
	_unregister(file);
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
	const a = a: *sys::epoll_event;
	const b = b: *sys::epoll_event;

	if (a.data.fd == 0 || b.data.fd == 0) {
		return 0;
	};

	const a = a.data.ptr: *file;
	const b = b.data.ptr: *file;

	return a.prio - b.prio;
};

// Updates epoll events for a given file. For internal use.
fn file_epoll_ctl(file: *file) void = {
	let events = sys::EPOLLONESHOT;

	switch (file.op & op::READ_MASK) {
	case op::READV, op::READABLE =>
		events |= sys::EPOLLIN | sys::EPOLLHUP;
	case op::RECV, op::RECVFROM =>
		events |= sys::EPOLLIN;
	case => void;
	};

	switch (file.op & op::WRITE_MASK) {
	case op::WRITEV, op::WRITABLE =>
		events |= sys::EPOLLOUT | sys::EPOLLHUP;
	case op::SEND, op::SENDTO =>
		events |= sys::EPOLLOUT;
	case => void;
	};

	switch (file.op & ~op::RW_MASK) {
	case op::ACCEPT =>
		events |= sys::EPOLLIN;
	case op::CONNECT_TCP, op::CONNECT_UNIX =>
		events |= sys::EPOLLOUT;
	case op::SIGNAL =>
		events |= sys::EPOLLIN;
	case op::TIMER =>
		events &= ~sys::EPOLLONESHOT;
		events |= sys::EPOLLIN;
	case op::WAIT =>
		events |= sys::EPOLLIN;
	case => void;
	};

	let ev = sys::epoll_event {
		events = events,
		data = sys::epoll_data {
			fd = 0,
		},
	};
	ev.data.ptr = file;
	// This can only fail under conditions associated with EPOLLEXCLUSIVE,
	// which we do not support.
	sys::epoll_ctl(file.ev.fd, sys::EPOLL_CTL_MOD, file.fd, &ev)!;
};
