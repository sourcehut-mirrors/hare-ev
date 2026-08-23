use bytes;
use io;
use net;
use net::unix;
use sys;

// Test userdata.
type msgtest = struct {
	rbuf: []u8,
	marker: u8,
	sent: bool,
	recvd: bool,
};

// Send a message with a passed file descriptor across a UNIX socket pair and
// verify that both the payload and the descriptor arrive intact.
@test fn msg_sendrecv() void = {
	let loop = newloop()!;
	defer finish(&loop);

	let sv: [2]int = [0, 0];
	sys::socketpair(sys::AF_UNIX: int,
		sys::SOCK_STREAM | sys::SOCK_NONBLOCK | sys::SOCK_CLOEXEC,
		0, &sv)!;
	const tx = register(&loop, sv[0]: io::file)!;
	defer close(tx);
	const rx = register(&loop, sv[1]: io::file)!;
	defer close(rx);

	// Send read end of the pipe, then write a marker byte and close it.
	let p: [2]int = [0, 0];
	sys::pipe2(&p, sys::O_CLOEXEC)!;
	defer io::close(p[0]: io::file)!;
	defer io::close(p[1]: io::file)!;
	const marker: [1]u8 = ['Z'];
	io::write(p[1]: io::file, marker)!;

	const payload: [5]u8 = ['h', 'a', 'l', 'l', 'o'];
	let smsg = net::newmsg();
	defer net::finish(&smsg);
	net::addvector(&smsg, payload)!;
	net::unix::addfiles(&smsg, p[0]: io::file)!;

	let rbuf: [64]u8 = [0...];
	let rmsg = net::newmsg();
	defer net::finish(&rmsg);
	net::addvector(&rmsg, rbuf)!;
	net::unix::allocfiles(&rmsg, 1)!;

	let state = msgtest {
		rbuf = rbuf,
		marker = 'Z',
		...
	};

	let sreq = sendmsgreq_init(tx, &state);
	sendmsg(&sreq, &smsg, &on_msgtest_send);

	let rreq = recvmsgreq_init(rx, &state);
	recvmsg(&rreq, &rmsg, &on_msgtest_recv);

	run(&loop)!;

	assert(state.sent, "send callback did not fire");
	assert(state.recvd, "recv callback did not fire");
};

fn on_msgtest_send(
	req: *sendmsgreq,
	r: (size | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *msgtest;
	assert(r is size, "sendmsg failed");
	assert(r as size == 5);
	state.sent = true;
};

fn on_msgtest_recv(
	req: *recvmsgreq,
	msg: *net::msghdr,
	r: (size | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *msgtest;
	const n = r as size;
	const want: [5]u8 = ['h', 'a', 'l', 'l', 'o'];
	assert(n == 5);
	assert(bytes::equal(state.rbuf[..n], want), "wrong payload");

	const files = net::unix::recvfiles(msg, 1);
	assert(len(files) == 1, "no descriptor received");
	let got: [1]u8 = [0];
	assert(io::read(files[0], got) as size == 1, "short read");
	assert(got[0] == state.marker, "wrong data through passed descriptor");
	io::close(files[0])!;
	state.recvd = true;
};

type parttest = struct {
	total: size,
	off: size,
	rbuf: []u8,
	fdcount: size,
	marker: u8,
	sent: bool,
	complete: bool,
};

// Send a message larger than the socket buffers so it is written across many
// partial sends, and verify that the payload arrives intact.
@test fn msg_partial() void = {
	let loop = newloop()!;
	defer finish(&loop);

	let sv: [2]int = [0, 0];
	sys::socketpair(sys::AF_UNIX: int,
		sys::SOCK_STREAM | sys::SOCK_NONBLOCK | sys::SOCK_CLOEXEC,
		0, &sv)!;
	let bufsz = 4096i;
	sys::setsockopt(sv[0], sys::SOL_SOCKET, sys::SO_SNDBUF,
		&bufsz, size(int): u32)!;
	sys::setsockopt(sv[1], sys::SOL_SOCKET, sys::SO_RCVBUF,
		&bufsz, size(int): u32)!;
	const tx = register(&loop, sv[0]: io::file)!;
	defer close(tx);
	const rx = register(&loop, sv[1]: io::file)!;
	defer close(rx);

	let p: [2]int = [0, 0];
	sys::pipe2(&p, sys::O_CLOEXEC)!;
	defer io::close(p[0]: io::file)!;
	defer io::close(p[1]: io::file)!;
	const marker: [1]u8 = ['Z'];
	io::write(p[1]: io::file, marker)!;

	const total = 128z * 1024;
	let payload = alloc([0u8...], total)!;
	defer free(payload);
	for (let i = 0z; i < total; i += 1) {
		payload[i] = (i & 0xff): u8;
	};
	const half = total / 2;

	let smsg = net::newmsg();
	defer net::finish(&smsg);
	net::addvector(&smsg, payload[..half])!;
	net::addvector(&smsg, payload[half..])!;
	net::unix::addfiles(&smsg, p[0]: io::file)!;

	let rbuf = alloc([0u8...], 8192)!;
	defer free(rbuf);
	let rmsg = net::newmsg();
	defer net::finish(&rmsg);
	net::addvector(&rmsg, rbuf)!;
	net::unix::allocfiles(&rmsg, 1)!;

	let state = parttest {
		total = total,
		rbuf = rbuf,
		marker = 'Z',
		...
	};

	let sreq = sendmsgreq_init(tx, &state);
	sendmsg(&sreq, &smsg, &on_parttest_send);

	let rreq = recvmsgreq_init(rx, &state);
	recvmsg(&rreq, &rmsg, &on_parttest_recv);

	run(&loop)!;

	assert(state.sent, "send callback did not fire");
	assert(state.complete, "receive did not complete");
	assert(state.fdcount == 1, "expected exactly one descriptor");
};

fn on_parttest_send(
	req: *sendmsgreq,
	r: (size | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *parttest;
	assert(r is size, "sendmsg failed");
	assert(r as size == state.total, "wrong total sent");
	state.sent = true;
};

fn on_parttest_recv(
	req: *recvmsgreq,
	msg: *net::msghdr,
	r: (size | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *parttest;
	const n = r as size;
	for (let i = 0z; i < n; i += 1) {
		assert(state.rbuf[i] == ((state.off + i) & 0xff): u8,
			"payload corrupted");
	};

	const files = net::unix::recvfiles(msg, 1);
	state.fdcount += len(files);
	for (let i = 0z; i < len(files); i += 1) {
		let got: [1]u8 = [0];
		assert(io::read(files[i], got) as size == 1, "short read");
		assert(got[0] == state.marker, "wrong data through descriptor");
		io::close(files[i])!;
	};

	state.off += n;
	if (state.off < state.total) {
		recvmsg(req, msg, &on_parttest_recv);
	} else {
		state.complete = true;
	};
};
