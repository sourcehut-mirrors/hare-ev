use errors;
use sys;
use time;

// A callback which executes when a timer expires.
export type timercb = fn(req: *timer, user: nullable *opaque) void;

// Determines how the timer behaves after expiring.
export type timer_mode = enum {
	// Expire once and stop ticking.
	ONESHOT,
	// Expire in repeating intervals until explicitly [[cancel]led.
	REPEATING,
};

export type timer = struct {
	req,
	cb: nullable *timercb,
	interval: time::duration,
	mode: timer_mode,
	enabled: bool,
};

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
) (timer | nomem) = {
	return timer {
		user = user,
		loop = loop,
		cb = cb,
		link = req_list { ... },
		...
	};
};

// Frees resources associated with a [[timer]]. The timer is [[cancel]]ed if
// configured and removed from the associated event [[loop]].
export fn timer_finish(timer: *timer) void = {
	cancel(timer);
};

// Configures a timer created with [[timer_init]] to expire after the given
// "interval". mode controls whether the timer fires once or repeatedly.
export fn timer_configure(
	timer: *timer,
	interval: time::duration,
	mode: timer_mode,
) (void | errors::error) = {
	timer_disarm(timer);

	timer.interval = interval;
	timer.mode = mode;

	if (timer.interval != 0) {
		timer_arm(timer)?;
	};
};

// Returns true if this [[timer]] is armed (and will eventually expire and run
// its callback).
export fn timer_armed(timer: *timer) bool = {
	return timer.enabled;
};

// Gets the delay and mode configuration of a [[timer]].
// Returns delay 0 if the timer is not armed.
export fn timer_gettime(timer: *timer) (time::duration, timer_mode) = {
	return (timer.interval, timer.mode);
};

fn timer_disarm(timer: *timer) void = {
	if (!timer.enabled) {
		return;
	};

	const loop = timer.loop as *loop;
	let kev = [sys::kevent {
		ident = timer: uintptr,
		filter = sys::EVFILT_TIMER,
		flags = sys::EV_DELETE,
		fflags = 0,
		data = 0,
		udata = null,
	}];

	match (sys::kevent_poll(loop.fd, &kev: *[*]sys::kevent, 1, null, 0, null)) {
	case int => void;
	// ev::req::cancel can't propagate errors.
	case => void;
	};

	timer.enabled = false;
	loop.nrequest -= 1;
	timer.cancel = null;
};

fn timer_arm(timer: *timer) (void | errors::error) = {
	const loop = timer.loop as *loop;
	loop.nrequest += 1;
	timer.cancel = &timer_cancel;

	const flags = switch (timer.mode) {
	case timer_mode::ONESHOT =>
		yield sys::EV_ADD | sys::EV_ONESHOT;
	case timer_mode::REPEATING =>
		yield sys::EV_ADD;
	};

	let kev = [sys::kevent {
		ident = timer: uintptr,
		filter = sys::EVFILT_TIMER,
		flags = flags,
		fflags = sys::NOTE_NSECONDS,
		data = timer.interval,
		udata = timer,
	}];

	match (sys::kevent_poll(loop.fd, &kev: *[*]sys::kevent, 1, null, 0, null)) {
	case int => void;
	case let err: sys::errno =>
		loop.nrequest -= 1;
		timer.cancel = null;
		return errors::errno(err);
	};

	timer.enabled = true;
};

fn timer_ready(timer: *timer, ev: *sys::kevent) (void | errors::error) = {
	const cb = timer.cb as *timercb;
	cb(timer, timer.user);

	// For ONESHOT timers, the kevent was auto-deleted by the kernel.
	// For REPEATING timers, the kevent remains active.
	if (timer.mode == timer_mode::ONESHOT) {
		timer.enabled = true;
		(timer.loop as *loop).nrequest -= 1;
		timer.cancel = null;
	};
};

fn timer_cancel(req: *req) void = {
	let timer = req: *timer;
	timer_disarm(timer);
};
