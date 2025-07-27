use errors;
use io;
use rt;
use time;

// A callback which executes when a timer expires.
export type timercb = fn(req: *timer, user: nullable *opaque) void;

export type timer = struct {
	req,
	cb: nullable *timercb,
	delay: time::duration,
	repeat: time::duration,
};

// An uninitialized [[timer]] value. This can be used to statically
// initialize [[timer]] objects when [[timer_init]] is not applicable, for
// instance when storing an [[timer]] in a global.
export def TIMER_INIT = timer { ... };

// Initializes a [[timer]] to run on the specified event [[loop]]. The timer is
// initially unconfigured and will not fire any callbacks; see
// [[timer_configure]] to configure it.
//
// The caller must call [[timer_finish]] to free resources associated with this
// timer after use.
export fn timer_init(
	loop: *loop,
	clock: time::clock,
	cb: *timercb,
	user: nullable *opaque = null,
) (timer | errors::error | nomem) = {
	def FLAGS = rt::TFD_NONBLOCK | rt::TFD_CLOEXEC;
	const fd = match (rt::timerfd_create(clock, FLAGS)) {
	case let fd: int =>
		yield fd: io::file;
	case let errno: rt::errno =>
		return errors::errno(errno);
	};

	return timer {
		file = register(loop, fd)?,
		user = user,
		cb = cb,
		...
	};
};

// Frees resources associated with a [[timer]]. The timer is [[cancel]]ed if
// configured and removed from the associated event [[loop]].
export fn timer_finish(timer: *timer) void = {
	match (timer.file) {
	case null =>
		return; // Idempotency
	case let f: *file =>
		cancel(timer);
		close(f);
		timer.file = null;
	};
};

// Configures a timer created with [[timer_init]] to expire after the given
// "delay" and indefinitely thereafter following each interval of "repeat".
// Setting both values to zero disarms the timer; setting either value non-zero
// arms the timer.
export fn timer_configure(
	timer: *timer,
	delay: time::duration,
	repeat: time::duration,
) void = {
	const file = match (timer.file) {
	case let f: *file =>
		yield f;
	case null =>
		abort("timer_configure called with uninitialized timer object");
	};

	const spec = rt::itimerspec {
		it_value = time::duration_to_timespec(delay),
		it_interval = time::duration_to_timespec(repeat),
		...
	};
	rt::timerfd_settime(file.fd, 0, &spec, null)!;

	const was_armed = timer.delay != 0 || timer.repeat != 0;
	const is_armed = delay != 0 || repeat != 0;
	timer.delay = delay;
	timer.repeat = repeat;

	if (!was_armed && is_armed) {
		timer_arm(timer);
	};
	if (was_armed && !is_armed) {
		timer_disarm(timer);
	};
};

// Returns true if this [[timer]] is armed (and will eventually expire and run
// its callback).
export fn timer_armed(timer: *timer) bool = {
	return timer.delay != 0 || timer.repeat != 0;
};

// Gets the delay and repeat configuration of this [[timer]], respectively. The
// delay indicates the approximate amount of time remaining before the timer
// will expire, rather than the delay that was passed to [[timer_configure]].
export fn timer_gettime(timer: *timer) (time::duration, time::duration) = {
	const file = match (timer.file) {
	case let f: *file =>
		yield f;
	case null =>
		abort("timer_gettime called with uninitialized timer object");
	};

	let spec = rt::itimerspec { ... };
	rt::timerfd_gettime(file.fd, &spec)!;
	timer.delay = time::timespec_to_duration(spec.it_value);
	timer.repeat = time::timespec_to_duration(spec.it_interval);
	return (timer.delay, timer.repeat);
};

fn timer_arm(timer: *timer) void = {
	const file = timer.file as *file;
	assert(file.timer == null);
	file.timer = timer;
	file.ev.nrequest += 1;
	timer.cancel = &timer_cancel;
	file.op = op::TIMER;
	file_epoll_ctl(file);
};

fn timer_disarm(timer: *timer) void = {
	const file = timer.file as *file;
	assert(file.timer == timer);
	file.timer = null;
	file.ev.nrequest -= 1;
	timer.cancel = null;
	file.op = op::NONE;
	file_epoll_ctl(file);
};

fn timer_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op == op::TIMER);
	let timer = match (file.timer) {
	case let t: *timer =>
		yield t;
	case null =>
		abort("Invalid timer");
	};

	timer.delay = 0;
	if (timer.repeat == 0) {
		timer_disarm(timer);
	};

	let buf: [8]u8 = [0...];
	match (io::read(file.fd, buf)) {
	case errors::again =>
		// This can occur if the timer was reconfigured in an event
		// handler while the expiration event was pending in the same
		// dispatch of the event loop. Just discard the event in this
		// case.
		return;
	case (io::EOF | io::error) => abort();
	case => void;
	};

	const cb = timer.cb as *timercb;
	cb(timer, timer.user);
};

fn timer_cancel(req: *req) void = {
	let timer = req: *timer;
	timer_configure(timer, 0, 0);
};
