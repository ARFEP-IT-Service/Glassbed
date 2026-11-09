import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import 'device.dart';
import 'lan.dart';

const _services = ['_uscan._tcp.local', '_ipp._tcp.local', '_ipps._tcp.local'];

/// Browse _uscan._tcp, _ipp._tcp and _ipps._tcp for [timeout]; one Device per IPv4 host,
/// sorted by name.
/// The caller holds the Android multicast lock while this runs.
Future<List<Device>> discover({Duration timeout = const Duration(seconds: 4)}) async {
  final found = <String, DiscoveredEntry>{};
  for (final s in await browseServices(_services, timeout: timeout)) {
    addService(found,
        serviceType: s.type, instance: s.instance, host: s.host, port: s.port, txt: s.txt);
  }
  return devicesFrom(found);
}

/// One resolved mDNS service instance (IPv4 only).
class MdnsService {
  const MdnsService({
    required this.type,
    required this.instance,
    required this.host,
    required this.port,
    required this.txt,
  });

  /// e.g. "_ipp._tcp.local"
  final String type;
  final String instance;
  final String host;
  final int port;

  /// TXT record, keys lower case.
  final Map<String, String> txt;
}

/// Browses [services] (e.g. "_ipp._tcp.local") for [timeout] and resolves every instance.
/// Empty if the mDNS socket cannot be opened.
/// The caller holds the Android multicast lock while this runs.
Future<List<MdnsService>> browseServices(List<String> services,
    {Duration timeout = const Duration(seconds: 4)}) async {
  // Android does not allow SO_REUSEPORT on the mDNS socket.
  final client = MDnsClient(
    rawDatagramSocketFactory: (dynamic host, int port,
            {bool reuseAddress = true, bool reusePort = false, int ttl = 255}) =>
        RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: false, ttl: ttl),
  );
  final found = <MdnsService>[];
  try {
    await client.start(listenAddress: InternetAddress.anyIPv4);
    await Future.wait([
      for (final service in services) _browse(client, service, timeout, found),
    ]).timeout(timeout + const Duration(seconds: 1), onTimeout: () => const []);
  } on SocketException {
    return const [];
  } finally {
    client.stop();
  }
  return List.of(found);
}

/// What was learned about one host while browsing.
class DiscoveredEntry {
  DiscoveredEntry(this.name);

  String name;
  bool nameFromScanner = false;
  Uri? escl;
  Uri? ipp; // from _ipp; from _ipps only until a plain _ipp answer arrives
}

/// Parses an mDNS TXT record ("key=value" lines) into a map (keys lower case).
Map<String, String> parseTxt(String text) {
  final out = <String, String>{};
  for (final line in text.split('\n')) {
    final eq = line.indexOf('=');
    if (eq <= 0) continue;
    out[line.substring(0, eq).trim().toLowerCase()] = line.substring(eq + 1).trim();
  }
  return out;
}

/// Adds one resolved service to [found] (pure, unit-testable).
void addService(
  Map<String, DiscoveredEntry> found, {
  required String serviceType,
  required String instance,
  required String host,
  required int port,
  required Map<String, String> txt,
}) {
  if (!isLocalHost(host)) return;
  final entry = found.putIfAbsent(host, () => DiscoveredEntry(instance));
  final model = txt['ty'] ?? '';
  if (serviceType.startsWith('_uscan')) {
    final rs = _trimSlashes(txt['rs'] ?? 'eSCL');
    entry.escl = Uri(scheme: 'http', host: host, port: port, path: rs.isEmpty ? '/' : '/$rs/');
    if (model.isNotEmpty) {
      entry
        ..name = model
        ..nameFromScanner = true;
    }
  } else if (serviceType.startsWith('_ipps')) {
    // IPP over TLS. The app talks plain IPP, which these printers also accept on port 631.
    if (entry.ipp == null) {
      final rp = _trimSlashes(txt['rp'] ?? 'ipp/print');
      entry.ipp = Uri(scheme: 'ipp', host: host, port: 631, path: '/$rp');
    }
    if (model.isNotEmpty && !entry.nameFromScanner) entry.name = model;
  } else {
    final rp = _trimSlashes(txt['rp'] ?? 'ipp/print');
    entry.ipp = Uri(scheme: 'ipp', host: host, port: port, path: '/$rp');
    if (model.isNotEmpty && !entry.nameFromScanner) entry.name = model;
  }
}

List<Device> devicesFrom(Map<String, DiscoveredEntry> found) {
  final devices = [
    for (final MapEntry(key: host, value: e) in found.entries)
      () {
        final d = Device.fromHost(host, name: e.name);
        return Device(
          name: d.name,
          host: d.host,
          esclBase: e.escl ?? d.esclBase,
          ippUri: e.ipp ?? d.ippUri,
          scanner: e.escl != null,
        );
      }(),
  ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return devices;
}

String _trimSlashes(String s) {
  var v = s.trim();
  while (v.startsWith('/')) {
    v = v.substring(1);
  }
  while (v.endsWith('/')) {
    v = v.substring(0, v.length - 1);
  }
  return v;
}

Future<void> _browse(
  MDnsClient client,
  String service,
  Duration timeout,
  List<MdnsService> found,
) async {
  final pending = <Future<void>>[];
  await for (final ptr in client.lookup<PtrResourceRecord>(
    ResourceRecordQuery.serverPointer(service),
    timeout: timeout,
  )) {
    pending.add(_resolve(client, service, ptr.domainName, found).catchError((_) {}));
  }
  await Future.wait(pending);
}

Future<void> _resolve(
  MDnsClient client,
  String service,
  String instanceName,
  List<MdnsService> found,
) async {
  const t = Duration(seconds: 2);
  final srv = await client
      .lookup<SrvResourceRecord>(ResourceRecordQuery.service(instanceName), timeout: t)
      .firstOrNullWithin(t);
  if (srv == null) return;
  final txt = await client
      .lookup<TxtResourceRecord>(ResourceRecordQuery.text(instanceName), timeout: t)
      .firstOrNullWithin(t);
  final addr = await client
      .lookup<IPAddressResourceRecord>(ResourceRecordQuery.addressIPv4(srv.target), timeout: t)
      .firstOrNullWithin(t);
  if (addr == null || addr.address.type != InternetAddressType.IPv4) return;
  final dot = instanceName.indexOf('._');
  found.add(MdnsService(
    type: service,
    instance: dot > 0 ? instanceName.substring(0, dot) : instanceName,
    host: addr.address.address,
    port: srv.port,
    txt: parseTxt(txt?.text ?? ''),
  ));
}

extension<T> on Stream<T> {
  Future<T?> firstOrNullWithin(Duration t) async {
    try {
      return await first.timeout(t);
    } on StateError {
      return null; // stream ended without a record
    } on TimeoutException {
      return null;
    }
  }
}
