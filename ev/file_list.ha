export type file_list = struct {
	union {
		next: nullable *file_list,
		head: nullable *file_list,
	},
	union {
		prev: nullable *file_list,
		tail: nullable *file_list,
	},
};

fn file_link(list: *file_list, link: *file_list) void = {
	assert(link.prev == null && link.next == null,
		"Double linking a file list");

	match (list.head) {
	case let next: *file_list =>
		assert(next.prev == null);
		link.next = next;
		next.prev = link;
		list.head = link;
	case null =>
		list.head = link;
		list.tail = link;
	};
};

fn file_unlink(list: *file_list, link: *file_list) void = {
	match (link.prev) {
	case let prev: *file_list =>
		prev.next = link.next;
	case null =>
		list.head = link.next;
	};

	match (link.next) {
	case let next: *file_list =>
		next.prev = link.prev;
	case null =>
		list.tail = link.prev;
	};

	link.prev = null;
	link.next = null;
};

fn file_list_empty(list: *file_list) bool = {
	return list.head == null;
};

fn file_list_get_file(link: *file_list) *file = {
	const offs = offset((null: *file).link): uintptr;
	return (link: uintptr - offs): *file;
};
