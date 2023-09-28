use ev;
use fmt;
use net;
use net::dial;
use net::ip;
use net::uri;

// Callback for a [[dial]] operation.
export type dialcb = fn(user: nullable *opaque, r: (*ev::file | error)) void;

// Dials a remote address, establishing a connection and returning the resulting
// [[net::socket]] to the callback. The proto parameter should be the transport
// protocol (e.g. "tcp"), the address parameter should be the remote address,
// and the service should be the name of the service, or the default port to
// use.
//
// See also [[net::dial::dial]].
export fn dial(
	loop: *ev::loop,
	proto: str,
	address: str,
	service: str,
	cb: *dialcb,
	user: nullable *opaque,
) (ev::req | error) = {
	for (let i = 0z; i < len(default_protocols); i += 1) {
		const p = default_protocols[i];
		if (p.name == proto) {
			return p.dial(loop, address, service, cb, user);
		};
	};
	for (let i = 0z; i < len(protocols); i += 1) {
		const p = protocols[i];
		if (p.name == proto) {
			return p.dial(loop, address, service, cb, user);
		};
	};
	return net::unknownproto: net::error;
};

def HOST_MAX: size = 255;

// Performs a [[dial]] operation for a given URI, taking the service name from
// the URI scheme and forming an address from the URI host and port.
//
// See also [[net::dial::uri]].
export fn dial_uri(
	loop: *ev::loop,
	proto: str,
	uri: *uri::uri,
	cb: *dialcb,
	user: nullable *opaque,
) (ev::req | error) = {
	if (uri.host is str && len(uri.host as str) > HOST_MAX) {
		return invalid_address;
	};
	static let addr: [HOST_MAX + len("[]:65535")]u8 = [0...];

	const colon = if (uri.port != 0) ":" else "";
	const port: fmt::formattable = if (uri.port != 0) uri.port else "";

	let addr = match (uri.host) {
	case let host: str =>
		yield fmt::bsprintf(addr, "{}{}{}", host, colon, port);
	case let ip: ip::addr4 =>
		const host = ip::string(ip);
		yield fmt::bsprintf(addr, "{}{}{}", host, colon, port);
	case let ip: ip::addr6 =>
		const host = ip::string(ip);
		yield fmt::bsprintf(addr, "[{}]{}{}", host, colon, port);
	};

	return dial(loop, proto, addr, uri.scheme, cb, user);
};
