use errors;
use fmt;
use os::exec;
use sys;
use time;
use unix::signal::{sig, code};

// A callback for a [[wait]] operation.
export type waitcb = fn(
	req: *child,
	result: exec::status,
	user: nullable *opaque,
) void;

export type child = struct {
	req,
	cb: nullable *waitcb,
	pid: int,
};

// Starts a child process prepared with [[exec::cmd]] and returns a [[child]]
// that can be used to [[wait]] for it to exit.
//
// [[wait]] cannot be [[cancel]]ed, but one can hasten the process by
// [[kill]]ing the child.
export fn exec(
	loop: *loop,
	cmd: *exec::command,
	user: nullable *opaque = null,
) (child | exec::error | nomem) = {
	const pid = match (sys::fork()) {
	case let p: int =>
		yield p;
	case void =>
		// We're in the child process
		const err = exec::exec(cmd);
		fmt::fatal("ev::exec:", exec::strerror(err));
	case let err: sys::errno =>
		return errors::errno(err);
	};

	return child {
		user = user,
		loop = loop,
		pid = pid,
		link = req_list { ... },
		...
	};
};

// Waits for a [[child]] process to exit. A [[child]] may only be [[wait]]ed
// upon once. If the event [[loop]] is [[stop]]ped before this operation
// completes, the child will never be reaped.
export fn wait(c: *child, callback: *waitcb) void = {
	assert(c.cancel == null, "ev::wait: cannot wait twice on one child");
	c.cb = callback;
	c.cancel = &wait_cancel;

	const loop = c.loop as *loop;
	loop.nrequest += 1;

	let kev = [sys::kevent {
		ident = c.pid: uintptr,
		filter = sys::EVFILT_PROC,
		flags = sys::EV_ADD | sys::EV_ONESHOT,
		fflags = sys::NOTE_EXIT,
		data = 0,
		udata = c: nullable *opaque,
	}];

	match (sys::kevent_poll(loop.fd, &kev: *[*]sys::kevent, 1, null, 0, null)) {
	case int => void;
	case let err: sys::errno =>
		abort("ev::wait: unexpected error from kevent_poll");
	};
};

fn wait_ready(c: *child, ev: *sys::kevent) void = {
	let status: int = 0;
	let ru = sys::rusage { ... };
	const pid: int = 0;
	const loop = c.loop as *loop;

	// waitid should not fail at this point
	for (true) {
		match (sys::wait4(c.pid: sys::pid_t, &status, sys::WNOHANG, &ru)) {
		case let p: sys::pid_t =>
			pid = p;
			break;
		case let err: sys::errno =>
			// Interrupted by signal handler, try again
			assert(err == sys::EINTR);
		};
	};

	assert(pid: int == c.pid);

	let st = exec::status {
		status = status,
		...
	};

	rusage(&st, &ru);

	const callback = c.cb as *waitcb;
	callback(c, st, c.user);

	loop.nrequest -= 1;
	c.cancel = null;
};

// Copied from os::exec
fn rusage(st: *exec::status, ru: *sys::rusage) void = {
	st.rusage.utime = time::instant {
		sec = ru.ru_utime.tv_sec,
		nsec = ru.ru_utime.tv_usec * time::MICROSECOND: i64,
	};
	st.rusage.stime = time::instant {
		sec = ru.ru_stime.tv_sec,
		nsec = ru.ru_stime.tv_usec * time::MICROSECOND: i64,
	};
	st.rusage.maxrss = ru.ru_maxrss;
	st.rusage.minflt = ru.ru_minflt;
	st.rusage.majflt = ru.ru_majflt;
	st.rusage.inblock = ru.ru_inblock;
	st.rusage.oublock = ru.ru_oublock;
	st.rusage.nvcsw = ru.ru_nvcsw;
	st.rusage.nivcsw = ru.ru_nivcsw;
};

// Sends a signal to a process started with [[ev::exec]].
export fn kill(c: *child, sig: sig = sig::TERM) (void | errors::error) = {
	match (sys::kill(c.pid: sys::pid_t, sig)) {
	case void => void;
	case let err: sys::errno =>
		return errors::errno(err);
	};
};

fn wait_cancel(req: *req) void = {
	let c = req: *child;
	const loop = c.loop as *loop;

	let kev = [sys::kevent {
		ident = c.pid: uintptr,
		filter = sys::EVFILT_PROC,
		flags = sys::EV_DELETE,
		fflags = 0,
		data = 0,
		udata = null: nullable *opaque,
	}];

	match (sys::kevent_poll(loop.fd, &kev: *[*]sys::kevent, 1, null, 0, null)) {
	case int => void;
	// ev::req::cancel can't propagate errors.
	case => void;
	};

	loop.nrequest -= 1;
	c.cancel = null;
};
