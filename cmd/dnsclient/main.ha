use ev;
use ev::dial;
use fmt;
use net::ip;
use os;

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const addr = os::args[1], svc = os::args[2];
	dial::resolve(&loop, "tcp", addr, svc, &resolvecb, &loop)!;

	for (ev::dispatch(&loop, -1)!) void;
};

fn resolvecb(
	user: nullable *opaque,
	r: (([]ip::addr, u16) | dial::error),
) void = {
	const loop = user: *ev::loop;
	defer ev::stop(loop);

	const (ip, port) = match (r) {
	case let ip: ([]ip::addr, u16) =>
		yield ip;
	case let err: dial::error =>
		fmt::fatal("Dial error:", dial::strerror(err));
	};

	for (let i = 0z; i < len(ip); i += 1) {
		fmt::printfln("{}:{}", ip::string(ip[i]), port)!;
	};
};
