use crypto::random;
use errors;
use ev;
use edns = ev::dns;
use net;
use net::ip;
use net::dial;
use net::dns;
use unix::hosts;

// Callback from a [[resolve]] operation.
export type resolvecb = fn(
	user: nullable *opaque,
	r: (([]ip::addr, u16) | error),
) void;

type resolve_state = struct {
	user: nullable *opaque,
	cb: *resolvecb,
	r4: ev::req,
	r6: ev::req,
	nq: uint,
	ip: []ip::addr,
	port: u16,
};

// Performs DNS resolution on a given address string for a given service,
// including /etc/hosts lookup and SRV resolution, and returns a list of
// candidate IP addresses and the appropriate port, or an error, to the
// callback.
//
// The caller must free the [[net::ip::addr]] slice.
export fn resolve(
	loop: *ev::loop,
	proto: str,
	addr: str,
	service: str,
	cb: *resolvecb,
	user: nullable *opaque
) (ev::req | error) = {
	// TODO: Reduce duplication with net::dial
	let state = alloc(resolve_state {
		cb = cb,
		user = user,
		...
	});

	const (addr, port) = match (dial::splitaddr(addr, service)) {
	case let svc: (str, u16) =>
		yield svc;
	case dial::invalid_address =>
		resolve_finish(state, invalid_address);
		return ev::req { ... };
	};

	if (service == "unknown" && port == 0) {
		resolve_finish(state, unknown_service);
		return ev::req { ... };
	};

	if (port == 0) {
		match (lookup_service(proto, service)) {
		case let p: u16 =>
			port = p;
		case void => yield;
		};
	};

	// TODO:
	// - Consult /etc/services
	// - Fetch the SRV record

	if (port == 0) {
		resolve_finish(state, unknown_service);
		return ev::req { ... };
	};

	match (ip::parse(addr)) {
	case let addr: ip::addr =>
		const addrs = alloc([addr]);
		resolve_finish(state, (addrs, port));
		return ev::req { ... };
	case ip::invalid => yield;
	};

	const addrs = hosts::lookup(addr)?;
	if (len(addrs) != 0) {
		resolve_finish(state, (addrs, port));
		return ev::req { ... };
	};

	state.port = port;
	return resolve_dns(state, loop, addr);
};

fn resolve_dns(
	state: *resolve_state,
	loop: *ev::loop,
	addr: str,
) (ev::req | error) = {
	const domain = dns::parse_domain(addr);
	defer free(domain);

	let rand: []u8 = [0, 0];
	random::buffer(rand);
	let id = *(&rand[0]: *u16);

	const query6 = dns::message {
		header = dns::header {
			id = id,
			op = dns::op {
				qr = dns::qr::QUERY,
				opcode = dns::opcode::QUERY,
				rd = true,
				...
			},
			qdcount = 1,
			...
		},
		questions = [
			dns::question {
				qname = domain,
				qtype = dns::qtype::AAAA,
				qclass = dns::qclass::IN,
			},
		],
		...
	};
	const query4 = dns::message {
		header = dns::header {
			id = id + 1,
			op = dns::op {
				qr = dns::qr::QUERY,
				opcode = dns::opcode::QUERY,
				rd = true,
				...
			},
			qdcount = 1,
			...
		},
		questions = [
			dns::question {
				qname = domain,
				qtype = dns::qtype::A,
				qclass = dns::qclass::IN,
			},
		],
		...
	};

	state.r6 = edns::query(loop, &query6, &query_cb_v6, state)?;
	state.r4 = edns::query(loop, &query4, &query_cb_v4, state)?;
	return ev::mkreq(&resolve_cancel, state);
};

fn resolve_finish(st: *resolve_state, r: (([]ip::addr, u16) | error)) void = {
	const user = st.user;
	const cb = st.cb;
	if (r is error) {
		free(st.ip);
	};
	free(st);
	cb(user, r);
};

fn resolve_cancel(req: *ev::req) void = {
	const state = req.user: *resolve_state;
	ev::cancel(&state.r4);
	ev::cancel(&state.r6);
	free(state.ip);
	free(state);
};

fn query_cb_v4(user: nullable *opaque, r: (*dns::message | dns::error)) void = {
	let state = user: *resolve_state;
	state.r4 = ev::req { ... };

	match (r) {
	case let err: dns::error =>
		ev::cancel(&state.r6);
		resolve_finish(state, err);
		return;
	case let msg: *dns::message =>
		collect_answers(&state.ip, &msg.answers);
		state.nq += 1;
	};

	if (state.nq < 2) {
		return;
	};
	resolve_finish(state, (state.ip, state.port));
};

fn query_cb_v6(user: nullable *opaque, r: (*dns::message | dns::error)) void = {
	let state = user: *resolve_state;
	state.r6 = ev::req { ... };

	match (r) {
	case let err: dns::error =>
		ev::cancel(&state.r4);
		resolve_finish(state, err);
		return;
	case let msg: *dns::message =>
		collect_answers(&state.ip, &msg.answers);
		state.nq += 1;
	};

	if (state.nq < 2) {
		return;
	};
	resolve_finish(state, (state.ip, state.port));
};

fn collect_answers(addrs: *[]ip::addr, answers: *[]dns::rrecord) void = {
	for (let answer &.. answers) {
		match (answer.rdata) {
		case let addr: dns::aaaa =>
			append(addrs, addr: ip::addr);
		case let addr: dns::a =>
			append(addrs, addr: ip::addr);
		case => void;
		};
	};
};
