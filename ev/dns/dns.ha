use endian;
use errors;
use ev;
use io;
use net;
use net::dns;
use net::ip;
use net::udp;
use time;
use time::{clock};
use types;
use unix::resolvconf;

// Callback for a [[query]] operation.
export type querycb = fn(
	req: *req,
	r: (*dns::message | dns::error | nomem),
	user: nullable *opaque,
) void;

export type req = struct {
	ev::req,

	// UDP state
	s4: nullable *ev::file,
	s6: nullable *ev::file,
	r4: ev::dgramreq,
	r6: ev::dgramreq,

	// TCP state
	tcpsock: nullable *ev::file,
	connect: ev::sockreq,
	read: ev::ioreq,
	read_vector: [2]io::vector,

	// Timeout
	timer: ev::timer,
	timeout: time::duration,

	union {
		// Request ID
		rid: u16,
		// Response length
		resp_len: u16,
	},

	// Outgoing DNS query
	qbuf: []u8,
	qlen: u16,

	// Response buffer
	rbuf: []u8,
	rbuf_valid: u16,

	// Length buffer
	zbuf: [2]u8,

	// Callback
	cb: nullable *querycb,
};

export def REQ_INIT = req {
	r4 = ev::DGRAMREQ_INIT,
	r6 = ev::DGRAMREQ_INIT,
	timer = ev::TIMER_INIT,
	connect = ev::SOCKREQ_INIT,
	read = ev::IOREQ_INIT,
	...
};

// Initializes a new [[req]] for use with [[query]]. This function allocates
// memory and binds a UDP socket for the lifetime of the [[req]] object,
// which must be disposed of with [[req_finish]].
//
// Only one [[query]] may be performed at a time per [[req]]. In order to run
// multiple DNS queries in parallel, one must use multiple [[req]] objects.
// Once a DNS query completes (when its callback is run) or is cancelled (via
// [[ev::cancel]]), the [[req]] object may be reused.
export fn req_init(
	loop: *ev::loop,
	user: nullable *opaque = null,
	timeout: time::duration = 3 * time::SECOND,
) (req | net::error | errors::error | nomem) = {
	let req = REQ_INIT;
	let ok = false;
	defer if (!ok) req_finish(&req);
	req.loop = loop;
	req.s4 = ev::listen_udp(loop, ip::ANY_V4, 0)?;
	req.s6 = ev::listen_udp(loop, ip::ANY_V6, 0)?;
	req.timer = ev::timer_init(loop, clock::MONOTONIC, &on_timeout_expired)?;
	req.timeout = timeout;
	req.qbuf = alloc([0...], 512)?;
	req.rbuf = alloc([0...], types::U16_MAX)?;
	req.user = user;
	ok = true;
	return req;
};

// Disposes of resources associated with a [[req]].
export fn req_finish(req: *req) void = {
	ev::cancel(&req.r4);
	ev::cancel(&req.r6);
	ev::timer_finish(&req.timer);

	match (req.s4) {
	case let sock: *ev::file =>
		ev::close(sock);
		req.s4 = null;
	case null => void;
	};

	match (req.s6) {
	case let sock: *ev::file =>
		ev::close(sock);
		req.s6 = null;
	case null => void;
	};

	free(req.qbuf);
	free(req.rbuf);
};

// Performs a DNS query against the provided set of DNS servers, or the list of
// servers from /etc/resolv.conf if none are specified. The DNS message passed
// to the callback is only valid for the duration of the callback.
export fn query(
	req: *req,
	query: *dns::message,
	cb: *querycb,
	servers: ip::addr...
) (void | nomem | dns::error | net::error) = {
	if (len(servers) == 0) {
		const rconf = resolvconf::load();
		servers = rconf.nameservers;
	};
	if (len(servers) == 0) {
		// Fall back to localhost
		servers = [ip::LOCAL_V6, ip::LOCAL_V4];
	};

	assert(req.cb == null, "Cannot reuse in-flight DNS req");
	assert(req.s4 != null, "Attempted DNS query with uninitialized req");
	const s4 = req.s4 as *ev::file;
	const s6 = req.s6 as *ev::file;

	req.qlen = dns::encode(req.qbuf, query)?: u16;
	req.rid = query.header.id;
	req.cancel = &query_cancel;
	req.cb = cb;

	req.r4 = ev::dgramreq_init(s4, req);
	req.r6 = ev::dgramreq_init(s6, req);
	req.connect = ev::connect_init(req.loop as *ev::loop, req);

	ev::req_setuser(&req.timer, req);
	ev::timer_configure(&req.timer, req.timeout, 0);

	// Note: the initial set of requests is sent directly through net::udp
	// as it is assumed they can fit into the kernel's internal send buffer
	// and will finish without blocking
	const buf = req.qbuf[..req.qlen];
	for (const server .. servers) {
		match (server) {
		case ip::addr4 =>
			udp::sendto(ev::getfd(s4), buf, server, 53)?;
		case ip::addr6 =>
			udp::sendto(ev::getfd(s6), buf, server, 53)?;
		};
	};

	ev::recvfrom(&req.r4, req.rbuf, &on_recvfrom);
	ev::recvfrom(&req.r6, req.rbuf, &on_recvfrom);
};

fn on_recvfrom(
	dreq: *ev::dgramreq,
	r: ((size, ip::addr, u16) | net::error),
	user: nullable *opaque,
) void = {
	const dnsreq = user: *req;
	match (post_recv(dreq, dnsreq, r)) {
	case let result: (*dns::message | dns::error) =>
		query_complete(dnsreq, result);
	case errors::again =>
		// Wait for the next response in case this one was not suitable
		ev::recvfrom(dreq, dnsreq.rbuf, &on_recvfrom);
	case void => void;
	};
};

fn post_recv(
	udpreq: *ev::dgramreq,
	dnsreq: *req,
	r: ((size, ip::addr, u16) | net::error),
) (*dns::message | dns::error | errors::again | void) = {
	const (z, addr, port) = match (r) {
	case let r: (size, ip::addr, u16) =>
		yield r;
	case let err: net::error =>
		return err;
	};

	const resp = match (dns::decode(dnsreq.rbuf[..z])) {
	case dns::format =>
		return errors::again;
	case let msg: *dns::message =>
		yield msg;
	};

	const header = &resp.header;
	if (header.id != dnsreq.rid || header.op.qr != dns::qr::RESPONSE) {
		dns::message_free(resp);
		return errors::again;
	};

	if (!header.op.tc) {
		return resp;
	};

	// Reponse truncated, retry over TCP
	dns::message_free(resp);

	// Cancel UDP requests
	ev::cancel(&dnsreq.r4);
	ev::cancel(&dnsreq.r6);

	dnsreq.rbuf_valid = 0;

	match (ev::connect_tcp(&dnsreq.connect, addr, 53, &on_tcp_connected)) {
	case let err: net::error =>
		return err;
	case let err: errors::error =>
		return err: net::error;
	case void => void;
	};
};

fn on_tcp_connected(
	sockreq: *ev::sockreq,
	result: (*ev::file | net::error),
	user: nullable *opaque,
) void = {
	const dnsreq = user: *req;
	const sock = match (result) {
	case let file: *ev::file =>
		yield file;
	case let err: net::error =>
		query_complete(dnsreq, err);
		return;
	};

	dnsreq.tcpsock = sock;
	dnsreq.read = ev::ioreq_init(sock, dnsreq);

	endian::beputu16(dnsreq.zbuf, dnsreq.qlen);
	dnsreq.read_vector = [
		io::mkvector(dnsreq.zbuf),
		io::mkvector(dnsreq.qbuf[..dnsreq.qlen]),
	];
	ev::writev(&dnsreq.read, dnsreq.read_vector, &on_tcp_write);
};

fn on_tcp_write(
	ioreq: *ev::ioreq,
	result: (size | io::error),
	user: nullable *opaque,
) void = {
	const dnsreq = user: *req;

	match (result) {
	case size => void;
	case let err: io::error =>
		query_complete(dnsreq, err);
		return;
	};

	ev::read(ioreq, dnsreq.zbuf, &on_tcp_read_length);
};

fn on_tcp_read_length(
	ioreq: *ev::ioreq,
	result: (size | io::EOF | io::error),
	user: nullable *opaque,
) void = {
	const dnsreq = user: *req;

	match (result) {
	case size => void;
	case let err: io::error =>
		query_complete(dnsreq, err);
		return;
	case io::EOF =>
		query_complete(dnsreq, dns::format);
		return;
	};

	dnsreq.resp_len = endian::begetu16(dnsreq.zbuf);
	ev::read(ioreq, dnsreq.rbuf, &on_tcp_read_resp);
};

fn on_tcp_read_resp(
	ioreq: *ev::ioreq,
	result: (size | io::EOF | io::error),
	user: nullable *opaque,
) void = {
	const dnsreq = user: *req;

	match (result) {
	case let z: size =>
		const rlen = z: u16;
		if (dnsreq.rbuf_valid + rlen > dnsreq.resp_len) {
			query_complete(dnsreq, dns::format);
			return;
		};
		dnsreq.rbuf_valid += rlen;
	case io::EOF =>
		return;
	};

	if (dnsreq.rbuf_valid < dnsreq.resp_len) {
		ev::read(ioreq, dnsreq.rbuf[dnsreq.rbuf_valid..], &on_tcp_read_resp);
		return;
	};

	const resp = match (dns::decode(dnsreq.rbuf[..dnsreq.rbuf_valid])) {
	case dns::format =>
		query_complete(dnsreq, dns::format);
		return;
	case let msg: *dns::message =>
		yield msg;
	};
	query_complete(dnsreq, resp);
};

fn query_cancel(r: *ev::req) void = {
	const req = r: *req;
	ev::cancel(&req.r4);
	ev::cancel(&req.r6);
	ev::cancel(&req.connect);
	ev::cancel(&req.read);
	ev::cancel(&req.timer);

	// TODO: Reuse the TCP socket
	// https://todo.sr.ht/~sircmpwn/hare/969
	match (req.tcpsock) {
	case let sock: *ev::file =>
		ev::close(sock);
		req.tcpsock = null;
	case null => void;
	};
};

fn query_complete(
	req: *req,
	outcome: (*dns::message | dns::error | nomem),
) void = {
	ev::cancel(req);

	const cb = req.cb as *querycb;
	req.cb = null;
	cb(req, outcome, req.user);

	match (outcome) {
	case let msg: *dns::message =>
		dns::message_free(msg);
	case => void;
	};
};

fn on_timeout_expired(timer: *ev::timer, user: nullable *opaque) void = {
	const req = user: *req;
	query_complete(req, errors::timeout);
};
