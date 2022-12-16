use ev;
use log;
use time;

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const timer = ev::newtimer(&loop, &expired, time::clock::MONOTONIC)!;
	ev::timer_configure(timer, 1 * time::SECOND, 500 * time::MILLISECOND);

	for (ev::dispatch(&loop, -1)!) void;
};

fn expired(timer: *ev::file) void = {
	log::println("timer expired");
};
