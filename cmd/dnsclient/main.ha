use ev;
use ev_dns = ev::dns;
use fmt;
use net::ip;
use net::dns;
use os;

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	let i = 1z;
	const req = ev_dns::dnsreq_init(&loop, &i)!;
	defer ev_dns::dnsreq_finish(&req);

	do_query(&req, os::args[i]);
	ev::run(&loop)!;
};

fn do_query(req: *ev_dns::dnsreq, targ: str) void = {
	const domain = dns::parse_domain(targ)!;
	defer free(domain);

	const msg = dns::message {
		header = dns::header {
			id = 1337,
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
	ev_dns::query(req, &msg, &on_query)!;
};

fn on_query(
	req: *ev_dns::dnsreq,
	r: (*dns::message | dns::error | nomem),
	user: nullable *opaque,
) void = {
	const msg = match (r) {
	case let msg: *dns::message =>
		yield msg;
	case let err: dns::error =>
		fmt::errorln("Error:", dns::strerror(err))!;
		return;
	case nomem =>
		fmt::errorln("Error: out of memory")!;
		return;
	};

	for (let answer &.. msg.answers) {
		match (answer.rdata) {
		case let addr: dns::aaaa =>
			fmt::println(ip::string(addr))!;
		case let addr: dns::a =>
			fmt::println(ip::string(addr))!;
		case => void;
		};
	};

	let i = user: *size;
	*i += 1;
	if (*i < len(os::args)) {
		do_query(req, os::args[*i]);
	};
};
