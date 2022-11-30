use errors;
use io;
use rt;
use time;
use types;

export type loop = struct {
	fd: io::file,
	events: []rt::epoll_event,
};

// Creates a new event loop. The user must pass the return value to
// [[loop_finish]] to free associated resources when done using the loop.
export fn newloop() (loop | errors::error) = {
	const fd = match (rt::epoll_create1(rt::EPOLL_CLOEXEC)) {
	case let fd: int =>
		yield fd: io::file;
	case let err: rt::errno =>
		return errors::errno(err);
	};

	return loop {
		fd = fd,
		events = [],
	};
};

// Frees resources associated with an event loop. Must only be called once per
// event loop object.
export fn loop_finish(loop: *loop) void = {
	io::close(loop.fd)!;
};

// Returns an [[io::file]] for this event loop which can be polled on when
// events are available for processing, for chaining together different event
// loops. The exact semantics of this function are platform-specific, and it may
// not be available for all implementations.
export fn loop_file(loop: *loop) io::file = {
	return loop.fd;
};

// Dispatches the event loop. A duration of -1 specifies an indefinite timeout,
// and will cause dispatch to block until the next event is available.
//
// Portable use of the timeout argument supports only millisecond granularity of
// up to 24 days (INT_MAX milliseconds). Negative values other than -1 will
// cause the program to abort.
//
// Returns false if there are no events to process.
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
	if (len(loop.events) == 0) {
		return false;
	};
	// TODO: Deal with signals
	const maxev = len(loop.events);
	assert(maxev <= types::INT_MAX: size, "ev::dispatch: too many events");
	const events = rt::epoll_pwait(
		loop.fd,
		&loop.events[0],
		maxev: int,
		millis,
		null)!;
	return true;
};
