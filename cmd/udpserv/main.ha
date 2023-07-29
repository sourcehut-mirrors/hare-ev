use errors;
use ev;
use log;
use net;
use net::ip;
use os;

type state = struct {
	loop: *ev::loop,
	src: ip::addr,
	port: u16,
	buf: [os::BUFSIZ]u8,
	wbuf: []u8,
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
		src = [0: u8, 0: u8, 0: u8, 0: u8],
		...
	};
	ev::setuser(sock, &state);
	ev::recvfrom(sock, &recv, state.buf);

	log::println("Listening on 127.0.0.1:12345");
	for (ev::dispatch(&loop, -1)!) void;
};

fn recv(sock: *ev::file, r: ((size, ip::addr, u16) | net::error)) void = {
	const state = ev::getuser(sock): *state;
	const (n, src, port) = match (r) {
	case let err: net::error =>
		log::println("Error: recv:", net::strerror(err));
		ev::stop(state.loop);
		return;
	case let packet: (size, ip::addr, u16) =>
		yield packet;
	};

	// TODO: Make ev send/write all data and drop these fields and the need
	// to manually manage a write buffer and re-call sendto in &send
	state.src = src;
	state.port = port;

	log::printfln("{} bytes from {}:{}", n, ip::string(src), port);
	state.wbuf = state.buf[..n];
	ev::sendto(sock, &send, state.wbuf, src, port);
};

fn send(sock: *ev::file, r: (size | net::error)) void = {
	const state = ev::getuser(sock): *state;
	const n = match (r) {
	case let err: net::error =>
		log::println("Error: send:", net::strerror(err));
		ev::stop(state.loop);
		return;
	case let n: size =>
		yield n;
	};

	static delete(state.wbuf[..n]);

	if (len(state.wbuf) != 0) {
		ev::sendto(sock, &send, state.wbuf, state.src, state.port);
	} else {
		ev::recvfrom(sock, &recv, state.buf);
	};
};
