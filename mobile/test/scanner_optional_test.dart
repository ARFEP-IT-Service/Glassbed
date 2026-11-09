import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/device.dart';
import 'package:glassbed/core/escl.dart';
import 'package:glassbed/core/ipp.dart';
import 'package:glassbed/core/probe.dart';
import 'package:glassbed/device_texts.dart';
import 'package:glassbed/ui/home/home_screen.dart';
import 'package:glassbed/ui/home/printer_card.dart';
import 'package:glassbed/ui/home/scan_card.dart';
import 'package:glassbed/ui/print/print_section.dart';
import 'package:glassbed/ui/theme.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final capsXml = File('test/fixtures/scanner_capabilities.xml').readAsStringSync();
final device = Device.fromHost('192.168.178.50');

const printerInfo = PrinterInfo(
  state: 'idle',
  stateReasons: [],
  makeAndModel: 'Canon LBP',
  markers: [],
);

/// eSCL that answers ScannerCapabilities with [respond].
EsclClient escl(Future<http.Response> Function() respond) =>
    EsclClient(device.esclBase, client: MockClient((_) => respond()));

Future<PrinterInfo> printerUp(Uri _) async => printerInfo;
Future<PrinterInfo> printerDown(Uri _) async => throw const IppError('Cannot reach the printer');

/// The Scan / Copy / Print button with [label] (not the navigation bar entry).
ButtonStyleButton button(WidgetTester tester, String label) => tester.widget<ButtonStyleButton>(
    find.ancestor(of: find.text(label), matching: find.bySubtype<ButtonStyleButton>()).first);

NavigationDestination destination(WidgetTester tester, String label) =>
    tester.widget<NavigationDestination>(find.widgetWithText(NavigationDestination, label));

void main() {
  group('probe: the capabilities decide', () {
    test('capabilities answer: it scans', () async {
      final p = await probeDevice(device, escl(() async => http.Response(capsXml, 200)),
          printerInfo: printerUp);
      expect(p.scanner, isTrue);
      expect(p.online, isTrue);
      expect(p.caps!.sources, isNotEmpty);
    });

    test('printer answers, eSCL 404: printer only', () async {
      final p = await probeDevice(device, escl(() async => http.Response('', 404)),
          printerInfo: printerUp);
      expect(p.scanner, isFalse);
      expect(p.online, isTrue);
      expect(p.scanError, isA<ScannerError>());
    });

    test('printer answers, port 80 refuses: printer only', () async {
      final p = await probeDevice(
          device, escl(() async => throw http.ClientException('Connection refused')),
          printerInfo: printerUp);
      expect(p.scanner, isFalse);
      expect(p.online, isTrue);
    });

    test('printer answers, a web page instead of capabilities: printer only', () async {
      final p = await probeDevice(
          device,
          escl(() async => http.Response(
              '<html xmlns="http://www.w3.org/1999/xhtml"><body>Login</body></html>', 200)),
          printerInfo: printerUp);
      expect(p.scanner, isFalse);
    });

    test('nothing answers: offline, never "no scanner"', () async {
      final p = await probeDevice(
          device, escl(() async => throw http.ClientException('No route to host')),
          printerInfo: printerDown);
      expect(p.online, isFalse);
      expect(p.scanner, isNull);
    });

    test('a later successful load makes it a scanner again', () async {
      var up = false;
      final client = escl(() async => up ? http.Response(capsXml, 200) : http.Response('', 503));
      expect((await probeDevice(device, client, printerInfo: printerUp)).scanner, isFalse);
      up = true;
      expect((await probeDevice(device, client, printerInfo: printerUp)).scanner, isTrue);
    });
  });

  group('home screen', () {
    late Probe next;

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      // The Android side: local network allowed, nothing shared.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('de.arfep.glassbed/platform'),
          (call) async => switch (call.method) {
                'localNetworkAllowed' => true,
                'takeSharedFiles' => <Object?>[],
                _ => null,
              });
    });

    Future<void> pumpHome(WidgetTester tester) async {
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.light),
        home: HomeScreen(probe: (_, _) async => next),
      ));
      await tester.pumpAndSettle();
    }

    Future<void> connect(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField).first, device.host); // the address field
      await tester.tap(find.byTooltip('Connect'));
      await tester.pumpAndSettle();
    }

    final scanner = Probe(caps: parseCapabilities(capsXml), info: printerInfo);
    const printerOnly = Probe(info: printerInfo, scanError: ScannerError('HTTP 404'));

    testWidgets('printer only: scan locked with a hint, opens on Print, printing stays',
        (tester) async {
      await pumpHome(tester);
      expect(button(tester, 'Scan').onPressed, isNotNull); // nothing known yet: as before
      next = printerOnly;
      await connect(tester);
      expect(find.text(noScannerHint), findsOneWidget);
      expect(find.text('Ready'), findsOneWidget);
      expect(find.byType(PrintSection), findsOneWidget);
      expect(find.byType(ScanCard), findsNothing);
      expect(destination(tester, 'Scan').enabled, isFalse);
      expect(destination(tester, 'Print').enabled, isTrue);
    });

    testWidgets('offline: no "no scanner" hint, scanning not locked', (tester) async {
      await pumpHome(tester);
      next = const Probe(scanError: ScannerError('Cannot reach the scanner'));
      await connect(tester);

      expect(find.text('Offline'), findsOneWidget);
      expect(find.text(noScannerHint), findsNothing);
      expect(find.byType(ScanCard), findsOneWidget);
      expect(destination(tester, 'Scan').enabled, isTrue);
      expect(button(tester, 'Scan').onPressed, isNotNull);
      expect(button(tester, 'Print copy').onPressed, isNotNull);
    });

    testWidgets('capabilities load after a failure: scanning comes back', (tester) async {
      await pumpHome(tester);
      next = printerOnly;
      await connect(tester);
      expect(destination(tester, 'Scan').enabled, isFalse);

      next = scanner;
      await connect(tester);
      expect(find.text(noScannerHint), findsNothing);
      expect(destination(tester, 'Scan').enabled, isTrue);
      await tester.tap(find.widgetWithText(NavigationDestination, 'Scan'));
      await tester.pumpAndSettle();
      expect(button(tester, 'Scan').onPressed, isNotNull);
      expect(button(tester, 'Print copy').onPressed, isNotNull);
    });
  });

  testWidgets('scan card without a scanner: options, scan and copy locked', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ListView(children: [
          ScanCard(
            caps: null,
            source: ScanSource.platen,
            mode: ColorMode.color,
            dpi: 200,
            scanning: false,
            pagesThisRun: 0,
            hasPages: true,
            onSource: (_) {},
            onMode: (_) {},
            onDpi: (_) {},
            onScan: () {},
            onCancel: () {},
            copyCopies: 1,
            onCopyCopies: (_) {},
            onCopy: () {},
            copyStatus: null,
            onCancelCopy: null,
            available: false,
          ),
        ]),
      ),
    ));
    expect(button(tester, 'Scan').onPressed, isNull);
    expect(button(tester, 'Print copy').onPressed, isNull);
    final source = tester.widget<SegmentedButton<ScanSource>>(find.byType(SegmentedButton<ScanSource>));
    expect(source.onSelectionChanged, isNull);
  });

  testWidgets('device list: several printers, each with its kind, no overflow on a narrow screen',
      (tester) async {
    final devices = [
      Device.fromHost('192.168.178.12', name: 'FUJIFILM Apeos C2360 Color Multifunction (A1B2C3D4)')
          .withScanner(false),
      Device.fromHost('192.168.178.11', name: 'Canon LBP').withScanner(false),
      Device.fromHost('192.168.178.10', name: 'Zebra MFP').withScanner(true),
      Device.fromHost('192.168.178.13', name: 'Brother').withScanner(true),
    ];
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: ListView(children: [
          PrinterCard(
            hostController: TextEditingController(),
            searching: false,
            devices: devices,
            selected: devices[2],
            link: Link.online,
            info: printerInfo,
            scanner: false, // Zebra announced a scanner, but its capabilities failed
            onConnect: () {},
            onSearch: () {},
            onPick: (_) {},
          ),
        ]),
      ),
    ));
    expect(tester.takeException(), isNull);
    for (final d in devices) {
      expect(find.text(d.host), findsOneWidget);
      expect(find.text(d.name), findsOneWidget);
    }
    // the connected device shows what it really can
    expect(find.text('Printer only'), findsNWidgets(3));
    expect(find.text('Scanner + printer'), findsOneWidget);
    expect(find.text(noScannerHint), findsOneWidget);
  });

  test('device texts come from the shared texts in en/de/tr', () {
    final texts = (jsonDecode(File('assets/i18n/shared.json').readAsStringSync()) as Map)['texts'] as Map;
    for (final key in [noScannerHint, 'Printer only', 'Scanner + printer']) {
      final entry = texts[key] as Map;
      expect(entry['en'], key);
      for (final lang in ['de', 'tr']) {
        expect((entry[lang] as String).trim(), isNotEmpty, reason: '$key/$lang');
      }
    }
  });
}

extension on Device {
  Device withScanner(bool scanner) =>
      Device(name: name, host: host, esclBase: esclBase, ippUri: ippUri, scanner: scanner);
}
