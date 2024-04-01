export type req = struct {
	cancel: nullable *cancelfn,
	user: nullable *opaque,
};

// Makes a new request object.
export fn mkreq(cancel: *cancelfn, user: nullable *opaque = null) req = {
	return req {
		cancel = cancel,
		user = user,
	};
};

// A function which cancels an in-flight request.
export type cancelfn = fn(req: *req) void;

// Cancels an in-flight request. The user can safely cancel a request more than
// once. A request cannot be cancelled once it has completed.
export fn cancel(req: *req) void = {
	match (req.cancel) {
	case let cancel: *cancelfn =>
		cancel(req);
	case null => yield;
	};
	req.cancel = null;
};
