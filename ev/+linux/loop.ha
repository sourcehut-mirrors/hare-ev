use errors;
use io;
use rt;
use sort;
use time;
use types;
use unix::signal;

// Dispatch callback. See [[ondispatch]].
export type dispatchcb = fn(loop: *loop, user: nullable *opaque) void;

export type ondispatch = struct {
	cb: *dispatchcb,
	user: nullable *opaque,
	loop: *loop,
};

export type loop = struct {
	fd: io::file,
	events: []rt::epoll_event,
	dispatch: []*ondispatch,
	nrequest: uint,
	stop: bool,
};

// Finishes a loop [[req]]uest which has been completed or cancelled.
fn loop_req_finish(req: *req) void = {
	const file = req.file as *file;
	assert(file.ev.nrequest != 0);
	file.ev.nrequest -= 1;
	req.cancel = null;
	req.loop = file.ev;
};

// Creates a new event loop. The user must pass the return value to [[finish]]
// to free associated resources when done using the loop.
//
// The optional "events" parameter controls how many events may be pending at
// once. Most applications should not need to configure this parameter.
export fn newloop(events: size = 256) (loop | nomem | errors::error) = {
	const fd = match (rt::epoll_create1(rt::EPOLL_CLOEXEC)) {
	case let fd: int =>
		yield fd: io::file;
	case let err: rt::errno =>
		return errors::errno(err);
	};

	return loop {
		fd = fd,
		events = alloc([rt::epoll_event {
			events = 0,
			data = rt::epoll_data {
				fd = 0,
			}
		}...], events)?,
		dispatch = [],
		nrequest = 0,
		stop = false,
	};
};

// Frees resources associated with an event loop. Must only be called once per
// event loop object. Calling finish invalidates all I/O objects associated with
// the event loop.
export fn finish(loop: *loop) void = {
	free(loop.events);
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
) (req | nomem) = {
	const dispatch = alloc(ondispatch {
		cb = cb,
		user = user,
		loop = loop,
	})?;
	append(loop.dispatch, dispatch)?;
	return mkreq(null, &do_cancel, dispatch);
};

fn do_cancel(req: *req) void = {
	const dispatch = req.user: *ondispatch;
	const loop = dispatch.loop;
	for (let i = 0z; i < len(loop.dispatch); i += 1) {
		if (loop.dispatch[i] == dispatch) {
			delete(loop.dispatch[i]);
			break;
		};
	};
	free(dispatch);
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
	loop: *loop,
	timeout: time::duration = -1,
) (bool | errors::error) = {
	const millis: int = if (timeout == -1) {
		yield -1;
	} else if (timeout < 0) {
		abort("ev::dispatch: invalid timeout");
	} else {
		yield (timeout / time::MILLISECOND): int;
	};
	if (loop.stop) {
		return false;
	};

	let todo = loop.dispatch;
	loop.dispatch = [];
	for (let dispatch .. todo) {
		dispatch.cb(loop, dispatch.user);
		free(dispatch);
	};
	free(todo);

	if (len(loop.events) == 0 || loop.stop) {
		return true;
	};

	// TODO: Deal with signals
	const maxev = len(loop.events);
	assert(maxev <= types::INT_MAX: size, "ev::dispatch: too many events");
	const nevent = match(rt::epoll_pwait(
		loop.fd, &loop.events[0],
		maxev: int, millis, null)) {
	case let nevent: int =>
		yield nevent;
	case let err: rt::errno =>
		switch (err) {
		case rt::EINTR =>
			// We shallow system suspension error code
			return true;
		case =>
			abort("ev::dispatch: epoll_pwait failure");
		};
	};

	if (nevent == 0) {
		return true;
	};

	sort::sort(loop.events[..nevent], size(rt::epoll_event), &sort_events)!;

	for (let ev &.. loop.events[..nevent]) {
		const file = ev.data.ptr: *file;
		if (ev.events == 0) {
			continue;
		};
		const pending = file.op;
		if (ev.events & (rt::EPOLLIN | rt::EPOLLHUP) != 0
				&& file.op & op::READV != 0) {
			readv_ready(file, ev);
		};
		if (ev.events & (rt::EPOLLOUT | rt::EPOLLHUP) != 0
				&& file.op & op::WRITEV != 0) {
			writev_ready(file, ev);
		};

		if (ev.events & (rt::EPOLLIN | rt::EPOLLHUP) != 0
				&& file.op & op::RECV != 0) {
			recv_ready(file, ev);
		};
		if (ev.events & (rt::EPOLLIN | rt::EPOLLHUP) != 0
				&& file.op & op::RECVFROM != 0) {
			recvfrom_ready(file, ev);
		};
		if (ev.events & (rt::EPOLLOUT | rt::EPOLLHUP) != 0
				&& file.op & op::SEND != 0) {
			send_ready(file, ev);
		};
		if (ev.events & (rt::EPOLLOUT | rt::EPOLLHUP) != 0
				&& file.op & op::SENDTO != 0) {
			sendto_ready(file, ev);
		};

		switch (pending) {
		case op::NONE =>
			abort("No operation pending for ready object");
		case op::READABLE =>
			readable_ready(file, ev);
		case op::WRITABLE =>
			writable_ready(file, ev);
		case op::ACCEPT =>
			accept_ready(file, ev);
		case op::CONNECT_TCP =>
			connect_tcp_ready(file, ev);
		case op::CONNECT_UNIX =>
			connect_unix_ready(file, ev);
		case op::SIGNAL =>
			signal_ready(file, ev);
		case op::TIMER =>
			timer_ready(file, ev);
		case op::WAIT =>
			wait_ready(file, ev);
		case => void;
		};
	};

	return !loop.stop;
};

// Runs the event loop (via [[dispatch]]) until all in-flight requests have been
// processed, or [[stop]] is called, then returns.
export fn run(loop: *loop) (void | errors::error) = {
	for (loop.nrequest != 0) {
		if (!dispatch(loop, -1)?) {
			break;
		};
	};
};

// Signals the loop to stop processing events. If called during a callback, it
// will cause that invocation of [[dispatch]] to return false. Otherwise, false
// will be returned only upon the next call to [[dispatch]].
export fn stop(loop: *loop) void = {
	loop.stop = true;
};
