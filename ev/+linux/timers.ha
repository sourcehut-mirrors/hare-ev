use errors;
use io;
use rt;
use time;

// A callback which executes when a timer expires.
export type timercb = fn(file: *file) void;

// Creates a new timer. By default, this timer never expires; configure it with
// [[timer_configure]].
export fn newtimer(
	loop: *loop,
	cb: *timercb,
	clock: time::clock,
) (*file | errors::error) = {
	const fd = match (rt::timerfd_create(clock, rt::TFD_CLOEXEC)) {
	case let fd: int =>
		yield fd: io::file;
	case let errno: rt::errno =>
		return errors::errno(errno);
	};
	const file = register(loop, fd)?;
	file.op = op::TIMER;
	file.cb = cb;
	file_epoll_ctl(file);
	return file;
};

// Starts a timer created with [[newtimer]] to expire after the given "delay"
// and indefinitely thereafter following each interval of "repeat". Setting both
// values to zero disarms the timer; setting either value non-zero arms the
// timer.
export fn timer_configure(
	timer: *file,
	delay: time::duration,
	repeat: time::duration,
) void = {
	assert(timer.op == op::TIMER);
	let spec = rt::itimerspec { ... };
	time::duration_to_timespec(delay, &spec.it_value);
	time::duration_to_timespec(repeat, &spec.it_interval);
	rt::timerfd_settime(timer.fd, 0, &spec, null)!;
};

fn timer_ready(timer: *file, ev: *rt::epoll_event) void = {
	assert(timer.op == op::TIMER);
	let buf: [8]u8 = [0...];
	io::read(timer.fd, buf)!;

	assert(timer.cb != null);
	const cb = timer.cb: *timercb;
	cb(timer);
};
