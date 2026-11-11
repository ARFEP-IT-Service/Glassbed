import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/device_check.dart';
import 'package:glassbed/core/discovery.dart';
import 'package:glassbed/core/escl.dart';
import 'package:glassbed/core/ipp.dart';
import 'package:glassbed/ui/home/device_check_screen.dart';
import 'package:glassbed/ui/home/printer_card.dart';
import 'package:glassbed/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const hp = '192.168.178.50';
const epson = '192.168.178.60';

const _source = SourceCaps(resolutions: [300], colorModes: ['RGB24'], maxWidth: 2550, maxHeight: 3507);

/// ProbeMatches as an Epson ET-2710 sends them (WS-Scan only, no IPP/eSCL).
const epsonProbeMatches = '''<?xml version="1.0" encoding="utf-8"?>
<soap:Envelope xmlns:soap="http://www.w3.org/2003/05/soap-envelope"
    xmlns:wsa="http://schemas.xmlsoap.org/ws/2004/08/addressing"
    xmlns:wsd="http://schemas.xmlsoap.org/ws/2005/04/discovery"
    xmlns:wsdp="http://schemas.xmlsoap.org/ws/2006/02/devprof"
    xmlns:wscn="http://schemas.microsoft.com/windows/2006/08/wdp/scan">
  <soap:Header>
    <wsa:To>http://schemas.xmlsoap.org/ws/2004/08/addressing/role/anonymous</wsa:To>
    <wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/ProbeMatches</wsa:Action>
    <wsa:MessageID>urn:uuid:5f0b2c1e-0000-4000-8000-000000000001</wsa:MessageID>
    <wsa:RelatesTo>urn:uuid:1b4e28ba-2fa1-41d2-883f-0016d3cca427</wsa:RelatesTo>
  </soap:Header>
  <soap:Body>
    <wsd:ProbeMatches>
      <wsd:ProbeMatch>
        <wsa:EndpointReference><wsa:Address>urn:uuid:cfe92100-67c4-11d4-a45f-e0bb9ec1a2b3</wsa:Address></wsa:EndpointReference>
        <wsd:Types>wsdp:Device
          wscn:ScanDeviceType</wsd:Types>
        <wsd:XAddrs>http://192.168.178.60:80/WSD/DEVICE</wsd:XAddrs>
        <wsd:MetadataVersion>1</wsd:MetadataVersion>
      </wsd:ProbeMatch>
    </wsd:ProbeMatches>
  </soap:Body>
</soap:Envelope>''';

/// A fake network: [ports] by number, [services] from mDNS, IPP/eSCL answers by URI.
DeviceCheckNet fakeNet({
  required Map<int, String> ports,
  List<MdnsService> services = const [],
  Map<String, PrinterCaps> ipp = const {},
  Object ippError = const IppError('Cannot reach the printer: Connection refused'),
  Map<String, ScannerCaps> escl = const {},
  Object esclError = const ScannerError('ScannerCapabilities failed (HTTP 404)'),
  List<WsdMatch> wsd = const [],
  List<String>? asked,
}) =>
    DeviceCheckNet(
      resolve: (host) async => InternetAddress(host),
      port: (address, port) async => ports[port] ?? 'timeout',
      browse: (types, {Duration timeout = Duration.zero}) async => services,
      printerCaps: (uri) async {
        asked?.add(uri.toString());
        return ipp[uri.toString()] ?? (throw ippError);
      },
      scannerCaps: (base) async {
        asked?.add(base.toString());
        return escl[base.toString()] ?? (throw esclError);
      },
      wsd: (target, {Duration wait = Duration.zero}) async => wsd,
    );

final time = DateTime.utc(2026, 11, 9, 10, 30, 15, 123);

void main() {
  test('HP: IPP and eSCL work, WSD answers', () async {
    final asked = <String>[];
    final net = fakeNet(
      ports: {80: 'open', 443: 'open', 515: 'closed', 631: 'open', 1865: 'closed', 9100: 'open'},
      services: [
        const MdnsService(
            type: '_uscan._tcp.local',
            instance: 'HP',
            host: hp,
            port: 80,
            txt: {'ty': 'HP Color LaserJet MFP M182n', 'rs': 'eSCL', 'vers': '2.63'}),
        const MdnsService(
            type: '_ipp._tcp.local',
            instance: 'HP',
            host: hp,
            port: 631,
            txt: {
              'ty': 'HP Color LaserJet MFP M182n',
              'rp': 'ipp/print',
              'pdl': 'application/pdf,image/urf',
              'urf': 'V1.4,W8,SRGB24,RS600'
            }),
        // another printer in the network: not in the report
        const MdnsService(
            type: '_ipp._tcp.local', instance: 'Other', host: '192.168.178.99', port: 631, txt: {}),
      ],
      ipp: {
        'ipp://$hp:631/ipp/print': const PrinterCaps(
          state: 'idle',
          stateReasons: [],
          makeAndModel: 'HP Color LaserJet MFP M182n',
          documentFormats: ['application/pdf', 'image/urf', 'image/jpeg'],
          urfSupported: ['V1.4', 'W8', 'SRGB24', 'RS600'],
        ),
      },
      escl: {
        'http://$hp/eSCL/': const ScannerCaps(version: '2.63', platen: _source, adf: _source),
      },
      wsd: const [
        WsdMatch(types: 'wsdp:Device wprt:PrintDeviceType', xaddrs: 'http://$hp:3911/'),
        WsdMatch(types: 'wsdp:Device wscn:ScanDeviceType', xaddrs: 'http://$hp:3911/'),
      ],
      asked: asked,
    );
    final r = await checkDevice(hp, appVersion: '0.2.0', flavor: 'github', net: net, now: () => time);
    expect(buildReport(r), '''Glassbed device check
App: Glassbed for Android 0.2.0 (github)
Time: 2026-11-09T10:30:15Z
Host: $hp
Ports: 80 open, 443 open, 515 closed, 631 open, 1865 closed, 9100 open
mDNS: _ipp._tcp port 631 ty="HP Color LaserJet MFP M182n" rp="ipp/print" pdl="application/pdf,image/urf" URF="V1.4,W8,SRGB24,RS600"
mDNS: _uscan._tcp port 80 ty="HP Color LaserJet MFP M182n" rs="eSCL"
IPP: ok ipp://$hp:631/ipp/print make-and-model="HP Color LaserJet MFP M182n" formats=application/pdf,image/urf,image/jpeg urf=V1.4,W8,SRGB24,RS600 state=idle
eSCL: ok http://$hp:80/eSCL/ScannerCapabilities version=2.63 sources=Platen,Feeder
WSD: ok types=wsdp:Device wprt:PrintDeviceType wscn:ScanDeviceType xaddrs=http://$hp:3911/
Verdict: print=IPP, scan=eSCL
''');
    // the mDNS paths first, and nothing after the first that works
    expect(asked, ['ipp://$hp:631/ipp/print', 'http://$hp/eSCL/']);
  });

  test('Epson ET-2710: no IPP (631 closed), eSCL 404, WSD scanner, RAW and LPR open', () async {
    final asked = <String>[];
    final net = fakeNet(
      ports: {80: 'open', 443: 'open', 515: 'open', 631: 'closed', 1865: 'open', 9100: 'open'},
      services: [
        const MdnsService(
            type: '_pdl-datastream._tcp.local',
            instance: 'EPSON ET-2710 Series',
            host: epson,
            port: 9100,
            txt: {'ty': 'EPSON ET-2710 Series'}),
        const MdnsService(
            type: '_printer._tcp.local',
            instance: 'EPSON ET-2710 Series',
            host: epson,
            port: 515,
            txt: {'ty': 'EPSON ET-2710 Series', 'rp': 'auto'}),
      ],
      wsd: parseProbeMatches(epsonProbeMatches),
      asked: asked,
    );
    final r = await checkDevice(epson, appVersion: '0.2.0', flavor: 'play', net: net, now: () => time);
    final report = buildReport(r);
    expect(report.split('\n'), [
      'Glassbed device check',
      'App: Glassbed for Android 0.2.0 (play)',
      'Time: 2026-11-09T10:30:15Z',
      'Host: $epson',
      'Ports: 80 open, 443 open, 515 open, 631 closed, 1865 open, 9100 open',
      'mDNS: _printer._tcp port 515 ty="EPSON ET-2710 Series" rp="auto"',
      'mDNS: _pdl-datastream._tcp port 9100 ty="EPSON ET-2710 Series"',
      'IPP: connection refused',
      'eSCL: HTTP 404',
      'WSD: ok types=wsdp:Device wscn:ScanDeviceType xaddrs=http://$epson:80/WSD/DEVICE',
      'Verdict: print=none, scan=WSD (not supported by Glassbed yet)',
      '',
    ]);
    // 631 refused the connection: no IPP request at all
    expect(asked, ['http://$epson/eSCL/']);
  });

  test('IPP: tries the mDNS rp, then the usual paths, and reports the last error', () async {
    final asked = <String>[];
    final net = fakeNet(
      ports: {631: 'open', 80: 'closed'},
      services: [
        const MdnsService(
            type: '_ipps._tcp.local', instance: 'X', host: hp, port: 631, txt: {'rp': '/ipp/lp'}),
      ],
      ippError: const IppError('Printer answered HTTP 404'),
      asked: asked,
    );
    final r = await checkDevice(hp, appVersion: '1', flavor: 'play', net: net, now: () => time);
    expect(asked, [
      'ipp://$hp:631/ipp/lp',
      'ipp://$hp:631/ipp/print',
      'ipp://$hp:631/ipp/printer',
      'ipp://$hp:631/ipp',
    ]);
    final report = buildReport(r);
    expect(report, contains('\nIPP: HTTP 404\n'));
    expect(report, contains('\neSCL: connection refused\n'));
    expect(report, contains('\nmDNS: _ipps._tcp port 631 rp="/ipp/lp"\n'));
    expect(report, contains('\nWSD: no answer\n'));
    expect(report, endsWith('Verdict: print=none, scan=none\n'));
  });

  test('nothing answers: every line still there', () async {
    final net = fakeNet(ports: const {}, ippError: const IppError('The printer did not answer in time'));
    final r = await checkDevice(hp, appVersion: '1', flavor: 'play', net: net, now: () => time);
    final report = buildReport(r);
    expect(report, contains('Ports: 80 timeout, 443 timeout, 515 timeout, 631 timeout, 1865 timeout, 9100 timeout\n'));
    expect(report, contains('mDNS: no services from this host\n'));
    expect(report, contains('IPP: timeout\n'));
    expect(report, contains('eSCL: timeout\n'));
  });

  group('LAN only', () {
    /// The real IPP and eSCL clients on a fake HTTP stack; [redirect] answers every request.
    (DeviceCheckNet, List<http.Request>) httpNet({String? redirect}) {
      final requests = <http.Request>[];
      final client = MockClient((r) async {
        requests.add(r);
        return redirect == null
            ? http.Response('', 404)
            : http.Response('', 307, headers: {'location': redirect});
      });
      final net = DeviceCheckNet(
        resolve: resolveLocal,
        port: (address, port) async => 'open',
        browse: (types, {Duration timeout = Duration.zero}) async => const [],
        printerCaps: (uri) => getPrinterCaps(uri, client: client),
        scannerCaps: (base) => EsclClient(base, client: client).capabilities(),
        wsd: (target, {Duration wait = Duration.zero}) async => const [],
      );
      return (net, requests);
    }

    test('a public address is refused before any request', () async {
      final (net, requests) = httpNet();
      final r = await checkDevice('8.8.8.8', appVersion: '1', flavor: 'play', net: net, now: () => time);
      expect(requests, isEmpty);
      expect(r.ipp.error, 'not a local address');
      expect(r.escl.error, 'not a local address');
    });

    test('a redirect to a public address is refused', () async {
      final (net, requests) = httpNet(redirect: 'http://8.8.8.8/x');
      final r = await checkDevice(hp, appVersion: '1', flavor: 'play', net: net, now: () => time);
      expect(r.ipp.error, 'not a local address');
      expect(r.escl.error, 'not a local address');
      expect(requests, isNotEmpty);
      expect(requests.where((q) => q.url.host != hp), isEmpty);
      expect(requests.where((q) => q.followRedirects), isEmpty);
    });
  });

  group('WS-Discovery', () {
    test('ProbeMatch: Types and XAddrs without namespace prefixes, whitespace collapsed', () {
      final m = parseProbeMatches(epsonProbeMatches);
      expect(m, hasLength(1));
      expect(m.single.types, 'wsdp:Device wscn:ScanDeviceType');
      expect(m.single.xaddrs, 'http://$epson:80/WSD/DEVICE');
      expect(m.single.scanner, isTrue);
    });

    test('not a ProbeMatches envelope or not XML: nothing', () {
      expect(parseProbeMatches('<a><b/></a>'), isEmpty);
      expect(parseProbeMatches('garbage <'), isEmpty);
    });

    test('several answers merge into one, each entry once', () {
      final m = mergeMatches(const [
        WsdMatch(types: 'wsdp:Device wprt:PrintDeviceType', xaddrs: 'http://a/'),
        WsdMatch(types: 'wsdp:Device wscn:ScannerServiceType', xaddrs: 'http://a/ http://b/'),
      ])!;
      expect(m.types, 'wsdp:Device wprt:PrintDeviceType wscn:ScannerServiceType');
      expect(m.xaddrs, 'http://a/ http://b/');
      expect(m.scanner, isTrue);
      expect(mergeMatches(const []), isNull);
    });

    test('Probe message: SOAP 1.2, discovery To/Action, a uuid MessageID, no Types', () {
      final id = randomMessageId();
      expect(id, matches(RegExp(r'^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')));
      expect(randomMessageId(), isNot(id));
      final msg = wsdProbeMessage(id);
      expect(msg, contains('http://www.w3.org/2003/05/soap-envelope'));
      expect(msg, contains('<wsa:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</wsa:To>'));
      expect(msg, contains('<wsa:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</wsa:Action>'));
      expect(msg, contains('<wsa:MessageID>$id</wsa:MessageID>'));
      expect(msg, contains('<wsd:Probe/>'));
      expect(msg, isNot(contains('Types')));
    });

    test('a public address is never probed', () async {
      expect(await wsDiscoveryProbe(InternetAddress('8.8.8.8')), isEmpty);
    });
  });

  test('short errors', () {
    expect(shortError(const ScannerError('The scanner did not answer in time')), 'timeout');
    expect(shortError(const IppError('Cannot reach the printer: Connection refused')),
        'connection refused');
    expect(shortError(const ScannerError('ScannerCapabilities failed (HTTP 404)')), 'HTTP 404');
    expect(shortError(const IppError('x', status: 0x0406)), 'client-error-not-found');
  });

  testWidgets('check screen: progress, then the report; Copy puts it in the clipboard',
      (tester) async {
    const report = 'Glassbed device check\nHost: 192.168.178.60\nVerdict: print=none, scan=none\n';
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboard = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() =>
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    String? checked;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: DeviceCheckScreen(
        host: epson,
        check: (host) async {
          checked = host;
          await Future<void>.delayed(const Duration(seconds: 2));
          return report;
        },
      ),
    ));
    await tester.pump();
    expect(find.text('Device check'), findsOneWidget);
    expect(find.text('Checking the device…'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Copy report'), findsNothing);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(checked, epson);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(report.trimRight()), findsOneWidget);
    expect(find.textContaining('Send this report to the developer'), findsOneWidget);
    expect(find.text('Share report'), findsOneWidget);

    await tester.tap(find.text('Copy report'));
    await tester.pump();
    expect(clipboard, report);
    expect(find.text('Copied.'), findsOneWidget);
  });

  testWidgets('printer card: "Check device" in the menu next to Search', (tester) async {
    var checks = 0;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: Scaffold(
        body: PrinterCard(
          hostController: TextEditingController(text: epson),
          searching: false,
          devices: null,
          selected: null,
          link: Link.offline,
          info: null,
          onConnect: () {},
          onSearch: () {},
          onPick: (_) {},
          onCheck: () => checks++,
        ),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('printer-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Check device'));
    await tester.pumpAndSettle();
    expect(checks, 1);
  });

  testWidgets('check screen: a failing check still shows a report', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.light),
      home: DeviceCheckScreen(host: epson, check: (_) async => throw const SocketException('boom')),
    ));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('Host: $epson'), findsOneWidget);
    expect(find.text('Copy report'), findsOneWidget);
  });
}
