import 'dart:io';

import 'package:http/http.dart' as http;

/// True for hosts on the local network: private IPv4 (10/8, 172.16/12, 192.168/16),
/// link-local 169.254/16, IPv6 fc00::/7 and fe80::/10, and names ending in ".local".
///
/// Every request the app makes goes through this check, so a typo or a crafted
/// mDNS answer can never make it talk to the internet.
bool isLocalHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  final zone = h.indexOf('%'); // IPv6 zone id, e.g. fe80::1%wlan0
  if (zone >= 0) h = h.substring(0, zone);
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  if (h.isEmpty) return false;

  final addr = InternetAddress.tryParse(h);
  if (addr == null) {
    // A name: only mDNS names are resolved on the local link by definition.
    return h.endsWith('.local') && h.length > '.local'.length;
  }
  final b = addr.rawAddress;
  if (addr.type == InternetAddressType.IPv4) return _privateV4(b);
  if (b.length != 16) return false;
  // IPv4-mapped IPv6 (::ffff:a.b.c.d)
  final mapped = b.sublist(0, 10).every((v) => v == 0) && b[10] == 0xff && b[11] == 0xff;
  if (mapped) return _privateV4(b.sublist(12));
  if ((b[0] & 0xfe) == 0xfc) return true; // fc00::/7 unique local
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return true; // fe80::/10 link-local
  return false;
}

bool _privateV4(List<int> b) =>
    b[0] == 10 ||
    (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
    (b[0] == 192 && b[1] == 168) ||
    (b[0] == 169 && b[1] == 254);

/// Thrown before any request to a host outside the local network.
class NotLocalNetwork implements Exception {
  const NotLocalNetwork(this.host);

  final String host;

  @override
  String toString() => 'NotLocalNetwork: $host is not on the local network';
}

/// Throws [NotLocalNetwork] unless [uri] points to the local network.
void checkLocal(Uri uri) {
  if (!isLocalHost(uri.host)) throw NotLocalNetwork(uri.host);
}

/// Redirects followed by [sendLocal] before it gives up.
const maxRedirects = 5;

const _redirectAny = {'GET', 'HEAD', 'DELETE'};

/// Sends one request to a device on the local network and follows redirects by hand
/// (the HTTP stack never follows them: `followRedirects` is false on every request).
///
/// GET/HEAD/DELETE follow 301, 302, 303, 307 and 308; other methods (POST) only 307
/// and 308, with the same method and body. Every hop goes through [checkLocal] before
/// it is sent, so a redirect can never lead outside the local network ([NotLocalNetwork]).
/// Any other 3xx is returned as it is. More than [maxRedirects] redirects or a redirect
/// without a usable Location throw `error(message)`.
Future<http.Response> sendLocal(
  http.Client client,
  String method,
  Uri uri, {
  Map<String, String> headers = const {},
  List<int>? body,
  required Exception Function(String message) error,
}) async {
  var url = uri;
  for (var hop = 0;; hop++) {
    checkLocal(url);
    final req = http.Request(method, url)
      ..followRedirects = false
      ..headers.addAll(headers);
    if (body != null) req.bodyBytes = body;
    final r = await http.Response.fromStream(await client.send(req));
    final code = r.statusCode;
    final follow = code == 307 ||
        code == 308 ||
        (_redirectAny.contains(method) && (code == 301 || code == 302 || code == 303));
    if (!follow) return r;
    if (hop >= maxRedirects) throw error('Too many redirects');
    final location = r.headers['location']?.trim() ?? '';
    if (location.isEmpty) throw error('Redirect without a target');
    final Uri next;
    try {
      next = url.resolve(location);
    } on FormatException {
      throw error('Redirect to an invalid address');
    }
    if (next.scheme != 'http' && next.scheme != 'https') {
      throw error('Redirect to an unsupported address');
    }
    url = next;
  }
}
