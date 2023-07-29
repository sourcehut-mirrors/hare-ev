// TODO: Expose full siginfo data for non-portable use
use errors;
use rt;
use unix::signal;

// Callback function for [[signal]] operations.
export type signalcb = fn(file: *file, sig: signal::sig) void;

// Registers a signal handler with this event loop. The signals specified will
// be masked so they are only raised via the provided callback. Closing this
// file will unmask the signals.
//
// It is not necessary to call [[signal]] again after the callback has
// processed; it will automatically re-register the operation for subsequent
// signals.
export fn signal(
	loop: *loop,
	cb: *signalcb,
	signals: signal::sig...
) (*file | errors::error) = {
	const fd = signal::signalfd(signals...)?;
	const file = register(loop, fd)?;
	file.op = op::SIGNAL;
	file.cb = cb;
	file_epoll_ctl(file);
	signal::sigset_empty(&file.sigmask);
	signal::sigset_add(&file.sigmask, signals...);
	signal::block(signals...);
	return file;
};

fn signal_restore(file: *file) void = {
	assert(file.op == op::SIGNAL);
	let buf: [rt::NSIG]signal::sig = [0...];
	let signals = buf[..0];
	for (let i = 1; i < rt::NSIG; i += 1) {
		const sig = i: signal::sig;
		if (signal::sigset_member(&file.sigmask, sig)) {
			static append(signals, sig);
		};
	};
	signal::unblock(signals...);
};

fn signal_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op == op::SIGNAL);
	assert(file.cb != null);
	const cb = file.cb: *signalcb;
	const info = signal::read(file.fd)!;
	cb(file, info.signo);
};
