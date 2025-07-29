use errors;
use ev;
use log;
use net;
use net::ip;
use os;

type state = struct {
	loop: *ev::loop,
	buf: [os::BUFSZ]u8,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const sock = match (ev::listen_udp(&loop, ip::LOCAL_V4, 12345)) {
	case let err: net::error =>
		log::fatalf("Error: listen: {}", net::strerror(err));
	case let err: errors::error =>
		log::fatalf("Error: listen: {}", errors::strerror(err));
	case let sock: *ev::file =>
		yield sock;
	};
	defer ev::close(sock);

	let state = state {
		loop = &loop,
		...
	};
	let req = ev::dgramreq_init(sock, &state);
	ev::recvfrom(&req, state.buf, &on_recv);

	log::println("Listening on 127.0.0.1:12345");
	ev::run(&loop)!;
};

fn on_recv(
	req: *ev::dgramreq,
	r: ((size, ip::addr, u16) | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;
	const (n, src, port) = match (r) {
	case let err: net::error =>
		log::println("Error: recv:", net::strerror(err));
		ev::stop(state.loop);
		return;
	case let packet: (size, ip::addr, u16) =>
		yield packet;
	};

	log::printfln("{} bytes from {}:{}", n, ip::string(src), port);
	ev::sendto(req, state.buf[..n], src, port, &on_send_complete);
};

fn on_send_complete(
	req: *ev::dgramreq,
	r: (size | net::error),
	user: nullable *opaque,
) void = {
	const state = user: *state;
	const (dest, port) = ev::dgramreq_getdest(req);

	match (r) {
	case size =>
		ev::recvfrom(req, state.buf, &on_recv);
	case let err: net::error =>
		log::println("Error: send:", net::strerror(err));
		ev::stop(state.loop);
	};
};
