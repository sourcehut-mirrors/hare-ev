use ev;

// Callback for a [[dial]] operation.
export type dialcb = fn(
	req: *dialreq,
	r: (*ev::file | error),
	user: nullable *opaque,
) void;

// A dial request. Ultimately passed to the appropriate [[dialer]].
export type dialreq = struct {
	ev::req,
	cb: nullable *dialcb,
	// Reserved for dialer-specific state, if needed
	dialer: nullable *opaque,
};

// An uninitialized [[dialreq]] value. This can be used to statically initialize
// [[dialreq]] objects when [[dialreq_init]] is not applicable, for instance
// when storing an [[dialreq]] in a global.
export def DIALREQ_INIT = dialreq {
	...
};

// Initializes a [[dialreq]] for use with the given event loop, with an optional
// user data pointer.
//
// Once submitted to the event loop, a request object is borrowed from the
// caller and must remain stable until the request is cancelled or completed.
export fn dialreq_init(
	loop: *ev::loop,
	user: nullable *opaque = null,
) dialreq = {
	return dialreq {
		loop = loop,
		user = user,
		...
	};
};
