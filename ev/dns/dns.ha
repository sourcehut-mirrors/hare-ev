use errors;
use ev;
use net;
use net::dns;
use net::ip;
use net::udp;
use time;
use unix::resolvconf;

// TODO: Let users customize this?
def TIMEOUT: time::duration = 3 * time::SECOND;

// Callback for a [[query]] operation.
export type querycb = fn(
	user: nullable *opaque,
	r: (*dns::message | dns::error),
) void;

type qstate = struct {
	buf: [512]u8,
	socket4: *ev::file,
	socket6: *ev::file,
	r4: ev::req,
	r6: ev::req,
	timer: *ev::file,
	rid: u16,
	cb: *querycb,
	user: nullable *opaque,
};

// Performs a DNS query against the provided set of DNS servers, or the list of
// servers from /etc/resolv.conf if none are specified. The user must free the
// message passed to the callback with [[net::dns::message_free]].
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
		socket4 = socket4,
		socket6 = socket6,
		timer = timeout,
		rid = query.header.id,
		cb = cb,
		user = user,
		...
	});
	const z = dns::encode(state.buf, query)?;
	ev::setuser(socket4, state);
	ev::setuser(socket6, state);
	ev::setuser(timeout, state);
	ev::timer_configure(timeout, TIMEOUT, 0);

	// Note: the initial set of requests is sent directly through net::udp
	// as it is assumed they can fit into the kernel's internal send buffer
	// and will finish without blocking
	const buf = state.buf[..z];
	for (const server .. servers) {
		match (server) {
		case ip::addr4 =>
			udp::sendto(ev::getfd(socket4), buf, server, 53)?;
		case ip::addr6 =>
			udp::sendto(ev::getfd(socket6), buf, server, 53)?;
		};
	};

	state.r4 = ev::recvfrom(socket4, &qrecvcb, state.buf);
	state.r6 = ev::recvfrom(socket6, &qrecvcb, state.buf);
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
	free(q);
};

fn query_complete(q: *qstate, r: (*dns::message | dns::error)) void = {
	const cb = q.cb;
	const user = q.user;
	query_destroy(q);
	cb(user, r);
};

fn timeoutcb(file: *ev::file) void = {
	const q = ev::getuser(file): *qstate;
	query_complete(q, errors::timeout);
};

fn qrecvcb(file: *ev::file, r: ((size, ip::addr, u16) | net::error)) void = {
	const q = ev::getuser(file): *qstate;
	let req: *ev::req = if (file == q.socket4) &q.r4 else &q.r6;
	*req = ev::req { ... };

	const (z, addr, port) = match (r) {
	case let r: (size, ip::addr, u16) =>
		yield r;
	case let err: net::error =>
		query_complete(q, err);
		return;
	};

	const resp = match (dns::decode(q.buf[..z])) {
	case dns::format =>
		*req = ev::recvfrom(file, &qrecvcb, q.buf);
		return;
	case let msg: *dns::message =>
		yield msg;
	};
	defer dns::message_free(resp);

	if (resp.header.id != q.rid || resp.header.op.qr != dns::qr::RESPONSE) {
		*req = ev::recvfrom(file, &qrecvcb, q.buf);
		return;
	};

	if (!resp.header.op.tc) {
		query_complete(q, resp);
		return;
	};

	abort(); // TODO: retry over TCP
};
