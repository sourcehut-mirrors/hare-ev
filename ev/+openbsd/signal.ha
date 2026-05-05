use errors;
use sys;
use unix::signal;

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
	signals: []signal::sig,
	enabled: bool,
};

// Creates a [[signal]] handler with a set of signals. Pass the signal handler
// to [[handle]] to await signal delivery.
//
// The caller must call [[signal_finish]] to free resources associated with this
// signal handler after use.
export fn signal_init(
	loop: *loop,
	user: nullable *opaque = null,
	signals: signal::sig...
) (signal | nomem) = {
	let sigs: []signal::sig = alloc(signals...)?;
	let mask = signal::newsigset(signals...);

	return signal {
		user = user,
		loop = loop,
		mask = mask,
		signals = sigs,
		...
	};
};

// Frees resources associated with a [[signal]] handler.
export fn signal_finish(sig: *signal) void = {
	match (sig.cancel) {
	case let cancel: *cancelfn =>
		cancel(sig);
	case null =>
		void;
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
) (void | errors::error | nomem) = {
	if (req.enabled) {
		return errors::exists;
	};

	req.cb = cb;
	req.cancel = &signal_cancel;

	// Block signals so kqueue can handle them.
	signal::setprocmask(signal::how::BLOCK, &req.mask);

	const loop = req.loop as *loop;
	loop.nrequest += 1;

	let kevs: []sys::kevent = alloc([sys::kevent { ... }...], len(req.signals))?;

	for (let i = 0z; i < len(req.signals); i += 1) {
		kevs[i] = sys::kevent {
			ident = req.signals[i]: uintptr,
			filter = sys::EVFILT_SIGNAL,
			flags = sys::EV_ADD | sys::EV_CLEAR,
			fflags = 0,
			data = 0,
			udata = req,
		};
	};

	match (sys::kevent_poll(loop.fd, &kevs[0]: *[*]sys::kevent, len(kevs): int, null, 0, null)) {
	case int => void;
	case let err: sys::errno =>
		free(kevs);
		signal_cancel(req);
		return errors::errno(err);
	};

	free(kevs);
	req.enabled = true;
};

fn signal_disarm(sig: *signal) (void | errors::error | nomem) = {
	const loop = sig.loop as *loop;
	let kevs: []sys::kevent = alloc([sys::kevent { ... }...], len(sig.signals))?;
	defer free(kevs);

	for (let i = 0z; i < len(sig.signals); i += 1) {
		kevs[i] = sys::kevent {
			ident = sig.signals[i]: uintptr,
			filter = sys::EVFILT_SIGNAL,
			flags = sys::EV_DELETE,
			fflags = 0,
			data = 0,
			udata = null,
		};
	};

	match (sys::kevent_poll(loop.fd, &kevs[0]: *[*]sys::kevent, len(kevs): int, null, 0, null)) {
	case int => void;
	case let err: sys::errno =>
		return errors::errno(err);
	};

	signal::setprocmask(signal::how::UNBLOCK, &sig.mask);
	sig.enabled = false;
};

fn signal_ready(sig: *signal, ev: *sys::kevent) (void | errors::error | nomem) = {
	const cb = sig.cb as *signalcb;
	const s = ev.ident: signal::sig;
	cb(sig, s, sig.user);

	// If the user didn't call handle again during callback, clean up.
	// FIXME: review this condition
	if (sig.cancel != null && sig.cancel: uintptr == &signal_cancel: uintptr) {
		sig.cancel = null;
		(sig.loop as *loop).nrequest -= 1;
		signal_disarm(sig)?;
	};
};

fn signal_cancel(r: *req) void = {
	let sig = r: *signal;
	if (!sig.enabled) {
		return;
	};

	(sig.loop as *loop).nrequest -= 1;
	sig.cancel = null;
	match (signal_disarm(sig)) {
	case void => void;
	case errors::error => void; // ev::req::cancel can't propagate errors.
	};
};
