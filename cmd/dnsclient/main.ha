use crypto::random;
use ev;
use edns = ev::dns;
use fmt;
use net::dns;
use net::ip;
use os;

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	let rand: []u8 = [0, 0];
	random::buffer(rand);
	let id = *(&rand[0]: *u16);

	const domain = dns::parse_domain(os::args[1]);
	defer free(domain);

	const query = dns::message {
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

	edns::query(&loop, &query, &querycb, &loop)!;

	for (ev::dispatch(&loop, -1)!) void;
};

fn querycb(user: nullable *opaque, r: (*dns::message | dns::error)) void = {
	const loop = user: *ev::loop;
	const resp = match (r) {
	case let msg: *dns::message =>
		yield msg;
	case let err: dns::error =>
		fmt::errorln("DNS error:", dns::strerror(err))!;
		ev::stop(loop);
		return;
	};

	for (let i = 0z; i < len(resp.answers); i += 1) {
		match (resp.answers[i].rdata) {
		case let addr: dns::aaaa =>
			fmt::println(ip::string(addr))!;
		case let addr: dns::a =>
			fmt::println(ip::string(addr))!;
		case => void;
		};
	};
	ev::stop(loop);
};
