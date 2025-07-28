use errors;
use rt;
use unix::signal;
use fmt; // XXX TEMP

// Callback function for [[signal]] operations.
export type signalcb = fn(
	req: *signal,
	sig: signal::sig,
	user: nullable *opaque,
) void;

export type signal = struct {
	req,
	cb: nullable *signalcb,
	mask: signal::sigset,
};

// An uninitialized [[handler]] value. This can be used to statically initialize
// [[sigreq]] objects when [[signal_init]] is not applicable, for instance when
// storing a [[sigreq]] in a global.
export def SIGNAL_INIT = signal { ... };

// Creates a [[signal]] handler with a set of signals. Pass the signal handler
// to [[handle]] to await signal delivery.
//
// The caller must call [[signal_finish]] to free resources associated with this
// signal handler after use.
export fn signal_init(
	loop: *loop,
	user: nullable *opaque,
	signals: signal::sig...
) (signal | errors::error | nomem) = {
	const empty = signal::newsigset();

	const fd = match (rt::signalfd(-1, &empty, rt::SFD_CLOEXEC)) {
	case let fd: int =>
		yield fd;
	case let err: rt::errno =>
		return errors::errno(err);
	};

	return signal {
		file = register(loop, fd)?,
		mask = signal::newsigset(signals...),
		user = user,
		...
	};
};

// Frees resources associated with a [[signal]] handler.
export fn signal_finish(sig: *signal) void = {
	match (sig.file) {
	case null =>
		return; // Idempotency
	case let f: *file =>
		cancel(sig);
		close(f);
		sig.file = null;
	};
};

// Runs the given callback the next time a [[signal]] prepared with
// [[signal_init]] is received.
//
// The signals applicable to the pending request are blocked while the handler
// is pending. The callback is not run in a signal stack frame and need not be
// limited to running signal-safe code.
//
// During the callback, the user may call [[handle]] again to await the next
// signal delivery using the same [[signal]] object, like so:
//
//	fn on_signal(
//		sig: *ev::signal,
//		info: *signal::info,
//		user: nullable *opaque,
//	) void = {
//		// ...
//		ev::handle(sig, &on_signal);
//	};
//
// In this case, the applicable signals remain blocked. If the user does not
// call [[handle]] during the callback, the applicable signals are unblocked and
// the signal handler is disposed of. The [[signal]] object may then be
// re-initialized via [[signal_init]] and reused, if desired.
//
// [[cancel]]ling the signal request will cause the signals to be unblocked and
// the [[signal]] object to be disposed of; it may then be reused if desired.
//
// It is an error to attempt to handle the same signal with more than one
// [[signal]] object, or to use a [[signal]] object which is already waiting for
// a signal delivery.
export fn handle(
	req: *signal,
	cb: *signalcb,
) void = {
	const file = file_req_init(req, &signal_cancel);
	req.cb = cb;
	file.signal = req;
	file.ev.nrequest += 1;
	signal_arm(req);
};

fn signal_arm(req: *signal) void = {
	const file = req.file as *file;

	signal::setprocmask(signal::how::BLOCK, &req.mask);
	rt::signalfd(file.fd, &req.mask, rt::SFD_CLOEXEC)!;

	file.op = op::SIGNAL;
	file_epoll_ctl(file);
};

fn signal_disarm(req: *signal) void = {
	const file = req.file as *file;

	const empty = signal::newsigset();
	signal::setprocmask(signal::how::UNBLOCK, &req.mask);
	rt::signalfd(file.fd, &empty, rt::SFD_CLOEXEC)!;

	file.op = op::NONE;
	file_epoll_ctl(file);
};

fn signal_ready(file: *file, ev: *rt::epoll_event) void = {
	assert(file.op == op::SIGNAL);
	let req = match (file.signal) {
	case let sig: *signal =>
		file.signal = null;
		file.ev.nrequest -= 1;
		sig.cancel = null;
		yield sig;
	case null =>
		abort("Invalid signal");
	};

	const info = signal::read(file.fd)!;
	const cb = req.cb as *signalcb;
	cb(req, info.signo, req.user);

	if (file.signal == null) {
		signal_disarm(req);
	};
};

fn signal_cancel(req: *req) void = {
	let req = req: *signal;
	let file = req.file as *file;
	file.signal = null;
	file.ev.nrequest -= 1;
	file_epoll_ctl(file);
	signal_disarm(req);
};
