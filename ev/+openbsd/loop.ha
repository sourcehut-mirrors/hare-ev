use errors;
use io;
use sort;
use sys;
use time;
use types;

// Dispatch callback. See [[do]].
export type dispatchcb = fn(loop: *loop, user: nullable *opaque) void;

export type ondispatch = struct {
	cb: *dispatchcb,
	user: nullable *opaque,
	loop: *loop,
};

// TODO: Temporary placeholder for req.ha.
// TODO: Will be implemented with I/O.
export type file = bool;

export type loop = struct {
	fd: io::file,
	events: []sys::kevent,
	dispatch: []*ondispatch,
	nrequest: uint,
	flags: loop_flag,
};

export type loop_flag = enum uint {
	NONE = 0,
	STOP = 1 << 0,
	DISPATCH = 1 << 1,
};

// Creates a new event loop. The user must pass the return value to [[finish]]
// to free associated resources when done using the loop.
//
// The optional "events" parameter controls how many events may be pending at
// once. Most applications should not need to configure this parameter.
export fn newloop(events: size = 256) (loop | nomem | errors::error) = {
	const fd = match (sys::kqueue1(sys::O_CLOEXEC)) {
	case let fd: int =>
		yield fd: io::file;
	case let err: sys::errno =>
		return errors::errno(err);
	};

	return loop {
		fd = fd,
		events = alloc([sys::kevent { ... }], events)?,
		flags = loop_flag::NONE,
		...
	};
};

// Frees resources associated with an event loop. Must only be called once per
// event loop object. Calling finish invalidates all I/O objects associated with
// the event loop.
export fn finish(loop: *loop) void = {
	free(loop.events);
	for (let dispatch .. loop.dispatch) {
		free(dispatch);
	};
	free(loop.dispatch);
	io::close(loop.fd)!;
};

// Returns an [[io::file]] for this event loop which can be polled on when
// events are available for processing, for chaining together different event
// loops. The exact semantics of this function are platform-specific, and it may
// not be available for all implementations.
export fn loop_file(loop: *loop) io::file = {
	return loop.fd;
};

// Registers a callback to be invoked before the next call to [[dispatch]]
// processes requests. The callback may schedule additional I/O requests to be
// processed in this batch.
//
// Dispatch callbacks are only called once. If you wish to schedule another
// dispatch callback after the first, call [[do]] again.
export fn do(
	loop: *loop,
	cb: *dispatchcb,
	user: nullable *opaque = null,
) (void | nomem) = {
	const dispatch = alloc(ondispatch {
		cb = cb,
		user = user,
		loop = loop,
	})?;
	append(loop.dispatch, dispatch)?;
};

fn proc_closeq(loop: *loop) void = {
	// TODO: Will be implemented with I/O.
	return;
};

fn proc_blockq(loop: *loop) size = {
	return 0;
};

// Dispatches the event loop, waiting for new events and calling their callbacks
// as appropriate.
//
// A timeout of -1 will block indefinitely until the next event occurs. A
// timeout of 0 will cause dispatch to return immediately if no events are
// available to process. Portable use of the timeout argument supports only
// millisecond granularity of up to 24 days ([[types::INT_MAX]] milliseconds).
// Negative values other than -1 will cause the program to abort.
//
// Returns false if the loop has been stopped via [[stop]], or true otherwise.
export fn dispatch(
	loop_: *loop,
	timeout: time::duration = -1,
) (bool | errors::error | nomem) = {
	let ts: nullable *const sys::timespec = null;
	if (timeout >= 0) {
		let timespec = time::duration_to_timespec(timeout);
		ts = &timespec;
	};

	if (loop_.flags & loop_flag::STOP != 0) {
		return false;
	};

	loop_.flags |= loop_flag::DISPATCH;
	defer {
		loop_.flags &= ~loop_flag::DISPATCH;
		proc_closeq(loop_);
	};

	let dispatched = false;
	let todo = loop_.dispatch;
	loop_.dispatch = [];
	for (let dispatch .. todo) {
		dispatch.cb(loop_, dispatch.user);
		free(dispatch);
		dispatched = true;
	};
	free(todo);

	if (loop_.nrequest == 0) {
		if (loop_.flags & loop_flag::STOP != 0) {
			return false;
		};

		if (dispatched || len(loop_.dispatch) > 0) {
			return true;
		};

		abort("No action pending");
	};

	if (len(loop_.events) == 0 || loop_.flags & loop_flag::STOP != 0) {
		return true;
	};

	if (proc_blockq(loop_) != 0) {
		return loop_.flags & loop_flag::STOP == 0;
	};

	const maxev = len(loop_.events);
	assert(maxev <= types::INT_MAX: size, "ev::dispatch: too many events");
	const nevent = match (sys::kevent_poll(
		loop_.fd,
		null, 0,
		&loop_.events[0]: *[*]sys::kevent, maxev: int,
		ts)) {
	case let nevent: int =>
		yield nevent;
	case let err: sys::errno =>
		switch (err) {
		case sys::EINTR =>
			return true;
		case =>
			abort("ev::dispatch: kevent failure");
		};
	};

	if (nevent == 0) {
		return true;
	};

	for (let ev &.. loop_.events[..nevent]) {
		let udata = ev.udata;
		if (udata == null) {
			continue;
		};

		switch (ev.filter) {
		case sys::EVFILT_TIMER =>
			const timer = match (udata) {
			case let t: *opaque =>
				yield t: *timer;
			case =>
				abort("ev::dispatch: unexpected udata type");
			};
			timer_ready(timer, ev)?;
		case sys::EVFILT_SIGNAL =>
			const sig = match (udata) {
			case let s: *opaque =>
				yield s: *signal;
			case =>
				abort("ev::dispatch: unexpected udata type");
			};
			signal_ready(sig, ev)?;
		case =>
			// TODO: EVFILT_PROC
			// TODO: EVFILT_READ/EVFILT_WRITE
			abort("ev::dispatch: unsupported filter");
		};
	};

	return loop_.flags & loop_flag::STOP == 0;
};

// Runs the event loop (via [[dispatch]]) until all in-flight requests have been
// processed, or [[stop]] is called, then returns.
export fn run(loop_: *loop) (void | errors::error | nomem) = {
	for (loop_.nrequest != 0) {
		if (!dispatch(loop_, -1)?) {
			break;
		};
	};
};

// Signals the loop to stop processing events. If called during a callback, it
// will cause that invocation of [[dispatch]] to return false. Otherwise, false
// will be returned only upon the next call to [[dispatch]].
export fn stop(loop: *loop) void = {
	loop.flags |= loop_flag::STOP;
};
