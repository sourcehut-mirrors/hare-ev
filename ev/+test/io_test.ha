use io;
use unix;

// Test userdata.
type test_userdata = struct {
	total: size,
	off: size,
	rbuf: []u8,
	wrote: bool,
	complete: bool,
};

// Write a buffer much larger than the pipe capacity, forcing partial writes.
@test fn io_partial_write() void = {
	let loop = newloop()!;
	defer finish(&loop);

	const (rd, wr) = unix::pipe(unix::pipe_flag::NONBLOCK)!;
	const rx = register(&loop, rd)!;
	defer close(rx);
	const tx = register(&loop, wr)!;
	defer close(tx);

	const total = 1024z * 1024;
	let payload = alloc([0u8...], total)!;
	defer free(payload);
	for (let i = 0z; i < total; i += 1) {
		payload[i] = (i): u8;
	};

	let rbuf = alloc([0u8...], 8192)!;
	defer free(rbuf);

	let state = test_userdata {
		total = total,
		rbuf = rbuf,
		...
	};

	let rreq = ioreq_init(rx, &state);
	read(&rreq, rbuf, &iotest_read);

	let wreq = ioreq_init(tx, &state);
	write(&wreq, payload, &iotest_partial_write);

	run(&loop)!;

	assert(state.wrote, "write callback did not fire");
	assert(state.complete, "read did not complete");
};

fn iotest_partial_write(
	req: *ioreq,
	r: (size | io::error),
	user: nullable *opaque,
) void = {
	const state = user: *test_userdata;
	assert(r is size, "write failed");
	assert(r as size == state.total, "wrong total written");
	state.wrote = true;
};

fn iotest_read(
	req: *ioreq,
	r: (size | io::EOF | io::error),
	user: nullable *opaque,
) void = {
	const state = user: *test_userdata;
	const n = r as size;
	for (let i = 0z; i < n; i += 1) {
		assert(state.rbuf[i] == ((state.off + i)): u8,
			"payload corrupted");
	};

	state.off += n;
	if (state.off < state.total) {
		read(req, state.rbuf, &iotest_read);
	} else {
		state.complete = true;
	};
};

@test fn io_consecutive_writes() void = {
	let loop = newloop()!;
	defer finish(&loop);

	const (rd, wr) = unix::pipe(unix::pipe_flag::NONBLOCK)!;
	const rx = register(&loop, rd)!;
	defer close(rx);
	const tx = register(&loop, wr)!;
	defer close(tx);

	const total = 1024z * 1024;
	let payload = alloc([0u8...], total)!;
	defer free(payload);
	for (let i = 0z; i < total; i += 1) {
		payload[i] = (i): u8;
	};

	let rbuf = alloc([0u8...], 8192)!;
	defer free(rbuf);

	let state = test_userdata {
		total = total,
		rbuf = rbuf,
		...
	};

	let rreq = ioreq_init(rx, &state);
	read(&rreq, rbuf, &iotest_read);

	let wreq1 = ioreq_init(tx, &state);
	write(&wreq1, payload[..total / 2], &iotest_consecutive_writes);

	let wreq2 = ioreq_init(tx, &state);
	write(&wreq2, payload[total / 2..], &iotest_consecutive_writes);

	run(&loop)!;

	assert(state.wrote, "write callback did not fire");
	assert(state.complete, "read did not complete");
};

fn iotest_consecutive_writes(
	req: *ioreq,
	r: (size | io::error),
	user: nullable *opaque,
) void = {
	const state = user: *test_userdata;
	assert(r is size, "write failed");
	state.wrote = true;
};
