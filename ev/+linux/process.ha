use errors;
use fmt;
use os::exec;
use rt;
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
	let pidfd: int = 0;
	let args = rt::clone_args {
		flags = rt::CLONE_PIDFD,
		pidfd = &pidfd: uintptr: u64,
		exit_signal = sig::CHLD: u64,
		...
	};

	const pid = match (rt::clone3(&args)) {
	case let pid: rt::pid_t =>
		yield pid;
	case let errno: rt::errno =>
		return errors::errno(errno);
	};

	if (pid == 0) {
		const err = exec::exec(cmd);
		fmt::fatal("ev::exec:", exec::strerror(err));
	};

	const file = match (register(loop, pidfd)) {
	case let f: *file =>
		yield f;
	case let e: errors::error =>
		return e;
	case nomem =>
		return nomem;
	};
	return child {
		file = file,
		user = user,
		...
	};
};

// Waits for a [[child]] process to exit. A [[child]] may only be [[wait]]ed
// upon once. If the event [[loop]] is [[stop]]ped before this operation
// completes, the child will never be reaped.
export fn wait(req: *child, cb: *waitcb) void = {
	const file = file_req_init(req, null);
	assert(file.wait == null, "ev::wait: cannot wait twice on one child");
	req.cb = cb;

	// Attempt to waitid now to hit error cases early
	match (do_waitid(req, rt::WNOHANG)) {
	case let err: rt::errno =>
		assert(err == rt::EAGAIN,
			"ev::wait: unexpected error from waitid (not a pidfd?)");
	case void =>
		// Child has already exited. do_waitid ran the callback, so we
		// can return with no further fanfare
		return;
	};

	file.op = op::WAIT;
	file.wait = req;
	file_epoll_ctl(file);
};

// Calls [[rt::waitid]] with the given options. If successful, calls the
// callback and cleans up the file (and returns void). If unsuccessful, returns
// the error.
fn do_waitid(req: *child, options: int = 0) (void | rt::errno) = {
	def WAIT_OPTIONS = rt::WEXITED;

	const proc = req.file as *file;
	let si = rt::siginfo { ... };
	let ru = rt::rusage { ... };
	match (rt::waitid(rt::idtype::P_PIDFD, proc.fd: rt::id_t, &si,
		WAIT_OPTIONS | options, &ru)) {
	case void =>
		if (si.si_pid == 0) {
			assert(options & rt::WNOHANG != 0);
			return rt::EAGAIN;
		};
	case let err: rt::errno =>
		return err;
	};

	// Convert the siginfo data into a wait(2)-style exit status
	let status = 0i;
	if (si.si_code == code::EXITED) {
		status = si.si_status << 8;
	} else {
		status = si.si_status;
	};

	let st = exec::status {
		status = status,
		...
	};
	rusage(&st, &ru);

	const cb = req.cb as *waitcb;
	cb(req, st, req.user);
	proc.ev.nrequest -= 1;
	close(proc);
};

fn wait_ready(proc: *file, ev: *rt::epoll_event) void = {
	assert(proc.op == op::WAIT);
	const req = proc.wait as *child;

	// waitid should not fail at this point
	for (true) {
		match (do_waitid(req)) {
		case void =>
			break;
		case let err: rt::errno =>
			// Interrupted by signal handler, try again
			assert(err == rt::EINTR);
		};
	};
};

// Copied from os::exec
fn rusage(st: *exec::status, ru: *rt::rusage) void = {
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
export fn kill(req: *child, sig: sig = sig::TERM) (void | errors::error) = {
	const file = req.file as *file;
	match (rt::pidfd_send_signal(file.fd, sig, null, 0)) {
	case void => void;
	case let err: rt::errno =>
		return errors::errno(err);
	};
};
