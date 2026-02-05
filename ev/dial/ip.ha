// License: MPL-2.0
// (c) 2021-2023 Drew DeVault <sir@cmpwn.com>
// (c) 2021 Bor Grošelj Simić <bor.groseljsimic@telemach.net>
// (c) 2021 Ember Sawady <ecs@d2evs.net>
//
// Provides default dialers for tcp and udp
use errors;
use ev;
use math::random;
use net::ip;
use net::tcp;
use net::udp;
use net;
use time;

type tcp_dialer = struct {
	req: *dialreq,
	resolve: resolver,
	connect: ev::sockreq,
	ip: []ip::addr,
	port: u16,
	n: uint,
};

fn dial_tcp(
	req: *dialreq,
	addr: str,
	service: str,
	cb: *dialcb,
) (void | error) = {
	const loop = req.loop as *ev::loop;

	let ok = false;
	let dialer = alloc(tcp_dialer {
		req = req,
		resolve = @undefined,
		connect = @undefined,
		...
	})?;
	defer if (!ok) free(dialer);

	dialer.resolve = resolver_init(loop, dialer);
	dialer.connect = ev::connect_init(loop, dialer);

	req.dialer = dialer;
	req.cancel = &dial_tcp_cancel;
	req.cb = cb;

	match (resolve(&dialer.resolve,
		"tcp", addr, service,
		&dial_tcp_on_resolved)) {
	case void =>
		ok = true;
	case let err: error =>
		return err;
	};
};

fn dial_tcp_on_resolved(
	resolver: *resolver,
	r: (([]ip::addr, u16) | error),
	user: nullable *opaque,
) void = {
	let dialer = user: *tcp_dialer;

	const (ip, port) = match (r) {
	case let r: ([]ip::addr, u16) =>
		yield r;
	case let err: error =>
		dial_tcp_complete(dialer, err);
		return;
	};

	dialer.ip = match (alloc(ip...)) {
	case let ip: []ip::addr =>
		yield ip;
	case nomem =>
		dial_tcp_complete(dialer, nomem);
		return;
	};
	dialer.port = port;
	dial_tcp_connect(dialer);
};

fn dial_tcp_connect(dialer: *tcp_dialer) void = {
	match (ev::connect_tcp(&dialer.connect,
		dialer.ip[dialer.n], dialer.port,
		&dial_tcp_on_connected)) {
	case let err: (net::error | errors::error) =>
		dial_tcp_complete(dialer, err);
	case void => void;
	};
};

fn dial_tcp_on_connected(
	sockreq: *ev::sockreq,
	r: (*ev::file | net::error),
	user: nullable *opaque,
) void = {
	let dialer = user: *tcp_dialer;

	match (r) {
	case let sock: *ev::file =>
		dial_tcp_complete(dialer, sock);
	case let err: net::error =>
		dialer.n += 1;
		if (dialer.n < len(dialer.ip)) {
			// Try the next one
			dial_tcp_connect(dialer);
			return;
		};
		dial_tcp_complete(dialer, err);
	};
};

fn dial_tcp_cancel(req: *ev::req) void = {
	let req = req: *dialreq;
	let dialer = match (req.dialer) {
	case null =>
		return;
	case let dialer: *opaque =>
		req.dialer = null;
		yield dialer: *tcp_dialer;
	};

	ev::cancel(&dialer.resolve);
	ev::cancel(&dialer.connect);
	free(dialer.ip);
	free(dialer);
};

fn dial_tcp_complete(dialer: *tcp_dialer, r: (*ev::file | error)) void = {
	const req = dialer.req;
	const cb = req.cb as *dialcb;
	dial_tcp_cancel(req);
	cb(req, r, req.user);
};

type udp_dialer = struct {
	req: *dialreq,
	resolve: resolver,
};

fn dial_udp(
	req: *dialreq,
	addr: str,
	service: str,
	cb: *dialcb,
) (void | error) = {
	const loop = req.loop as *ev::loop;

	let ok = false;
	let dialer = alloc(udp_dialer {
		req = req,
		resolve = @undefined,
		...
	})?;
	defer if (!ok) free(dialer);

	dialer.resolve = resolver_init(loop, dialer);

	req.dialer = dialer;
	req.cancel = &dial_udp_cancel;
	req.cb = cb;

	match (resolve(&dialer.resolve,
		"udp", addr, service,
		&dial_udp_on_resolved)) {
	case void =>
		ok = true;
	case let err: error =>
		return err;
	};
};

fn dial_udp_on_resolved(
	resolver: *resolver,
	r: (([]ip::addr, u16) | error),
	user: nullable *opaque,
) void = {
	let dialer = user: *udp_dialer;

	const (ip, port) = match (r) {
	case let r: ([]ip::addr, u16) =>
		yield r;
	case let err: error =>
		dial_udp_complete(dialer, err);
		return;
	};

	dial_udp_connect(dialer, ip, port);
};

fn dial_udp_connect(dialer: *udp_dialer, ips: []ip::addr, port: u16) void = {
	const loop = dialer.req.loop as *ev::loop;
	for (let n = 0z; n < len(ips); n += 1) {
		const ip = ips[n];
		match (ev::connect_udp(loop, ip, port)) {
		case let err: net::error =>
			if (n + 1 < len(ips)) {
				continue;
			};
			dial_udp_complete(dialer, err);
			break;
		case let err: errors::error =>
			if (n + 1 < len(ips)) {
				continue;
			};
			dial_udp_complete(dialer, err);
			break;
		case let sock: *ev::file =>
			dial_udp_complete(dialer, sock);
			break;
		};
	};
};

fn dial_udp_cancel(req: *ev::req) void = {
	let req = req: *dialreq;
	let dialer = match (req.dialer) {
	case null =>
		return;
	case let dialer: *opaque =>
		req.dialer = null;
		yield dialer: *udp_dialer;
	};

	ev::cancel(&dialer.resolve);
	free(dialer);
};

fn dial_udp_complete(dialer: *udp_dialer, r: (*ev::file | error)) void = {
	const req = dialer.req;
	const cb = req.cb as *dialcb;
	dial_udp_cancel(req);
	cb(req, r, req.user);
};
