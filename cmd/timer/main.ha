use ev;
use log;
use time;

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const timer = ev::timer_init(&loop, time::clock::MONOTONIC, &expired)!;
	ev::timer_configure(&timer, 1 * time::SECOND, 500 * time::MILLISECOND);

	for (ev::dispatch(&loop, -1)!) void;
};

fn expired(timer: *ev::timer, user: nullable *opaque) void = {
	log::println("timer expired");
};
