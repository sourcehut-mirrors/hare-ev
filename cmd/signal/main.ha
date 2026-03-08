use ev;
use log;
use unix::signal;
use sys;

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	log::printfln("PID: {}", sys::getpid(): int);
	log::println("Send SIGINT (Ctrl+C) or SIGTERM to test");

	const sig = ev::signal_init(
		&loop,
		&loop, // user
		signal::sig::INT, signal::sig::TERM,
	)!;
	defer ev::signal_finish(&sig);
	ev::handle(&sig, &on_signal);

	// Run loop until signal.
	ev::run(&loop)!;

	log::println("Exiting normally");
};

fn on_signal(req: *ev::signal, sig: signal::sig, user: nullable *opaque) void = {
	log::println("Received signal:", signal::signame(sig));

	let loop = user: *ev::loop;
	ev::stop(loop);
};
