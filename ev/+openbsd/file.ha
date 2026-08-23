use errors;
use io;
use sys;

export type op = enum u32 {
	NONE     = 0,

	READV     = 1 << 0,
	RECV      = 1 << 1,
	RECVFROM  = 1 << 2,
	READABLE  = 1 << 3,
	RECVMSG   = 1 << 4,
	READ_MASK = 0xFF,

	WRITEV     = 1 << 8,
	SEND       = 1 << 9,
	SENDTO     = 1 << 10,
	SENDMSG    = 1 << 11,
	WRITABLE   = 2 << 11,
	WRITE_MASK = 0xFF00,

	RW_MASK = 0xFFFF,

	ACCEPT       = 1 << 16,
	CONNECT_TCP  = 2 << 16,
	CONNECT_UNIX = 3 << 16,
};

export type fflags = enum u8 {
	NONE = 0,
	READ_REG = 1 << 0,  // EVFILT_READ is registered
	WRITE_REG = 1 << 1, // EVFILT_WRITE is registered
	CLOSING = 1 << 2,
	CLOSE = 1 << 3,
	PAUSED = 1 << 4,
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

	connect: nullable *sockreq,
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
	file_kevent_ctl(file);

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

	if (!paused && reconfigure) {
		file_kevent_ctl(file);
	};
};

// Initializes a file [[req]]est.
fn file_req_init(req: *req, cancel: nullable *cancelfn) *file = {
	const file = req_getfile(req) as *file;
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
	let nkevs = 0z;
	let kevs: [2]sys::kevent = [sys::kevent { ... }, sys::kevent { ... }];

	if (file.flags & fflags::READ_REG != 0) {
		kevs[nkevs] = sys::kevent {
			ident = file.fd: uintptr,
			filter = sys::EVFILT_READ,
			flags = sys::EV_DELETE,
			...
		};
		nkevs += 1;
	};

	if (file.flags & fflags::WRITE_REG != 0) {
		kevs[nkevs] = sys::kevent {
			ident = file.fd: uintptr,
			filter = sys::EVFILT_WRITE,
			flags = sys::EV_DELETE,
			...
		};
		nkevs += 1;
	};

	if (nkevs > 0) {
		match (sys::kevent_poll(loop.fd, &kevs: *[*]sys::kevent, nkevs: int, null, 0, null)) {
		case int => void;
		case sys::errno =>
			abort("pause: kevent_poll failure");
		};
	};

	file.flags &= ~(fflags::READ_REG | fflags::WRITE_REG);

	for (let ev &.. loop.events) {
		if (ev.udata == null || file: *opaque != ev.udata) {
			continue;
		};
		ev.udata = null;
		break;
	};

	file.flags |= fflags::PAUSED;
};

// Continues to listen for events on the 'file' object.
export fn resume(file: *file) (void | errors::error) = {
	assert(file.flags & fflags::PAUSED == fflags::PAUSED);
	file.flags &= ~fflags::PAUSED;
	file_kevent_ctl(file);
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

	if (file.flags & fflags::PAUSED == 0) {
		pause(file);
	};
	if (file.flags & fflags::CLOSE != 0) {
		io::close(file.fd)!;
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
	const a = a: *sys::kevent;
	const b = b: *sys::kevent;

	if (a.udata == null || b.udata == null) {
		return 0;
	};

	const fa = a.udata: *file;
	const fb = b.udata: *file;

	return fa.prio - fb.prio;
};

// kqueue filters are level-triggered; this is a no-op.
fn file_rearm(file: *file) void = void;

// Set up kevent filters for a given file.
fn file_kevent_ctl(file: *file) void = {
	if (file.flags & fflags::PAUSED != 0) {
		return;
	};

	const want_read = file.op & op::READ_MASK != 0
		|| file.op & ~op::RW_MASK == op::ACCEPT;
	const want_write = file.op & op::WRITE_MASK != 0
		|| file.op & ~op::RW_MASK == op::CONNECT_TCP
		|| file.op & ~op::RW_MASK == op::CONNECT_UNIX;

	const have_read = file.flags & fflags::READ_REG != 0;
	const have_write = file.flags & fflags::WRITE_REG != 0;

	if (want_read && !have_read) {
		let kev = sys::kevent {
			ident = file.fd: uintptr,
			filter = sys::EVFILT_READ,
			flags = sys::EV_ADD,
			udata = file,
			...
		};
		match (sys::kevent_poll(file.ev.fd, &kev: *[*]sys::kevent, 1, null, 0, null)) {
		case int =>
			file.flags |= fflags::READ_REG;
		case let err: sys::errno =>
			abort("ev::file_kevent_ctl: EVFILT_READ kevent failure");
		};
	} else if (!want_read && have_read) {
		let kev = sys::kevent {
			ident = file.fd: uintptr,
			filter = sys::EVFILT_READ,
			flags = sys::EV_DELETE,
			...
		};
		match (sys::kevent_poll(file.ev.fd, &kev: *[*]sys::kevent, 1, null, 0, null)) {
		case int =>
			file.flags &= ~fflags::READ_REG;
		case sys::errno =>
			abort("ev::file_kevent_ctl: EVFILT_READ kevent failure");
		};
	};

	if (want_write && !have_write) {
		let kev = sys::kevent {
			ident = file.fd: uintptr,
			filter = sys::EVFILT_WRITE,
			flags = sys::EV_ADD,
			udata = file,
			...
		};
		match (sys::kevent_poll(file.ev.fd, &kev: *[*]sys::kevent, 1, null, 0, null)) {
		case int =>
			file.flags |= fflags::WRITE_REG;
		case let err: sys::errno =>
			abort("ev::file_kevent_ctl: EVFILT_WRITE kevent failure");
		};
	} else if (!want_write && have_write) {
		let kev = sys::kevent {
			ident = file.fd: uintptr,
			filter = sys::EVFILT_WRITE,
			flags = sys::EV_DELETE,
			...
		};
		match (sys::kevent_poll(file.ev.fd, &kev: *[*]sys::kevent, 1, null, 0, null)) {
		case int =>
			file.flags &= ~fflags::WRITE_REG;
		case sys::errno =>
			abort("ev::file_kevent_ctl: EVFILT_WRITE kevent failure");
		};
	};
};
