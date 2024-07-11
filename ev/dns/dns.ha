use endian;
use errors;
use ev;
use io;
use net;
use net::dns;
use net::ip;
use net::udp;
use time;
use types;
use unix::resolvconf;

// TODO: Let users customize this?
def TIMEOUT: time::duration = 3 * time::SECOND;

// Callback for a [[query]] operation.
export type querycb = fn(
	user: nullable *opaque,
	r: (*dns::message | dns::error),
) void;

type qstate = struct {
	// Event loop objects
	loop: *ev::loop,
	socket4: *ev::file,
	socket6: *ev::file,
	r4: ev::req,
	r6: ev::req,
	timer: *ev::file,

	// Request ID
	rid: u16,

	// Outgoing DNS request
	query: [512]u8,
	qlen: u16,

	// Response buffer
	rbuf: []u8,
	rbuf_valid: u16,

	// Length buffer
	zbuf: [2]u8,

	// Callback and user data
	cb: *querycb,
	user: nullable *opaque,
};

// Performs a DNS query against the provided set of DNS servers, or the list of
// servers from /etc/resolv.conf if none are specified. The DNS message passed
// to the callback is only valid for the duration of the callback.
export fn query(
	loop: *ev::loop,
	query: *dns::message,
	cb: *querycb,
	user: nullable *opaque,
	servers: ip::addr...
) (ev::req | dns::error | net::error | errors::error) = {
	if (len(servers) == 0) {
		const rconf = resolvconf::load();
		servers = rconf.nameservers;
	};
	if (len(servers) == 0) {
		// Fall back to localhost
		servers = [ip::LOCAL_V6, ip::LOCAL_V4];
	};

	const socket4 = ev::listen_udp(loop, ip::ANY_V4, 0)?;
	const socket6 = ev::listen_udp(loop, ip::ANY_V6, 0)?;
	const timeout = ev::newtimer(loop, &timeoutcb, time::clock::MONOTONIC)?;
	let state = alloc(qstate {
		loop = loop,
		socket4 = socket4,
		socket6 = socket6,
		timer = timeout,
		rbuf = alloc([0...], 512),
		rid = query.header.id,
		cb = cb,
		user = user,
		...
	});
	state.qlen = dns::encode(state.query, query)?: u16;
	ev::setuser(socket4, state);
	ev::setuser(socket6, state);
	ev::setuser(timeout, state);
	ev::timer_configure(timeout, TIMEOUT, 0);

	// Note: the initial set of requests is sent directly through net::udp
	// as it is assumed they can fit into the kernel's internal send buffer
	// and will finish without blocking
	const buf = state.query[..state.qlen];
	for (const server .. servers) {
		match (server) {
		case ip::addr4 =>
			udp::sendto(ev::getfd(socket4), buf, server, 53)?;
		case ip::addr6 =>
			udp::sendto(ev::getfd(socket6), buf, server, 53)?;
		};
	};

	state.r4 = ev::recvfrom(socket4, &qrecvcb, state.rbuf);
	state.r6 = ev::recvfrom(socket6, &qrecvcb, state.rbuf);
	return ev::mkreq(&query_cancel, state);
};

fn query_cancel(req: *ev::req) void = {
	const q = req.user: *qstate;
	query_destroy(q);
};

fn query_destroy(q: *qstate) void = {
	ev::cancel(&q.r4);
	ev::cancel(&q.r6);
	ev::close(q.socket4);
	ev::close(q.socket6);
	ev::close(q.timer);
	free(q.rbuf);
	free(q);
};

fn query_complete(q: *qstate, r: (*dns::message | dns::error)) void = {
	const cb = q.cb;
	const user = q.user;
	cb(user, r);
	match (r) {
	case let msg: *dns::message =>
		dns::message_free(msg);
	case => void;
	};
	query_destroy(q);
};

fn timeoutcb(file: *ev::file) void = {
	const q = ev::getuser(file): *qstate;
	query_complete(q, errors::timeout);
};

fn qrecvcb(file: *ev::file, r: ((size, ip::addr, u16) | net::error)) void = {
	const q = ev::getuser(file): *qstate;
	match (qrecv(q, file, r)) {
	case void => void;
	case let r: (*dns::message | dns::error) =>
		query_complete(q, r);
	};
};

fn qrecv(
	q: *qstate,
	file: *ev::file,
	r: ((size, ip::addr, u16) | net::error),
) (*dns::message | dns::error | void) = {
	let req: *ev::req = if (file == q.socket4) &q.r4 else &q.r6;
	*req = ev::req { ... };

	const (z, addr, port) = match (r) {
	case let r: (size, ip::addr, u16) =>
		yield r;
	case let err: net::error =>
		query_complete(q, err);
		return;
	};

	const resp = match (dns::decode(q.rbuf[..z])) {
	case dns::format =>
		*req = ev::recvfrom(file, &qrecvcb, q.rbuf);
		return;
	case let msg: *dns::message =>
		yield msg;
	};

	if (resp.header.id != q.rid || resp.header.op.qr != dns::qr::RESPONSE) {
		*req = ev::recvfrom(file, &qrecvcb, q.rbuf);
		dns::message_free(resp);
		return;
	};

	if (!resp.header.op.tc) {
		return resp;
	};

	dns::message_free(resp);

	// Reponse truncated, retry over TCP
	//
	// Note that when we switch to TCP, we only use the r4 field for
	// in-flight requests (even if we're using IPv6), and likewise once the
	// TCP connection is estabilshed the UDP socket at socket4 is closed and
	// replaced with the TCP socket (regardless of domain).

	// Cancel in-flight UDP queries
	ev::cancel(&q.r4);
	ev::cancel(&q.r6);

	match (ev::connect_tcp(q.loop, &qconnected, addr, 53, q)) {
	case let req: ev::req =>
		q.r4 = req;
	case let err: net::error =>
		return err;
	case let err: errors::error =>
		return err: net::error;
	};
};

fn qconnected(result: (*ev::file | net::error), user: nullable *opaque) void = {
	const q = user: *qstate;
	q.r4 = ev::req { ... };
	const sock = match (result) {
	case let file: *ev::file =>
		yield file;
	case let err: net::error =>
		query_complete(q, err);
		return;
	};

	ev::close(q.socket4);
	q.socket4 = sock;

	endian::beputu16(q.zbuf, q.qlen);

	q.r4 = ev::writev(sock,
		&qtcp_write_cb,
		io::mkvector(q.zbuf),
		io::mkvector(q.query[..q.qlen]));
};

fn qtcp_write_cb(file: *ev::file, result: (size | io::error)) void = {
	const q = ev::getuser(file): *qstate;
	q.r4 = ev::req { ... };
	match (result) {
	case let z: size =>
		// XXX: some (stupid) configurations may have a TCP buffer less
		// than 514 bytes, which we might want to handle, but generally
		// the request should make it to the TCP buffer in a single
		// writev call.
		assert(z: u16 == q.qlen + 2);
	case let err: io::error =>
		query_complete(q, err);
	};

	q.r4 = ev::read(file, &qtcp_readlength_cb, q.zbuf);
};

fn qtcp_readlength_cb(
	file: *ev::file,
	result: (size | io::EOF | io::error),
) void = {
	const q = ev::getuser(file): *qstate;
	match (result) {
	case let z: size =>
		if (z != 2) {
			query_complete(q, dns::format);
			return;
		};
	case let err: io::error =>
		query_complete(q, err);
		return;
	case io::EOF =>
		query_complete(q, dns::format);
		return;
	};

	const rlen = endian::begetu16(q.zbuf);
	q.rid = rlen;
	q.rbuf = alloc([0...], rlen);
	q.r4 = ev::read(file, &qtcp_readdata_cb, q.rbuf);
};

fn qtcp_readdata_cb(
	file: *ev::file,
	result: (size | io::EOF | io::error),
) void = {
	const q = ev::getuser(file): *qstate;
	q.r4 = ev::req { ... };
	match (result) {
	case let z: size =>
		const rlen = z: u16;
		if (q.rbuf_valid + rlen > q.rid) {
			query_complete(q, dns::format);
			return;
		};
		q.rbuf_valid += rlen;
	case io::EOF =>
		return;
	};

	if (q.rbuf_valid < q.rid) {
		// Read more data from the socket
		q.r4 = ev::read(file, &qtcp_readdata_cb, q.rbuf[q.rbuf_valid..]);
		return;
	};

	const resp = match (dns::decode(q.rbuf[..q.rbuf_valid])) {
	case dns::format =>
		query_complete(q, dns::format);
		return;
	case let msg: *dns::message =>
		yield msg;
	};
	query_complete(q, resp);
};
