use errors;
use io;
use rt;
use time;
use types;
use unix::signal;

export type loop = struct {
	fd: io::file,
	events: []rt::epoll_event,
	stop: bool,
};

// Creates a new event loop. The user must pass the return value to [[finish]]
// to free associated resources when done using the loop.
export fn newloop() (loop | errors::error) = {
	const fd = match (rt::epoll_create1(rt::EPOLL_CLOEXEC)) {
	case let fd: int =>
		yield fd: io::file;
	case let err: rt::errno =>
		return errors::errno(err);
	};

	return loop {
		fd = fd,
		// XXX: Should the number of events be customizable?
		events = alloc([rt::epoll_event {
			events = 0,
			data = rt::epoll_data {
				fd = 0,
			}
		}...], 256),
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
	timeout: time::duration,
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
	if (len(loop.events) == 0) {
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

	for (let i = 0; i < nevent; i += 1) {
		const ev = &loop.events[i];
		const file = ev.data.ptr: *file;
		if (ev.events == 0) {
			continue;
		};
		const pending = file.op;
		if (ev.events & (rt::EPOLLIN | rt::EPOLLHUP) != 0
				&& pending & op::READV != 0) {
			readv_ready(file, ev);
		};
		if (ev.events & (rt::EPOLLOUT | rt::EPOLLHUP) != 0
				&& pending & op::WRITEV != 0) {
			writev_ready(file, ev);
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
		case op::SIGNAL =>
			signal_ready(file, ev);
		case op::TIMER =>
			timer_ready(file, ev);
		case op::SENDTO =>
			sendto_ready(file, ev);
		case op::RECVFROM =>
			recvfrom_ready(file, ev);
		case op::SEND =>
			send_ready(file, ev);
		case op::RECV =>
			recv_ready(file, ev);
		case =>
			assert(pending & ~(op::READV | op::WRITEV) == 0);
		};
	};

	return !loop.stop;
};

// Signals the loop to stop processing events. If called during a callback, it
// will cause that invocation of [[dispatch]] to return false. Otherwise, false
// will be returned only upon the next call to [[dispatch]].
export fn stop(loop: *loop) void = {
	loop.stop = true;
};
