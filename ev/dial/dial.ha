use ev;
use ev::dns;
use fmt;
use net;
use net::dial;
use net::ip;
use net::uri;

// Dials a remote address, establishing a connection and returning the resulting
// [[net::socket]] to the callback. The proto parameter should be the transport
// protocol (e.g. "tcp"), the address parameter should be the remote address,
// and the service should be the name of the service, or the default port to
// use.
//
// See also [[net::dial::dial]].
export fn dial(
	req: *dialreq,
	proto: str,
	address: str,
	service: str,
	cb: *dialcb,
) (void | error) = {
	for (const p .. default_protocols) {
		if (p.name == proto) {
			p.dial(req, address, service, cb)?;
			return;
		};
	};

	for (const p .. protocols) {
		if (p.name == proto) {
			p.dial(req, address, service, cb)?;
			return;
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
	req: *dialreq,
	proto: str,
	uri: *uri::uri,
	cb: *dialcb,
) (void | error) = {
	if (uri.host is str && len(uri.host as str) > HOST_MAX) {
		return invalid_address;
	};
	static let addr: [HOST_MAX + len("[]:65535")]u8 = [0...];

	const colon = if (uri.port != 0) ":" else "";
	const port: fmt::formattable = if (uri.port != 0) uri.port else "";

	let addr = match (uri.host) {
	case let host: str =>
		yield fmt::bsprintf(addr, "{}{}{}", host, colon, port)!;
	case let ip: ip::addr4 =>
		const host = ip::string(ip);
		yield fmt::bsprintf(addr, "{}{}{}", host, colon, port)!;
	case let ip: ip::addr6 =>
		const host = ip::string(ip);
		yield fmt::bsprintf(addr, "[{}]{}{}", host, colon, port)!;
	};

	return dial(req, proto, addr, uri.scheme, cb);
};
