// A request is used to store state associated with an I/O request. Users should
// not directly access any fields of any [[req]] unless they are creating
// subtypes of [[req]].
//
// This type is subtyped by various kinds of requests, such as [[ioreq]] or
// [[timer]], and may be subtyped by downstream users to provide request objects
// for their own high-level operations, with a user data pointer and
// cancellation semantics.
//
// Note that request objects are generally assumed to already be availble for
// reuse during the user callback. Therefore, if the downstream request
// implementation has a cleanup step following the callback, they should take
// care not to treat any state stored on the request object as valid during this
// step.
export type req = struct {
	// Cancellation function. [[cancel]] sets this field to null for
	// idempotency; therefore the field must be populated again each time
	// the request is submitted.
	cancel: nullable *cancelfn,
	// User data object
	user: nullable *opaque,

	// A request can either be associated with an event [[loop]] or a
	// [[file]] (and via the file, indirectly, an event loop).
	//
	// Internally, most [[ev::]] requests are associated with files. Some
	// requests, such as [[connect_tcp]], are briefly associated with a loop
	// before the socket is created, after which they are associated with
	// that file instead.
	union {
		loop: nullable *loop,
		file: nullable *file,
	},

	// Linked list of requests for internal use
	link: req_list,
};

// TODO: Add file_req type and subtype it for e.g. [[ioreq]]? And then we can
// move the req_list into file_req and avoid storing it for requests that don't
// care for it.

export type req_list = struct {
	union {
		next: nullable *req_list,
		head: nullable *req_list,
	},
	union {
		prev: nullable *req_list,
		tail: nullable *req_list,
	},
};

// Returns the user data associated with a [[req]]uest, if any.
export fn req_getuser(req: *req) nullable *opaque = {
	return req.user;
};

// Sets the user data associated with a [[req]]uest.
export fn req_setuser(req: *req, user: nullable *opaque) void = {
	req.user = user;
};

fn req_getfile(req: *req) nullable *file = {
	return req.file;
};

// A function which cancels an in-flight request.
export type cancelfn = fn(req: *req) void;

// Cancels an in-flight request. The user can safely cancel a request more than
// once. A request cannot be cancelled once it has completed.
export fn cancel(req: *req) void = {
	match (req.cancel) {
	case let cancel: *cancelfn =>
		req.cancel = null;
		cancel(req);
	case null => yield;
	};
};

fn req_link(list: *req_list, link: *req_list) void = {
	assert(link.prev == null && link.next == null,
		"Attempted to reuse in-flight request object");

	match (list.head) {
	case let next: *req_list =>
		assert(next.prev == null);
		link.next = next;
		next.prev = link;
		list.head = link;
	case null =>
		list.head = link;
		list.tail = link;
	};
};

fn req_unlink(list: *req_list, link: *req_list) void = {
	match (link.prev) {
	case let prev: *req_list =>
		prev.next = link.next;
	case null =>
		list.head = link.next;
	};

	match (link.next) {
	case let next: *req_list =>
		next.prev = link.prev;
	case null =>
		list.tail = link.prev;
	};

	link.prev = null;
	link.next = null;
};

fn req_list_empty(list: *req_list) bool = {
	return list.head == null;
};
