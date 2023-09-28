// License: MPL-2.0
// (c) 2021-2023 Drew DeVault <sir@cmpwn.com>
// (c) 2021 Bor Grošelj Simić <bor.groseljsimic@telemach.net>
// (c) 2021 Ember Sawady <ecs@d2evs.net>
//
// Provides default dialers for tcp and udp
use errors;
use ev;
use net;
use net::ip;
use net::tcp;
use net::udp;

type tcp_dialer = struct {
	loop: *ev::loop,
	cb: *dialcb,
	user: nullable *opaque,
	req: ev::req,
	ip: []ip::addr,
	port: u16,
};

fn dial_tcp(
	loop: *ev::loop,
	addr: str,
	service: str,
	cb: *dialcb,
	user: nullable *opaque,
) (ev::req | error) = {
	let state = alloc(tcp_dialer {
		loop = loop,
		cb = cb,
		user = user,
		...
	});

	const req = resolve(loop, "tcp", addr,
		service, &dial_tcp_resolvecb, state)?;
	state.req = req;
	return ev::mkreq(&dial_tcp_cancel, state);
};

fn dial_tcp_resolvecb(
	user: nullable *opaque,
	r: (([]ip::addr, u16) | error),
) void = {
	let state = user: *tcp_dialer;
	state.req = ev::req { ... };
	const (ip, port) = match (r) {
	case let r: ([]ip::addr, u16) =>
		yield r;
	case let err: error =>
		dial_tcp_complete(state, err);
		return;
	};

	state.ip = ip;
	state.port = port;
	dial_tcp_connect(state);
};

fn dial_tcp_connect(state: *tcp_dialer) void = {
	// TODO: Select IPs from a round-robin, or re-attempt on other IPs?
	// TODO: Detect supported networks? i.e. v4/v6
	const req = match (ev::connect_tcp(state.loop,
			&dial_tcp_connectcb,
			state.ip[0], state.port,
			state)) {
	case let err: (net::error | errors::error) =>
		dial_tcp_complete(state, err);
		return;
	case let req: ev::req =>
		yield req;
	};
	state.req = req;
};

fn dial_tcp_connectcb(
	r: (*ev::file | net::error),
	user: nullable *opaque,
) void = {
	let state = user: *tcp_dialer;
	match (r) {
	case let sock: *ev::file =>
		ev::setuser(sock, null);
		dial_tcp_complete(state, sock);
	case let err: net::error =>
		dial_tcp_complete(state, err);
	};
};

fn dial_tcp_cancel(req: *ev::req) void = {
	let state = req: *tcp_dialer;
	ev::cancel(&state.req);
	free(state.ip);
	free(state);
};

fn dial_tcp_complete(state: *tcp_dialer, r: (*ev::file | error)) void = {
	const cb = state.cb;
	const user = state.user;
	free(state.ip);
	free(state);
	cb(user, r);
};

type udp_dialer = struct {
	loop: *ev::loop,
	cb: *dialcb,
	user: nullable *opaque,
	req: ev::req,
	ip: []ip::addr,
	port: u16,
};

fn dial_udp(
	loop: *ev::loop,
	addr: str,
	service: str,
	cb: *dialcb,
	user: nullable *opaque,
) (ev::req | error) = {
	let state = alloc(udp_dialer {
		loop = loop,
		cb = cb,
		user = user,
		...
	});

	const req = resolve(loop, "udp", addr,
		service, &dial_udp_resolvecb, state)?;
	state.req = req;
	return ev::mkreq(&dial_udp_cancel, state);
};

fn dial_udp_resolvecb(
	user: nullable *opaque,
	r: (([]ip::addr, u16) | error),
) void = {
	let state = user: *udp_dialer;
	state.req = ev::req { ... };
	const (ip, port) = match (r) {
	case let r: ([]ip::addr, u16) =>
		yield r;
	case let err: error =>
		dial_udp_complete(state, err);
		return;
	};

	state.ip = ip;
	state.port = port;
	dial_udp_connect(state);
};

fn dial_udp_connect(state: *udp_dialer) void = {
	match (ev::connect_udp(state.loop,
			state.ip[0], state.port)) {
	case let err: (net::error | errors::error) =>
		dial_udp_complete(state, err);
		return;
	case let sock: *ev::file =>
		dial_udp_complete(state, sock);
		return;
	};
};

fn dial_udp_cancel(req: *ev::req) void = {
	let state = req: *udp_dialer;
	ev::cancel(&state.req);
	free(state.ip);
	free(state);
};

fn dial_udp_complete(state: *udp_dialer, r: (*ev::file | error)) void = {
	const cb = state.cb;
	const user = state.user;
	free(state.ip);
	free(state);
	cb(user, r);
};
