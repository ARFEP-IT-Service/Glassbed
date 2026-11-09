import 'dart:async';
import 'dart:io';

import 'package:multicast_dns/multicast_dns.dart';

import 'device.dart';
import 'lan.dart';

const _services = ['_uscan._tcp.local', '_ipp._tcp.local'];

/// Browse _uscan._tcp and _ipp._tcp for [timeout]; one Device per IPv4 host, sorted by name.
/// The caller holds the Android multicast lock while this runs.
Future<List<Device>> discover({Duration timeout = const Duration(seconds: 4)}) async {
  // Android does not allow SO_REUSEPORT on the mDNS socket.
  final client = MDnsClient(
    rawDatagramSocketFactory: (dynamic host, int port,
            {bool reuseAddress = true, bool reusePort = false, int ttl = 255}) =>
        RawDatagramSocket.bind(host, port, reuseAddress: true, reusePort: false, ttl: ttl),
  );
  final found = <String, DiscoveredEntry>{};
  try {
    await client.start(listenAddress: InternetAddress.anyIPv4);
    await Future.wait([
      for (final service in _services) _browse(client, service, timeout, found),
    ]).timeout(timeout + const Duration(seconds: 1), onTimeout: () => const []);
  } on SocketException {
    return const [];
  } finally {
    client.stop();
  }
  return devicesFrom(found);
}

/// What was learned about one host while browsing.
class DiscoveredEntry {
  DiscoveredEntry(this.name);

  String name;
  bool nameFromScanner = false;
  Uri? escl;
  Uri? ipp;
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
  Map<String, DiscoveredEntry> found,
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
  Map<String, DiscoveredEntry> found,
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
  addService(
    found,
    serviceType: service,
    instance: dot > 0 ? instanceName.substring(0, dot) : instanceName,
    host: addr.address.address,
    port: srv.port,
    txt: parseTxt(txt?.text ?? ''),
  );
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
