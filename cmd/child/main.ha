use errors;
use ev;
use fmt;
use os;
use os::exec;
use time;

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const cmd = exec::cmd(os::args[1], os::args[2..]...)!;
	const child = ev::exec(&loop, &cmd)!;
	ev::wait(child, &child_exited);

	const timer = ev::newtimer(&loop, &expired, time::clock::MONOTONIC)!;
	ev::timer_configure(timer, 5 * time::SECOND, 0);
	ev::setuser(timer, child);

	for (ev::dispatch(&loop, -1)!) void;
};

fn expired(timer: *ev::file) void = {
	fmt::println("Child timed out, sending SIGTERM")!;
	const child = ev::getuser(timer): *ev::file;
	ev::kill(child)!;
};

fn child_exited(child: *ev::file, r: exec::status) void = {
	const exit = exec::exit(&r);
	fmt::printfln("child exited: {}", exec::exitstr(exit))!;

	const loop = ev::getloop(child);
	ev::stop(loop);
};
