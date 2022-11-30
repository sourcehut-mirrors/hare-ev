// Defines events which are available for monitoring.
export type event = enum u32 {
	// Read operations are available
	IN = 0x00000001,
	// Write operations are available
	OUT = 0x00000004,
	// An error condition has been reported
	ERR = 0x00000008,
	// There is exceptional data available in the file descriptor;
	// equivalent to [[unix::poll::event::POLLPRI]]
	PRI = 0x00000002,
	// A hang-up event has occured
	HUP = 0x00000010,
};
// TODO: Add less portable flags like EPOLLWAKEUP
