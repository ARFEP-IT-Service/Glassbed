import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:xml/xml.dart';

import 'discovery.dart';
import 'escl.dart';
import 'ipp.dart';
import 'lan.dart';

// "Check device": what a device on the local network offers (open ports, mDNS services,
// IPP, eSCL, WS-Discovery), as a plain text report the user can send to the developer.
// The report is English and has the same lines as the Windows app's.

/// TCP ports that are tried: HTTP, HTTPS, LPR, IPP, Epson Scan, RAW.
const checkPorts = [80, 443, 515, 631, 1865, 9100];

/// mDNS service types whose answers from the host are listed.
const checkServices = [
  '_ipp._tcp.local',
  '_ipps._tcp.local',
  '_uscan._tcp.local',
  '_uscans._tcp.local',
  '_printer._tcp.local',
  '_pdl-datastream._tcp.local',
  '_scanner._tcp.local',
];

/// TXT keys shown in the mDNS lines (in this order) and how they are written.
const _txtKeys = {'ty': 'ty', 'rp': 'rp', 'rs': 'rs', 'pdl': 'pdl', 'urf': 'URF'};

const _wsdGroup = '239.255.255.250';
const _wsdPort = 3702;

/// IPP answer: [caps] when one of the tried paths worked, else [error].
class IppCheck {
  const IppCheck({this.uri, this.caps, this.error});

  final Uri? uri;
  final PrinterCaps? caps;
  final String? error;

  bool get ok => caps != null;
}

/// eSCL answer: [caps] with at least one source when it worked, else [error].
class EsclCheck {
  const EsclCheck({this.url, this.caps, this.error});

  /// The ScannerCapabilities URL that answered.
  final String? url;
  final ScannerCaps? caps;
  final String? error;

  bool get ok => caps != null;
}

/// One WS-Discovery ProbeMatch: the Types and XAddrs texts.
class WsdMatch {
  const WsdMatch({required this.types, required this.xaddrs});

  final String types;
  final String xaddrs;

  /// A WSD scanner (WS-Scan) – not supported by Glassbed.
  bool get scanner => types.contains('ScanDeviceType') || types.contains('ScannerServiceType');
}

/// Everything the check found out; turned into text by [buildReport].
class DeviceCheckResult {
  const DeviceCheckResult({
    required this.appVersion,
    required this.flavor,
    required this.time,
    required this.host,
    required this.ports,
    required this.mdns,
    required this.ipp,
    required this.escl,
    this.wsd,
  });

  final String appVersion;
  final String flavor;
  final DateTime time;
  final String host;

  /// Port -> "open", "closed", "timeout" or "unreachable"; empty if the host was not resolved.
  final Map<int, String> ports;

  /// The host's services only.
  final List<MdnsService> mdns;
  final IppCheck ipp;
  final EsclCheck escl;
  final WsdMatch? wsd;
}

/// The report text (pure).
String buildReport(DeviceCheckResult r) {
  final lines = <String>[
    'Glassbed device check',
    'App: Glassbed for Android ${r.appVersion} (${r.flavor})',
    'Time: ${_utcSeconds(r.time)}',
    'Host: ${r.host}',
    r.ports.isEmpty
        ? 'Ports: host name not resolved'
        : 'Ports: ${[for (final p in checkPorts) '$p ${r.ports[p] ?? 'unknown'}'].join(', ')}',
  ];
  final services = sortedServices(r.mdns);
  if (services.isEmpty) {
    lines.add('mDNS: no services from this host');
  } else {
    for (final s in services) {
      final txt = [
        for (final MapEntry(key: k, value: label) in _txtKeys.entries)
          if (s.txt[k] != null) '$label="${s.txt[k]!.replaceAll('"', r'\"')}"',
      ];
      lines.add(['mDNS: ${_shortType(s.type)} port ${s.port}', ...txt].join(' '));
    }
  }

  final ipp = r.ipp;
  if (ipp.ok) {
    final c = ipp.caps!;
    lines.add('IPP: ok ${ipp.uri == null ? '' : _url(ipp.uri!)} '
        'make-and-model="${c.makeAndModel}" '
        'formats=${_list(c.documentFormats)} urf=${_list(c.urfSupported)} state=${c.state}');
  } else {
    lines.add('IPP: ${ipp.error ?? 'no answer'}');
  }

  final escl = r.escl;
  if (escl.ok) {
    final c = escl.caps!;
    final sources = [
      for (final s in c.sources) s == ScanSource.platen ? 'Platen' : 'Feeder',
    ];
    lines.add('eSCL: ok ${escl.url ?? ''} version=${c.version} sources=${_list(sources)}');
  } else {
    lines.add('eSCL: ${escl.error ?? 'no answer'}');
  }

  final wsd = r.wsd;
  lines.add(wsd == null ? 'WSD: no answer' : 'WSD: ok types=${wsd.types} xaddrs=${wsd.xaddrs}');
  lines.add('Verdict: print=${ipp.ok ? 'IPP' : 'none'}, scan=${scanVerdict(r)}');
  return '${lines.join('\n')}\n';
}

/// "eSCL", "WSD (not supported by Glassbed yet)" or "none".
String scanVerdict(DeviceCheckResult r) {
  if (r.escl.ok) return 'eSCL';
  if (r.wsd?.scanner ?? false) return 'WSD (not supported by Glassbed yet)';
  return 'none';
}

/// Services in the order of [checkServices], then by port.
List<MdnsService> sortedServices(List<MdnsService> services) {
  int rank(MdnsService s) {
    final i = checkServices.indexOf(s.type);
    return i < 0 ? checkServices.length : i;
  }

  return List.of(services)
    ..sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      return c != 0 ? c : a.port.compareTo(b.port);
    });
}

String _shortType(String type) =>
    type.endsWith('.local') ? type.substring(0, type.length - '.local'.length) : type;

String _list(List<String> v) => v.isEmpty ? 'none' : v.join(',');

/// "2026-11-09T12:34:56Z"
String _utcSeconds(DateTime t) => '${t.toUtc().toIso8601String().substring(0, 19)}Z';

/// The URL with its port always written out (Uri drops 80 for http).
String _url(Uri u) {
  final host = u.host.contains(':') ? '[${u.host}]' : u.host;
  return '${u.scheme}://$host:${u.port}${u.path}';
}

/// A short reason for a failed request: "timeout", "connection refused", "HTTP 404", ...
String shortError(Object e) {
  if (e is TimeoutException) return 'timeout';
  if (e is NotLocalNetwork) return 'not a local address';
  if (e is IppError && e.status != null) return ippStatusName(e.status!);
  final text = e.toString();
  final http = RegExp(r'HTTP (\d{3})').firstMatch(text);
  if (http != null) return 'HTTP ${http.group(1)}';
  final lower = text.toLowerCase();
  if (lower.contains('did not answer in time') || lower.contains('timed out')) return 'timeout';
  if (lower.contains('refused')) return 'connection refused';
  if (lower.contains('unreachable') || lower.contains('no route')) return 'host unreachable';
  if (lower.contains('failed host lookup')) return 'host name not resolved';
  var s = text.replaceFirst(RegExp(r'^\w+(Error|Exception): '), '');
  s = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.length > 120 ? '${s.substring(0, 120)}…' : s;
}

// -- WS-Discovery ------------------------------------------------------------

/// A WS-Discovery Probe without Types, so every device answers.
String wsdProbeMessage(String messageId) => '<?xml version="1.0" encoding="utf-8"?>'
    '<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope" '
    'xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing" '
    'xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery">'
    '<soap:Header>'
    '<wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>'
    '<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>'
    '<wsa:MessageID>$messageId</wsa:MessageID>'
    '</soap:Header>'
    '<soap:Body><wsd:Probe/></soap:Body>'
    '</soap:Envelope>';

/// "urn:uuid:..." with a random (version 4) UUID.
String randomMessageId([Random? random]) {
  final r = random ?? Random.secure();
  final b = [for (var i = 0; i < 16; i++) r.nextInt(256)];
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((v) => v.toRadixString(16).padLeft(2, '0')).join();
  return 'urn:uuid:${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}

/// The ProbeMatch entries of a ProbeMatches envelope (element names without namespace);
/// empty for anything else.
List<WsdMatch> parseProbeMatches(String xml) {
  final XmlDocument doc;
  try {
    doc = XmlDocument.parse(xml);
  } on XmlException {
    return const [];
  }
  String text(XmlElement m, String local) => m.descendants
      .whereType<XmlElement>()
      .where((e) => e.name.local == local)
      .map((e) => e.innerText.replaceAll(RegExp(r'\s+'), ' ').trim())
      .where((t) => t.isNotEmpty)
      .join(' ');
  return [
    for (final m in doc.descendants
        .whereType<XmlElement>()
        .where((e) => e.name.local == 'ProbeMatch'))
      WsdMatch(types: text(m, 'Types'), xaddrs: text(m, 'XAddrs')),
  ];
}

/// One match from several (unicast and multicast answers, one per hosted service):
/// every Types and XAddrs entry once, in the order seen. Null if [matches] is empty.
WsdMatch? mergeMatches(List<WsdMatch> matches) {
  if (matches.isEmpty) return null;
  List<String> words(Iterable<String> v) =>
      {for (final s in v) ...s.split(' ').where((w) => w.isNotEmpty)}.toList();
  return WsdMatch(
    types: words(matches.map((m) => m.types)).join(' '),
    xaddrs: words(matches.map((m) => m.xaddrs)).join(' '),
  );
}

/// Sends a WS-Discovery Probe to [target]:3702 and to the WSD multicast group (link-local,
/// one hop) and collects the ProbeMatches that [target] sends back within [wait].
/// Only an IPv4 address on the local network is probed; nothing else is fetched.
Future<List<WsdMatch>> wsDiscoveryProbe(InternetAddress target,
    {Duration wait = const Duration(seconds: 3)}) async {
  if (target.type != InternetAddressType.IPv4 || !isLocalHost(target.address)) return const [];
  final RawDatagramSocket socket;
  try {
    socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  } on SocketException {
    return const [];
  }
  final found = <WsdMatch>[];
  final sub = socket.listen((event) {
    if (event != RawSocketEvent.read) return;
    final d = socket.receive();
    if (d == null || d.address.address != target.address) return;
    found.addAll(parseProbeMatches(utf8.decode(d.data, allowMalformed: true)));
  }, onError: (Object _) {});
  try {
    try {
      socket.multicastHops = 1;
    } on SocketException {
      // keeps the system default
    }
    final message = utf8.encode(wsdProbeMessage(randomMessageId()));
    final group = InternetAddress(_wsdGroup);
    // UDP may drop a datagram: send twice, as SOAP-over-UDP suggests.
    for (var i = 0; i < 2; i++) {
      try {
        socket.send(message, target, _wsdPort);
        socket.send(message, group, _wsdPort);
      } on SocketException {
        // no route for one of them: the other may still work
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await Future<void>.delayed(wait - const Duration(milliseconds: 400));
  } finally {
    await sub.cancel();
    socket.close();
  }
  return found;
}

// -- network -----------------------------------------------------------------

/// "open", "closed" (refused), "timeout" or "unreachable" for a TCP connect to [address]:[port].
Future<String> tcpPortState(InternetAddress address, int port,
    {Duration timeout = const Duration(seconds: 2)}) async {
  if (!isLocalHost(address.address)) return 'unreachable';
  try {
    final s = await Socket.connect(address, port, timeout: timeout)
        .timeout(timeout + const Duration(seconds: 1));
    s.destroy();
    return 'open';
  } on TimeoutException {
    return 'timeout';
  } on SocketException catch (e) {
    final code = e.osError?.errorCode;
    final text = '${e.message} ${e.osError?.message ?? ''}'.toLowerCase();
    if (code == 111 || code == 61 || code == 10061 || text.contains('refused')) return 'closed';
    if (text.contains('timed out') || code == 110 || code == 10060) return 'timeout';
    return 'unreachable';
  }
}

/// The host as a local address (names are looked up); null if not resolved or not local.
Future<InternetAddress?> resolveLocal(String host) async {
  final literal = InternetAddress.tryParse(host);
  if (literal != null) return isLocalHost(literal.address) ? literal : null;
  if (!isLocalHost(host)) return null;
  try {
    final all = await InternetAddress.lookup(host).timeout(const Duration(seconds: 3));
    return all.where((a) => isLocalHost(a.address)).firstOrNull;
  } catch (_) {
    return null;
  }
}

Future<PrinterCaps> _printerCaps(Uri ippUri) =>
    getPrinterCaps(ippUri, timeout: const Duration(seconds: 4));

Future<ScannerCaps> _scannerCaps(Uri esclBase) async {
  final client = EsclClient(esclBase, timeout: const Duration(seconds: 4));
  try {
    return await client.capabilities();
  } finally {
    client.close();
  }
}

/// The network parts of the check (replaced in tests).
class DeviceCheckNet {
  const DeviceCheckNet({
    this.resolve = resolveLocal,
    this.port = tcpPortState,
    this.browse = browseServices,
    this.printerCaps = _printerCaps,
    this.scannerCaps = _scannerCaps,
    this.wsd = wsDiscoveryProbe,
  });

  final Future<InternetAddress?> Function(String host) resolve;
  final Future<String> Function(InternetAddress address, int port) port;
  final Future<List<MdnsService>> Function(List<String> services, {Duration timeout}) browse;
  final Future<PrinterCaps> Function(Uri ippUri) printerCaps;
  final Future<ScannerCaps> Function(Uri esclBase) scannerCaps;
  final Future<List<WsdMatch>> Function(InternetAddress target, {Duration wait}) wsd;
}

/// Runs the whole check for [host] (about 4 s for ports, mDNS and WSD at the same time, then
/// at most 8 s each for IPP and eSCL, also at the same time). Never throws; a part that fails
/// shows up as an error line. The caller holds the Android multicast lock while this runs.
Future<DeviceCheckResult> checkDevice(
  String host, {
  required String appVersion,
  required String flavor,
  DeviceCheckNet net = const DeviceCheckNet(),
  DateTime Function() now = DateTime.now,
}) async {
  final time = now();
  final address = await _guard(net.resolve(host), const Duration(seconds: 4), null);

  final portsFuture = address == null
      ? Future.value(<int, String>{})
      : Future.wait([
          for (final p in checkPorts) _guard(net.port(address, p), const Duration(seconds: 4), 'timeout'),
        ]).then((s) => {for (var i = 0; i < checkPorts.length; i++) checkPorts[i]: s[i]});
  final mdnsFuture = _guard(
      net.browse(checkServices, timeout: const Duration(seconds: 4)),
      const Duration(seconds: 6),
      const <MdnsService>[]);
  final wsdFuture = address == null
      ? Future.value(const <WsdMatch>[])
      : _guard(net.wsd(address, wait: const Duration(seconds: 3)), const Duration(seconds: 5),
          const <WsdMatch>[]);

  final ports = await portsFuture;
  final mdns = [
    for (final s in await mdnsFuture)
      if (s.host == host || s.host == address?.address) s,
  ];
  final wsd = mergeMatches(await wsdFuture);

  String? txt(String type, String key) =>
      mdns.where((s) => s.type == type && s.txt[key] != null).firstOrNull?.txt[key];
  final rp = txt('_ipp._tcp.local', 'rp') ?? txt('_ipps._tcp.local', 'rp');
  final uscan = mdns.where((s) => s.type == '_uscan._tcp.local').firstOrNull;

  final ippFuture = _guard(_checkIpp(host, rp, ports[631], net), const Duration(seconds: 9),
      const IppCheck(error: 'timeout'));
  final esclFuture = _guard(_checkEscl(host, uscan, ports[80], net), const Duration(seconds: 9),
      const EsclCheck(error: 'timeout'));
  return DeviceCheckResult(
    appVersion: appVersion,
    flavor: flavor,
    time: time,
    host: host,
    ports: ports,
    mdns: mdns,
    ipp: await ippFuture,
    escl: await esclFuture,
    wsd: wsd,
  );
}

/// [f] or [fallback] on error or after [limit].
Future<T> _guard<T>(Future<T> f, Duration limit, T fallback) async {
  try {
    return await f.timeout(limit);
  } catch (_) {
    return fallback;
  }
}

List<String> _paths(String? first, List<String> rest) {
  final out = <String>[];
  for (final p in [?first, ...rest]) {
    var v = p.trim();
    while (v.startsWith('/')) {
      v = v.substring(1);
    }
    while (v.endsWith('/')) {
      v = v.substring(0, v.length - 1);
    }
    final path = '/$v';
    if (!out.contains(path)) out.add(path);
  }
  return out;
}

/// Get-Printer-Attributes on port 631: the mDNS rp path, then the usual ones.
Future<IppCheck> _checkIpp(String host, String? rp, String? port631, DeviceCheckNet net) async {
  if (port631 == 'closed') return const IppCheck(error: 'connection refused');
  if (port631 == 'timeout') return const IppCheck(error: 'timeout');
  var error = 'no answer';
  for (final path in _paths(rp, const ['ipp/print', 'ipp/printer', 'ipp'])) {
    final uri = Uri(scheme: 'ipp', host: host, port: 631, path: path);
    try {
      final caps = await net.printerCaps(uri).timeout(const Duration(seconds: 5));
      return IppCheck(uri: uri, caps: caps);
    } catch (e) {
      error = shortError(e);
      if (error == 'timeout' || error == 'connection refused') break; // the others won't answer either
    }
  }
  return IppCheck(error: error);
}

/// ScannerCapabilities: the mDNS rs path (on the announced port), then /eSCL on port 80.
Future<EsclCheck> _checkEscl(
    String host, MdnsService? uscan, String? port80, DeviceCheckNet net) async {
  final tries = <(int, String)>[
    if (uscan != null) (uscan.port, _paths(uscan.txt['rs'] ?? 'eSCL', const []).first),
    (80, '/eSCL'),
  ];
  var error = 'no answer';
  final seen = <String>{};
  for (final (port, path) in tries) {
    if (!seen.add('$port$path')) continue;
    if (port == 80 && port80 == 'closed') {
      error = 'connection refused';
      continue;
    }
    if (port == 80 && port80 == 'timeout') {
      error = 'timeout';
      continue;
    }
    final base = Uri(scheme: 'http', host: host, port: port, path: path == '/' ? '/' : '$path/');
    try {
      final caps = await net.scannerCaps(base).timeout(const Duration(seconds: 5));
      if (caps.sources.isEmpty) {
        error = 'no scan source in ScannerCapabilities';
        continue;
      }
      return EsclCheck(url: _url(base.resolve('ScannerCapabilities')), caps: caps);
    } catch (e) {
      error = shortError(e);
    }
  }
  return EsclCheck(error: error);
}

/// Runs [checkDevice] and returns the report text.
Future<String> deviceReport(
  String host, {
  required String appVersion,
  required String flavor,
  DeviceCheckNet net = const DeviceCheckNet(),
}) async =>
    buildReport(await checkDevice(host, appVersion: appVersion, flavor: flavor, net: net));
