use errors;
use ev;
use fmt;
use os;
use os::exec;
use time;

type state = struct {
	child: ev::child,
	timer: ev::timer,
};

export fn main() void = {
	const loop = ev::newloop()!;
	defer ev::finish(&loop);

	const cmd = exec::cmd(os::args[1], os::args[2..]...)!;
	const child = ev::exec(&loop, &cmd)!;
	ev::wait(&child, &child_exited);

	const timer = ev::timer_init(&loop,
		time::clock::MONOTONIC, &expired, &child)!;
	ev::timer_configure(&timer, 5 * time::SECOND, 0)!;
	ev::req_setuser(&child, &timer);

	ev::run(&loop)!;
};

fn expired(timer: *ev::timer, user: nullable *opaque) void = {
	const child = user: *ev::child;
	fmt::println("Child timed out, sending SIGTERM")!;
	ev::kill(child)!;
};

fn child_exited(
	child: *ev::child,
	r: exec::status,
	user: nullable *opaque,
) void = {
	const exit = exec::exit(&r);
	fmt::printfln("child exited: {}", exec::exitstr(exit))!;
	const timer = user: *ev::req;
	ev::cancel(timer);
};
