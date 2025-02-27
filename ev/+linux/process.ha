use errors;
use os::exec;
use rt;
use time;
use unix::signal::{sig, code};

// Starts a child process prepared with [[exec::cmd]] and returns a [[file]]
// that can be used to [[wait]] for it to exit.
export fn exec(
	loop: *loop,
	cmd: *exec::command,
) (*file | errors::error | nomem) = {
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
		exec::exec(cmd);
	};

	return register(loop, pidfd);
};

// A callback for a [[wait]] operation.
export type waitcb = fn(file: *file, result: exec::status) void;

// Waits for a process to exit. After the callback is run, the [[file]] is
// closed and unregistered from the event loop and may not be used again.
export fn wait(proc: *file, cb: *waitcb) (req | errors::error) = {
	assert(proc.op & op::WAIT == 0);

	// Attempt to waitid now to hit error cases early
	match (do_waitid(proc, cb, rt::WNOHANG)) {
	case let err: rt::errno =>
		// We expect EAGAIN, anything else indicates that something went
		// wrong (e.g. EBADF if using a non-pidfd with ev::wait)
		if (err != rt::EAGAIN) {
			return errors::errno(err);
		};
	case void =>
		// Child has already exited. do_waitid ran the callback, so we
		// can return with no further fanfare
		return req { ... };
	};

	proc.op |= op::WAIT;
	proc.cb = cb;
	file_epoll_ctl(proc);
	return mkreq(&wait_cancel, proc);
};

// Calls [[rt::waitid]] with the given options. If successful, calls the
// callback and cleans up the file (and returns void). If unsuccessful, returns
// the error.
fn do_waitid(proc: *file, cb: *waitcb, options: int = 0) (void | rt::errno) = {
	def WAIT_OPTIONS = rt::WEXITED | rt::WSTOPPED | rt::WCONTINUED;

	let si = rt::siginfo { ... };
	let ru = rt::rusage { ... };
	match (rt::waitid(rt::idtype::P_PIDFD, proc.fd: rt::id_t, &si,
		WAIT_OPTIONS | options, &ru)) {
	case let err: rt::errno =>
		return err;
	case void =>
		if (si.si_pid == 0) {
			assert(options & rt::WNOHANG != 0);
			return rt::EAGAIN;
		};
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
	cb(proc, st);
	close(proc);
};

fn wait_cancel(req: *req) void = {
	const proc = req.user: *file;
	assert(proc.op & op::WAIT != 0);
	proc.op &= ~op::WAIT;
	file_epoll_ctl(proc);
};

fn wait_ready(proc: *file, ev: *rt::epoll_event) void = {
	assert(proc.op & op::WAIT != 0);
	assert(proc.cb != null);
	const cb = proc.cb: *waitcb;
	proc.op &= ~op::WAIT;
	file_epoll_ctl(proc);

	// waitid should not fail at this point
	for (true) {
		match (do_waitid(proc, cb)) {
		case void =>
			break;
		case let err: rt::errno =>
			// Interrupted by signal handler, go again
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
export fn kill(child: *file, sig: sig = sig::TERM) (void | errors::error) = {
	match (rt::pidfd_send_signal(child.fd, sig, null, 0)) {
	case void => void;
	case let err: rt::errno =>
		return errors::errno(err);
	};
};
