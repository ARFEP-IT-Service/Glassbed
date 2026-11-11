import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/escl.dart';
import 'package:glassbed/core/lan.dart';
import 'package:glassbed/ui/dialogs.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

final capsXml = File('test/fixtures/scanner_capabilities.xml').readAsStringSync();
final statusXml = File('test/fixtures/scanner_status.xml').readAsStringSync();
final base = Uri.parse('http://192.168.178.33/eSCL/');

Uint8List jpegPage({bool gray = false}) {
  final image = img.Image(width: 48, height: 64);
  for (final p in image) {
    final v = p.x * 255 ~/ 47;
    if (gray) {
      p.setRgb(v, v, v);
    } else {
      p.setRgb(v, 255 - v, (p.y * 4) % 256);
    }
  }
  return img.encodeJpg(image, quality: 90);
}

/// A fake HP: records requests, serves [pages] JPEGs, then 404.
class FakeScanner {
  FakeScanner({
    this.pages = 2,
    this.adfState = 'ScannerAdfLoaded',
    this.createStatus = 201,
    this.location = 'http://192.168.178.33:80/eSCL/ScanJobs/7f3a',
    this.gray = false,
  });

  final int pages;
  final String adfState;
  final int createStatus;
  final String location;
  final bool gray;
  final requests = <http.Request>[];
  var served = 0;
  Completer<void>? hold; // when set, NextDocument waits for it

  late final client = MockClient((r) async {
    requests.add(r);
    final path = r.url.path;
    if (r.method == 'GET' && path.endsWith('/ScannerCapabilities')) {
      return http.Response(capsXml, 200, headers: {'content-type': 'text/xml'});
    }
    if (r.method == 'GET' && path.endsWith('/ScannerStatus')) {
      return http.Response(statusXml.replaceAll('ScannerAdfLoaded', adfState), 200);
    }
    if (r.method == 'POST' && path.endsWith('/ScanJobs')) {
      return http.Response('', createStatus,
          headers: createStatus == 201 ? {'location': location} : {});
    }
    if (r.method == 'GET' && path.endsWith('/NextDocument')) {
      if (hold != null) await hold!.future;
      if (served < pages) {
        served++;
        return http.Response.bytes(jpegPage(gray: gray), 200,
            headers: {'content-type': 'image/jpeg'});
      }
      return http.Response('', 404);
    }
    if (r.method == 'DELETE') return http.Response('', 200);
    return http.Response('', 500);
  });

  EsclClient escl() => EsclClient(base,
      client: client, busyWait: Duration.zero, retryDelay: const Duration(milliseconds: 1));

  Iterable<String> get calls => requests.map((r) => '${r.method} ${r.url.path}');
}

XmlElement el(XmlDocument d, String local) =>
    d.descendants.whereType<XmlElement>().firstWhere((e) => e.name.local == local);

void main() {
  group('parseCapabilities', () {
    final caps = parseCapabilities(capsXml);

    test('model and version', () {
      expect(caps.makeAndModel, 'HP Color Laser MFP 178 179');
      expect(caps.version, '2.63');
      expect(caps.sources, [ScanSource.platen, ScanSource.feeder]);
    });

    test('platen', () {
      final p = caps.platen!;
      expect(p.resolutions, [75, 100, 150, 200, 300, 600, 1200]);
      expect(p.colorModes, ['RGB24', 'Grayscale8', 'BlackAndWhite1']);
      expect(p.maxWidth, 2550);
      expect(p.maxHeight, 3508);
      expect(p.dpiChoices, [100, 150, 200, 300]);
      expect(p.modes, [ColorMode.color, ColorMode.gray, ColorMode.bw]);
    });

    test('feeder', () {
      final a = caps.adf!;
      expect(a.resolutions, [75, 100, 150, 200, 300]);
      expect(a.maxHeight, 4200);
    });

    test('no feeder in a flatbed-only device', () {
      final flatbed = parseCapabilities(
          capsXml.replaceAll(RegExp(r'<scan:Adf>.*</scan:Adf>', dotAll: true), ''));
      expect(flatbed.adf, isNull);
      expect(flatbed.sources, [ScanSource.platen]);
    });

    test('invalid XML is a ScannerError', () {
      expect(() => parseCapabilities('<nope'), throwsA(isA<ScannerError>()));
    });
  });

  test('parseScannerState / parseAdfState', () {
    expect(parseScannerState(statusXml), 'Idle');
    expect(parseScannerState(statusXml.replaceAll('>Idle<', '>Processing<')), 'Processing');
    expect(parseAdfState(statusXml), 'ScannerAdfLoaded');
  });

  group('buildScanSettings', () {
    final caps = parseCapabilities(capsXml);
    XmlDocument build(ScanSettings s) => XmlDocument.parse(buildScanSettings(s, caps));

    test('namespaces, region and resolution', () {
      final d = build(ScanSettings(source: ScanSource.platen, mode: ColorMode.color, dpi: 300));
      final root = d.rootElement;
      expect(root.name.local, 'ScanSettings');
      expect(root.name.namespaceUri, nsScan);
      expect(el(d, 'Version').name.namespaceUri, nsPwg);
      expect(el(d, 'Version').innerText, '2.63');
      expect(el(d, 'InputSource').name.namespaceUri, nsPwg);
      expect(el(d, 'ColorMode').name.namespaceUri, nsScan);
      expect(el(d, 'XResolution').name.namespaceUri, nsScan);
      expect(el(d, 'XResolution').innerText, '300');
      expect(el(d, 'YResolution').innerText, '300');
      expect(el(d, 'Width').innerText, '2480');
      expect(el(d, 'Height').innerText, '3507');
      expect(el(d, 'ContentRegionUnits').innerText, 'escl:ThreeHundredthsOfInches');
      expect(el(d, 'DocumentFormat').innerText, 'image/jpeg');
      expect(el(d, 'InputSource').innerText, 'Platen');
      expect(el(d, 'ColorMode').innerText, 'RGB24');
    });

    test('colour mode mapping (B/W is scanned in grey)', () {
      expect(el(build(ScanSettings(mode: ColorMode.color)), 'ColorMode').innerText, 'RGB24');
      expect(el(build(ScanSettings(mode: ColorMode.gray)), 'ColorMode').innerText, 'Grayscale8');
      expect(el(build(ScanSettings(mode: ColorMode.bw)), 'ColorMode').innerText, 'Grayscale8');
    });

    test('input source and resolutions', () {
      final d = build(ScanSettings(source: ScanSource.feeder, dpi: 150));
      expect(el(d, 'InputSource').innerText, 'Feeder');
      expect(el(d, 'XResolution').innerText, '150');
      // unsupported value -> nearest supported one
      expect(el(build(ScanSettings(dpi: 250)), 'XResolution').innerText, '300');
      expect(el(build(ScanSettings(dpi: 120)), 'XResolution').innerText, '100');
    });
  });

  group('scan flow', () {
    test('feeder: two pages, then 404', () async {
      final fake = FakeScanner();
      final pages = await fake
          .escl()
          .scan(ScanSettings(source: ScanSource.feeder, mode: ColorMode.color, dpi: 200))
          .toList();
      expect(pages, hasLength(2));
      for (final p in pages) {
        expect(p.dpi, 200);
        expect(p.image.width, 48);
        expect(p.image.height, 64);
        expect(p.image.numChannels, 3);
      }
      expect(fake.calls, [
        'GET /eSCL/ScannerCapabilities',
        'GET /eSCL/ScannerStatus',
        'POST /eSCL/ScanJobs',
        'GET /eSCL/ScanJobs/7f3a/NextDocument',
        'GET /eSCL/ScanJobs/7f3a/NextDocument',
        'GET /eSCL/ScanJobs/7f3a/NextDocument',
      ]);
      final post = fake.requests.firstWhere((r) => r.method == 'POST');
      expect(post.headers['Content-Type'], startsWith('text/xml'));
      expect(post.body, contains('<pwg:InputSource>Feeder</pwg:InputSource>'));
      expect(post.body, contains('<scan:XResolution>200</scan:XResolution>'));
    });

    test('platen: relative job location', () async {
      final fake = FakeScanner(pages: 1, location: '/eSCL/ScanJobs/42');
      final pages = await fake.escl().scan(ScanSettings()).toList();
      expect(pages, hasLength(1));
      expect(fake.calls, isNot(contains('GET /eSCL/ScannerStatus')));
      expect(fake.calls, contains('GET /eSCL/ScanJobs/42/NextDocument'));
    });

    test('503 on job creation -> ScannerBusy', () async {
      final fake = FakeScanner(createStatus: 503);
      await expectLater(fake.escl().scan(ScanSettings()).toList(), throwsA(isA<ScannerBusy>()));
      expect(fake.calls.where((c) => c.startsWith('DELETE')), isEmpty);
    });

    test('409 on job creation -> ScannerBusy', () async {
      final fake = FakeScanner(createStatus: 409);
      await expectLater(fake.escl().scan(ScanSettings()).toList(), throwsA(isA<ScannerBusy>()));
    });

    test('feeder empty per ScannerStatus -> FeederEmpty, no job', () async {
      final fake = FakeScanner(adfState: 'ScannerAdfEmpty');
      await expectLater(
        fake.escl().scan(ScanSettings(source: ScanSource.feeder)).toList(),
        throwsA(isA<FeederEmpty>()),
      );
      expect(fake.calls.where((c) => c.startsWith('POST')), isEmpty);
    });

    test('feeder returns no page at all -> FeederEmpty', () async {
      final fake = FakeScanner(pages: 0);
      await expectLater(
        fake.escl().scan(ScanSettings(source: ScanSource.feeder)).toList(),
        throwsA(isA<FeederEmpty>()),
      );
    });

    test('B/W pages are thresholded to pure black and white', () async {
      final fake = FakeScanner(pages: 1, gray: true);
      final pages = await fake.escl().scan(ScanSettings(mode: ColorMode.bw)).toList();
      final post = fake.requests.firstWhere((r) => r.method == 'POST');
      expect(post.body, contains('<scan:ColorMode>Grayscale8</scan:ColorMode>'));
      final image = pages.single.image;
      expect(image.numChannels, 1);
      final values = image.toUint8List().toSet();
      expect(values.difference({0, 255}), isEmpty);
      expect(values, containsAll([0, 255]));
    });

    test('grey pages have one channel', () async {
      final fake = FakeScanner(pages: 1);
      final pages = await fake.escl().scan(ScanSettings(mode: ColorMode.gray)).toList();
      expect(pages.single.image.numChannels, 1);
    });

    test('cancel between pages -> DELETE job + ScanCancelled', () async {
      final fake = FakeScanner(pages: 5);
      final token = CancelToken();
      final got = <ScannedPage>[];
      await expectLater(
        fake.escl().scan(ScanSettings(source: ScanSource.feeder), cancel: token).forEach((p) {
          got.add(p);
          token.cancel();
        }),
        throwsA(isA<ScanCancelled>()),
      );
      expect(got, hasLength(1));
      expect(fake.calls.last, 'DELETE /eSCL/ScanJobs/7f3a');
    });

    test('cancel while waiting for a page -> DELETE job + ScanCancelled', () async {
      final fake = FakeScanner()..hold = Completer<void>();
      final token = CancelToken();
      final future = fake.escl().scan(ScanSettings(), cancel: token).toList();
      Timer(const Duration(milliseconds: 50), token.cancel);
      await expectLater(future, throwsA(isA<ScanCancelled>()));
      expect(fake.calls, contains('DELETE /eSCL/ScanJobs/7f3a'));
      fake.hold!.complete();
    });

    test('state()', () async {
      expect(await FakeScanner().escl().state(), 'Idle');
    });
  });

  group('LAN only', () {
    for (final host in ['8.8.8.8', 'example.com']) {
      test('$host is refused before any request', () async {
        var calls = 0;
        final client = MockClient((r) async {
          calls++;
          return http.Response(capsXml, 200);
        });
        final escl = EsclClient(Uri.parse('http://$host/eSCL/'), client: client);
        await expectLater(escl.capabilities(), throwsA(isA<NotLocalNetwork>()));
        await expectLater(escl.state(), throwsA(isA<NotLocalNetwork>()));
        await expectLater(escl.scan(ScanSettings()).toList(), throwsA(isA<NotLocalNetwork>()));
        expect(calls, 0);
      });
    }

    test('a job location outside the LAN is refused', () async {
      final fake = FakeScanner(location: 'http://203.0.113.5/eSCL/ScanJobs/1');
      await expectLater(fake.escl().scan(ScanSettings()).toList(), throwsA(isA<NotLocalNetwork>()));
      expect(fake.requests.where((r) => r.url.host == '203.0.113.5'), isEmpty);
    });
  });

  group('redirects', () {
    /// Answers [routes] by "METHOD url"; anything else is 404. Records every request.
    (MockClient, List<http.Request>) redirecting(Map<String, http.Response Function()> routes) {
      final requests = <http.Request>[];
      final client = MockClient((r) async {
        requests.add(r);
        return routes['${r.method} ${r.url}']?.call() ?? http.Response('', 404);
      });
      return (client, requests);
    }

    http.Response to(int status, String location) =>
        http.Response('', status, headers: {'location': location});

    void noAutoRedirects(List<http.Request> requests) {
      expect(requests, isNotEmpty);
      for (final r in requests) {
        expect(r.followRedirects, isFalse, reason: '${r.method} ${r.url}');
      }
    }

    for (final target in [
      'http://8.8.8.8/eSCL/ScannerCapabilities',
      'http://[2001:4860:4860::8888]/eSCL/ScannerCapabilities',
    ]) {
      test('capabilities: a redirect to $target is refused', () async {
        final (client, requests) = redirecting({
          'GET http://192.168.178.33/eSCL/ScannerCapabilities': () => to(302, target),
          'GET $target': () => http.Response(capsXml, 200),
        });
        Object? error;
        try {
          await EsclClient(base, client: client).capabilities();
        } catch (e) {
          error = e;
        }
        final host = Uri.parse(target).host;
        expect(error, isA<NotLocalNetwork>().having((e) => e.host, 'host', host));
        expect(errorText(error!), 'Only devices on the local network can be used ($host).');
        expect(requests.map((r) => r.url.host), ['192.168.178.33']);
        noAutoRedirects(requests);
      });
    }

    test('capabilities: a redirect to another local address is followed', () async {
      for (final status in [301, 302, 303, 307, 308]) {
        final (client, requests) = redirecting({
          'GET http://192.168.178.33/eSCL/ScannerCapabilities': () =>
              to(status, 'http://192.168.1.50:8080/eSCL/ScannerCapabilities'),
          'GET http://192.168.1.50:8080/eSCL/ScannerCapabilities': () => http.Response(capsXml, 200),
        });
        final caps = await EsclClient(base, client: client).capabilities();
        expect(caps.makeAndModel, 'HP Color Laser MFP 178 179', reason: 'HTTP $status');
        expect(requests.map((r) => r.url.toString()), [
          'http://192.168.178.33/eSCL/ScannerCapabilities',
          'http://192.168.1.50:8080/eSCL/ScannerCapabilities',
        ]);
        noAutoRedirects(requests);
      }
    });

    test('a relative Location is resolved against the current URL', () async {
      final (client, requests) = redirecting({
        'GET http://192.168.178.33/eSCL/ScannerCapabilities': () => to(301, '/scan/ScannerCapabilities'),
        'GET http://192.168.178.33/scan/ScannerCapabilities': () => http.Response(capsXml, 200),
      });
      expect((await EsclClient(base, client: client).capabilities()).version, '2.63');
      expect(requests, hasLength(2));
      noAutoRedirects(requests);
    });

    test('a redirect loop stops after 5 redirects', () async {
      final (client, requests) = redirecting({
        'GET http://192.168.178.33/eSCL/ScannerCapabilities': () => to(302, '/a'),
        'GET http://192.168.178.33/a': () => to(302, '/eSCL/ScannerCapabilities'),
      });
      await expectLater(EsclClient(base, client: client).capabilities(),
          throwsA(isA<ScannerError>().having((e) => e.message, 'message', 'Too many redirects')));
      expect(requests, hasLength(maxRedirects + 1));
      noAutoRedirects(requests);
    });

    test('a redirect without Location is an error', () async {
      final (client, requests) = redirecting({
        'GET http://192.168.178.33/eSCL/ScannerStatus': () => http.Response('', 302),
      });
      await expectLater(
          EsclClient(base, client: client).state(),
          throwsA(isA<ScannerError>()
              .having((e) => e.message, 'message', 'Redirect without a target')));
      noAutoRedirects(requests);
    });

    test('ScanJobs: 302 is not followed', () async {
      final (client, requests) = redirecting({
        'GET http://192.168.178.33/eSCL/ScannerCapabilities': () => http.Response(capsXml, 200),
        'POST http://192.168.178.33/eSCL/ScanJobs': () =>
            to(302, 'http://192.168.178.33/other/ScanJobs'),
      });
      final escl = EsclClient(base, client: client, busyWait: Duration.zero);
      await expectLater(escl.scan(ScanSettings()).toList(),
          throwsA(isA<ScannerError>().having((e) => e.message, 'message', contains('HTTP 302'))));
      expect(requests.map((r) => '${r.method} ${r.url.path}'),
          ['GET /eSCL/ScannerCapabilities', 'POST /eSCL/ScanJobs']);
      noAutoRedirects(requests);
    });

    test('ScanJobs: 307 to a local address is followed with the same body', () async {
      var pages = 0;
      final (client, requests) = redirecting({
        'GET http://192.168.178.33/eSCL/ScannerCapabilities': () => http.Response(capsXml, 200),
        'POST http://192.168.178.33/eSCL/ScanJobs': () =>
            to(307, 'http://192.168.178.40/eSCL/ScanJobs'),
        'POST http://192.168.178.40/eSCL/ScanJobs': () => http.Response('', 201,
            headers: {'location': 'http://192.168.178.40/eSCL/ScanJobs/9'}),
        'GET http://192.168.178.40/eSCL/ScanJobs/9/NextDocument': () => pages++ == 0
            ? http.Response.bytes(jpegPage(), 200, headers: {'content-type': 'image/jpeg'})
            : http.Response('', 404),
      });
      expect(await EsclClient(base, client: client).scan(ScanSettings()).toList(), hasLength(1));
      final posts = requests.where((r) => r.method == 'POST').toList();
      expect(posts.map((r) => r.url.host), ['192.168.178.33', '192.168.178.40']);
      expect(posts[1].body, posts[0].body);
      expect(posts[1].body, contains('<pwg:InputSource>Platen</pwg:InputSource>'));
      expect(posts[1].headers['Content-Type'], startsWith('text/xml'));
      noAutoRedirects(requests);
    });

    test('ScanJobs: 307 to a public address is refused', () async {
      final (client, requests) = redirecting({
        'GET http://192.168.178.33/eSCL/ScannerCapabilities': () => http.Response(capsXml, 200),
        'POST http://192.168.178.33/eSCL/ScanJobs': () => to(307, 'http://8.8.8.8/eSCL/ScanJobs'),
      });
      await expectLater(EsclClient(base, client: client).scan(ScanSettings()).toList(),
          throwsA(isA<NotLocalNetwork>()));
      expect(requests.where((r) => r.url.host == '8.8.8.8'), isEmpty);
      noAutoRedirects(requests);
    });

    test('every request of a normal scan has followRedirects off', () async {
      final fake = FakeScanner(pages: 1);
      await fake.escl().scan(ScanSettings(source: ScanSource.feeder)).toList();
      noAutoRedirects(fake.requests);
    });
  });
}
