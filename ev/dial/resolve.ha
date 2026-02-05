use crypto::random;
use edns = ev::dns;
use errors;
use ev;
use io;
use net;
use net::dial;
use net::dns;
use net::ip;
use unix::hosts;

// TODO: ev::dial could maintain a pool of ev::dns::reqs (and their sockets)
//
// Or maybe ev::dns is better designed by adding a long-lived resolver which
// processes req's like an ev::file would

// Callback from a [[resolve]] operation.
export type resolvecb = fn(
	req: *resolver,
	result: (([]ip::addr, u16) | error),
	user: nullable *opaque,
) void;

export type resolver = struct {
	ev::req,
	nq: int,
	qa: edns::req,
	qaaaa: edns::req,
	cb: nullable *resolvecb,
	ip: []ip::addr,
	port: u16,
};

// Initializes a [[resolver]] for use with the given event loop, with an
// optional user data pointer.
//
// Once submitted to the event loop, a request object is borrowed from the
// caller and must remain stable until the request is cancelled or completed.
export fn resolver_init(
	loop: *ev::loop,
	user: nullable *opaque,
) resolver = {
	return resolver {
		loop = loop,
		user = user,
		qa = @undefined,
		qaaaa = @undefined,
		...
	};
};

// Performs DNS resolution on an Internet address string for a given service,
// including /etc/hosts lookup and SRV resolution if applicable, and returns a
// list of candidate IP addresses and the appropriate port, or an error, to the
// callback.
//
// The [[net::ip::addr]] slice's lifetime is the duration of the callback. The
// callback should duplicate this slice if the user needs to extend its
// lifetime.
export fn resolve(
	req: *resolver,
	proto: str,
	addr: str,
	service: str,
	cb: *resolvecb,
) (void | error) = {
	req.cb = cb;

	const (addr, port) = match (dial::splitaddr(addr, service)) {
	case let svc: (str, u16) =>
		yield svc;
	case dial::invalid_address =>
		resolve_finish(req, invalid_address);
		return;
	};

	if (service == "unknown" && port == 0) {
		resolve_finish(req, unknown_service);
		return;
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
		resolve_finish(req, unknown_service);
		return;
	};

	match (ip::parse(addr)) {
	case let addr: ip::addr =>
		let addrs: []ip::addr = [];
		defer free(addrs);
		match (append(addrs, addr)) {
		case void =>
			resolve_finish(req, (addrs, port));
			return;
		case nomem =>
			resolve_finish(req, nomem);
			return nomem;
		};
	case ip::invalid => yield;
	};

	const addrs = match (hosts::lookup(addr)) {
	case let addrs: []ip::addr =>
		yield addrs;
	case let e: hosts::error =>
		resolve_finish(req, e);
		return;
	};
	defer free(addrs);
	if (len(addrs) != 0) {
		resolve_finish(req, (addrs, port));
		return;
	};

	req.port = port;
	return resolve_dns(req, addr);
};

fn resolve_dns(
	req: *resolver,
	addr: str,
) (void | error) = {
	req.cancel = &resolve_cancel;
	req.qa = edns::req_init(req.loop as *ev::loop, req)?;
	req.qaaaa = edns::req_init(req.loop as *ev::loop, req)?;

	const domain = dns::parse_domain(addr)?;
	defer free(domain);

	let rand: []u8 = [0, 0];
	random::buffer(rand);
	let id = *(&rand[0]: *u16);

	const query4 = dns::message {
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
				qtype = dns::qtype::A,
				qclass = dns::qclass::IN,
			},
		],
		...
	};
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

	let ok = false;
	edns::query(&req.qaaaa, &query6, &on_dns_response)?;
	defer if (!ok) ev::cancel(&req.qaaaa);

	edns::query(&req.qa, &query4, &on_dns_response)?;
	ok = true;
};

fn on_dns_response(
	dnsreq: *edns::req,
	result: (*dns::message | dns::error | nomem),
	user: nullable *opaque,
) void = {
	let req = user: *resolver;

	match (result) {
	case let err: dns::error =>
		resolve_finish(req, err);
		return;
	case nomem =>
		resolve_finish(req, nomem);
		return;
	case let msg: *dns::message =>
		match (collect_answers(&req.ip, &msg.answers)) {
		case void => void;
		case nomem =>
			resolve_finish(req, nomem);
			return;
		};
		req.nq += 1;
	};

	if (req.nq < 2) {
		// Wait for the other query to finish
		return;
	};

	resolve_finish(req, (req.ip, req.port));
};

fn resolve_finish(
	req: *resolver,
	result: (([]ip::addr, u16) | error),
) void = {
	const ip = req.ip;
	defer free(ip);
	req.ip = [];

	edns::req_finish(&req.qa);
	edns::req_finish(&req.qaaaa);

	const cb = req.cb as *resolvecb;
	req.cb = null;

	cb(req, result, req.user);
};

fn resolve_cancel(req: *ev::req) void = {
	const req = req: *resolver;
	edns::req_finish(&req.qa);
	edns::req_finish(&req.qaaaa);
	free(req.ip);
	req.ip = [];
};

fn collect_answers(addrs: *[]ip::addr, answers: *[]dns::rrecord) (void | nomem) = {
	for (let answer &.. answers) {
		match (answer.rdata) {
		case let addr: dns::aaaa =>
			append(addrs, addr: ip::addr)?;
		case let addr: dns::a =>
			append(addrs, addr: ip::addr)?;
		case => void;
		};
	};
};
