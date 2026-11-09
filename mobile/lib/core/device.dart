/// A scanner/printer on the local network.
class Device {
  const Device({
    required this.name,
    required this.host,
    required this.esclBase,
    required this.ippUri,
    this.scanner,
  });

  /// Default endpoints for a host entered by hand: http://host/eSCL/ and
  /// ipp://host:631/ipp/print.
  factory Device.fromHost(String host, {String? name}) {
    final h = _bare(host);
    final authority = h.contains(':') ? '[$h]' : h; // IPv6 literal
    return Device(
      name: (name == null || name.trim().isEmpty) ? h : name.trim(),
      host: h,
      esclBase: Uri.parse('http://$authority/eSCL/'),
      ippUri: Uri.parse('ipp://$authority:631/ipp/print'),
    );
  }

  final String name;
  final String host;
  final Uri esclBase;
  final Uri ippUri;

  /// What the network search saw: true = announced a scanner (_uscan), false = printer
  /// only, null = not known (entered by hand). Only a hint for the list: whether the
  /// device really scans is decided by its ScannerCapabilities when it is connected.
  final bool? scanner;

  /// The device's own web page (http://host/).
  Uri get webPage => Uri.parse('http://${host.contains(':') ? '[$host]' : host}/');

  /// IPP over HTTP: the same path on port 631 (or the advertised port).
  Uri get ippHttpUri => ippUri.replace(scheme: 'http', port: ippUri.hasPort ? ippUri.port : 631);

  @override
  bool operator ==(Object other) =>
      other is Device &&
      other.name == name &&
      other.host == host &&
      other.esclBase == esclBase &&
      other.ippUri == ippUri &&
      other.scanner == scanner;

  @override
  int get hashCode => Object.hash(name, host, esclBase, ippUri, scanner);

  @override
  String toString() => 'Device($name, $host)';
}

/// Accepts "192.168.1.5", " printer.local ", "http://192.168.1.5/" or "[fe80::1]".
String _bare(String input) {
  var h = input.trim();
  final scheme = h.indexOf('://');
  if (scheme >= 0) {
    final uri = Uri.tryParse(h);
    if (uri != null && uri.host.isNotEmpty) return uri.host;
    h = h.substring(scheme + 3);
  }
  final slash = h.indexOf('/');
  if (slash >= 0) h = h.substring(0, slash);
  if (h.startsWith('[') && h.contains(']')) return h.substring(1, h.indexOf(']'));
  // "host:port" (a single colon) is not an IPv6 literal; the port is not used.
  if (':'.allMatches(h).length == 1) h = h.substring(0, h.indexOf(':'));
  return h;
}
