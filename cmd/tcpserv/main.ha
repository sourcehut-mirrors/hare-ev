use errors;
use ev;
use io;
use log;
use net;
use net::ip;
use net::tcp;
use os;
use unix::signal;

type server = struct {
	loop: *ev::loop,
	sock: *ev::file,
	clients: []*client,
	exit: int,
};

type client = struct {
	server: *server,
	sock: *ev::file,
	addr: ip::addr,
	port: u16,
	buf: [os::BUFSZ]u8,
	ioreq: ev::ioreq,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const sock = match (ev::listen_tcp(&loop, ip::LOCAL_V4, 12345)) {
	case let err: net::error =>
		log::fatalf("Error: listen: {}", net::strerror(err));
	case let err: errors::error =>
		log::fatalf("Error: listen: {}", errors::strerror(err));
	case let sock: *ev::file =>
		yield sock;
	};
	defer ev::close(sock);

	let state = server {
		loop = &loop,
		sock = sock,
		...
	};
	let req = ev::accept_init(sock, &state);
	ev::accept(&req, &server_accept);

	const sig = ev::signal_init(&loop, &state,
		signal::sig::INT, signal::sig::TERM)!;
	defer ev::signal_finish(&sig);
	ev::handle(&sig, &on_signal);

	log::println("Listening on 127.0.0.1:12345");
	ev::run(&loop)!;
	os::exit(state.exit);
};

fn on_signal(req: *ev::signal, sig: signal::sig, user: nullable *opaque) void = {
	const server = user: *server;
	log::printfln("Exiting due to {}", signal::signame(sig));
	ev::stop(server.loop);
};

fn server_accept(
	req: *ev::sockreq,
	r: (*ev::file | net::error),
	user: nullable *opaque,
) void = {
	let server = user: *server;
	const sock = match (r) {
	case let sock: *ev::file =>
		yield sock;
	case let err: net::error =>
		log::printfln("Error: accept: {}", net::strerror(err));
		ev::stop(server.loop);
		server.exit = 1;
		return;
	};
	const file = ev::getfd(sock);
	const (addr, port) = tcp::peeraddr(file) as (ip::addr, u16);
	log::printfln("Connection from {}:{}", ip::string(addr), port);

	const client = alloc(client {
		server = server,
		sock = sock,
		addr = addr,
		port = port,
		ioreq = ev::ioreq_init(sock),
		...
	})!;
	append(server.clients, client)!;

	ev::req_setuser(&client.ioreq, client);
	ev::read(&client.ioreq, client.buf, &client_read);

	ev::accept(req, &server_accept);
};

fn client_read(
	req: *ev::ioreq,
	r: (size | io::EOF | io::error),
	user: nullable *opaque,
) void = {
	const client = user: *client;
	const n = match (r) {
	case let err: io::error =>
		log::printfln("{}:{}: Error: read: {}",
			ip::string(client.addr), client.port,
			io::strerror(err));
		client_close(client);
		return;
	case io::EOF =>
		client_close(client);
		return;
	case let n: size =>
		yield n;
	};
	ev::write(req, client.buf[..n], &client_write);
};

fn client_write(
	req: *ev::ioreq,
	r: (size | io::error),
	user: nullable *opaque,
) void = {
	const client = user: *client;
	const n = match (r) {
	case let err: io::error =>
		log::printfln("{}:{}: Error: write: {}",
			ip::string(client.addr), client.port,
			io::strerror(err));
		client_close(client);
		return;
	case let n: size =>
		yield n;
	};
	ev::read(req, client.buf, &client_read);
};

fn client_close(client: *client) void = {
	const server = client.server;
	for (let i = 0z; i < len(server.clients); i += 1) {
		if (server.clients[i] == client) {
			delete(server.clients[i]);
			break;
		};
	};
	log::printfln("{}:{}: Connection closed",
		ip::string(client.addr), client.port);
	ev::cancel(&client.ioreq);
	ev::close(client.sock);
	free(client);
};
