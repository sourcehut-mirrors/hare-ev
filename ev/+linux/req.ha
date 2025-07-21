export type req = struct {
	file: nullable *file,
	cancel: nullable *cancelfn,
	user: nullable *opaque,
	link: req_list,
};

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

// Returns the [[file]] associated with a [[req]]uest, if any.
export fn req_getfile(req: *req) nullable *file = {
	return req.file;
};

// Returns the user data associated with a [[req]]uest, if any.
export fn req_getuser(req: *req) nullable *opaque = {
	return req.user;
};

// Sets the user data associated with a [[req]]uest.
export fn req_setuser(req: *req, user: nullable *opaque) void = {
	req.user = user;
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

// Makes a new request object.
export fn mkreq(
	file: nullable *file,
	cancel: *cancelfn,
	user: nullable *opaque = null,
) req = {
	return req {
		file = file,
		cancel = cancel,
		user = user,
		link = req_list { ... },
	};
};
