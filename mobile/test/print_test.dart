import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/escl.dart' show ScannedPage;
import 'package:glassbed/core/ipp.dart';
import 'package:glassbed/core/lan.dart';
import 'package:glassbed/core/pixels.dart';
import 'package:glassbed/core/print_layout.dart';
import 'package:glassbed/core/printing.dart';
import 'package:glassbed/core/urf.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as img;

import 'ipp_test.dart' show IppBuilder;

final printer = Uri.parse('ipp://192.168.178.33:631/ipp/print');

/// Raw attributes of a request, in order: (group, tag, name, value bytes).
List<(int, int, String, List<int>)> rawAttributes(Uint8List req, {List<int>? rest}) {
  final out = <(int, int, String, List<int>)>[];
  final bd = ByteData.sublistView(req);
  var i = 8, group = 0;
  String name = '';
  while (true) {
    final tag = req[i++];
    if (tag == 0x03) break;
    if (tag < 0x10) {
      group = tag;
      continue;
    }
    final nl = bd.getUint16(i);
    i += 2;
    if (nl > 0) name = String.fromCharCodes(req.sublist(i, i + nl));
    i += nl;
    final vl = bd.getUint16(i);
    i += 2;
    out.add((group, tag, name, req.sublist(i, i + vl)));
    i += vl;
  }
  rest?.addAll(req.sublist(i));
  return out;
}

Uint8List capsResponse({
  List<String> formats = const ['application/pdf', 'image/urf', 'image/jpeg'],
  List<String> reasons = const ['none'],
  List<String> urf = const ['V1.4', 'CP1', 'W8', 'SRGB24', 'RS300-600', 'DM1'],
  bool color = true,
}) {
  final b = IppBuilder(0)
    ..group(0x01)
    ..strings(tagCharset, 'attributes-charset', ['utf-8'])
    ..group(0x04)
    ..ints(tagEnum, 'printer-state', [3])
    ..strings(tagKeyword, 'printer-state-reasons', reasons)
    ..strings(tagText, 'printer-make-and-model', ['HP Color Laser MFP 178 179'])
    ..strings(tagMimeType, 'document-format-supported', formats)
    ..strings(tagKeyword, 'media-supported', ['iso_a4_210x297mm', 'na_letter_8.5x11in'])
    ..strings(tagKeyword, 'media-default', ['na_letter_8.5x11in'])
    ..bools('color-supported', [color])
    ..strings(tagKeyword, 'print-color-mode-supported', color ? ['color', 'monochrome'] : ['monochrome'])
    ..strings(tagKeyword, 'sides-supported', ['one-sided'])
    ..strings(tagKeyword, 'urf-supported', urf);
  return b.done();
}

Uint8List jobResponse(int status, {int jobId = 42, String message = ''}) {
  final b = IppBuilder(status)
    ..group(0x01)
    ..strings(tagCharset, 'attributes-charset', ['utf-8']);
  if (message.isNotEmpty) b.strings(tagText, 'status-message', [message]);
  if (status < 0x100) {
    b
      ..group(0x02)
      ..ints(tagInteger, 'job-id', [jobId])
      ..ints(tagEnum, 'job-state', [3]);
  }
  return b.done();
}

/// A fake printer: answers Get-Printer-Attributes with [caps] / [later] reasons and
/// records every Print-Job.
class FakePrinter {
  FakePrinter({this.laterReasons = const ['none'], this.jobStatus = 0});

  final Uint8List caps = capsResponse();
  List<String> laterReasons;
  int jobStatus;
  final jobs = <(List<(int, int, String, List<int>)>, Uint8List)>[];
  var infoCalls = 0;

  late final client = MockClient((r) async {
    final body = r.bodyBytes;
    final op = (body[2] << 8) | body[3];
    if (op == ippGetPrinterAttributes) {
      infoCalls++;
      if (infoCalls == 1) return http.Response.bytes(currentCaps, 200);
      return http.Response.bytes(capsResponse(reasons: laterReasons), 200);
    }
    final rest = <int>[];
    final attrs = rawAttributes(body, rest: rest);
    jobs.add((attrs, Uint8List.fromList(rest)));
    return http.Response.bytes(jobResponse(jobStatus), 200);
  });

  Uint8List? capsOverride;
  Uint8List get currentCaps => capsOverride ?? caps;
}

String str(List<int> v) => String.fromCharCodes(v);

Map<String, String> strings(List<(int, int, String, List<int>)> attrs) =>
    {for (final a in attrs) if (a.$2 != tagInteger) a.$3: str(a.$4)};

void main() {
  group('Print-Job', () {
    test('request bytes', () {
      final req = encodePrintJob(printer.toString(),
          format: 'image/urf', jobName: 'Brief.pdf', media: mediaA4, color: false, copies: 3, requestId: 9);
      expect(req.sublist(0, 8), [2, 0, 0x00, 0x02, 0, 0, 0, 9]);
      final attrs = rawAttributes(req);
      expect([for (final a in attrs) (a.$1, a.$2, a.$3)], [
        (0x01, tagCharset, 'attributes-charset'),
        (0x01, tagLanguage, 'attributes-natural-language'),
        (0x01, tagUri, 'printer-uri'),
        (0x01, tagName, 'requesting-user-name'),
        (0x01, tagName, 'job-name'),
        (0x01, tagMimeType, 'document-format'),
        (0x02, tagInteger, 'copies'),
        (0x02, tagKeyword, 'media'),
        (0x02, tagKeyword, 'print-color-mode'),
        (0x02, tagKeyword, 'sides'),
      ]);
      final s = strings(attrs);
      expect(s['attributes-charset'], 'utf-8');
      expect(s['printer-uri'], printer.toString());
      expect(s['requesting-user-name'], 'Glassbed');
      expect(s['job-name'], 'Brief.pdf');
      expect(s['document-format'], 'image/urf');
      expect(s['media'], mediaA4);
      expect(s['print-color-mode'], 'monochrome');
      expect(s['sides'], 'one-sided');
      expect(attrs.firstWhere((a) => a.$3 == 'copies').$4, [0, 0, 0, 3]);
      expect(req.last, 0x03);
    });

    test('colour mode, copies at least 1, long job names cut', () {
      final s = strings(rawAttributes(encodePrintJob('ipp://x/ipp/print',
          format: 'image/jpeg', jobName: 'x' * 300, media: mediaLetter, color: true, copies: 0)));
      expect(s['print-color-mode'], 'color');
      expect(s['job-name'], hasLength(200));
      final copies = rawAttributes(encodePrintJob('ipp://x/ipp/print',
              format: 'image/jpeg', jobName: 'j', media: mediaLetter, color: true, copies: 0))
          .firstWhere((a) => a.$3 == 'copies');
      expect(copies.$4, [0, 0, 0, 1]);
    });

    test('printJob posts header + document, returns the job id', () async {
      late http.Request seen;
      final client = MockClient((r) async {
        seen = r;
        return http.Response.bytes(jobResponse(0, jobId: 77), 200);
      });
      final doc = Uint8List.fromList([1, 2, 3, 4, 5]);
      final id = await printJob(printer, doc,
          format: 'image/urf', jobName: 'Scan', copies: 2, media: mediaA4, color: true, client: client);
      expect(id, 77);
      expect(seen.url.toString(), 'http://192.168.178.33:631/ipp/print');
      expect(seen.headers['Content-Type'], 'application/ipp');
      final rest = <int>[];
      final attrs = rawAttributes(seen.bodyBytes, rest: rest);
      expect(rest, doc); // document right after the end-of-attributes tag
      expect(attrs.firstWhere((a) => a.$3 == 'copies').$4, [0, 0, 0, 2]);
      expect(seen.bodyBytes.sublist(2, 4), [0x00, 0x02]);
    });

    test('error statuses become IppError with the status code', () async {
      for (final status in [ippStatusDocumentFormatNotSupported, 0x040B, ippStatusBusy, 0x0400]) {
        final client = MockClient((r) async =>
            http.Response.bytes(jobResponse(status, message: 'nope'), 200));
        await expectLater(
          printJob(printer, Uint8List(1), format: 'image/urf', jobName: 'j', media: mediaA4, color: true, client: client),
          throwsA(isA<IppError>()
              .having((e) => e.status, 'status', status)
              .having((e) => e.message, 'message', contains(ippStatusName(status)))),
        );
      }
      expect(ippStatusName(0x040A), 'client-error-document-format-not-supported');
      final http500 = MockClient((r) async => http.Response('', 500));
      await expectLater(
        printJob(printer, Uint8List(1), format: 'image/urf', jobName: 'j', media: mediaA4, color: true, client: http500),
        throwsA(isA<IppError>().having((e) => e.status, 'status', isNull)),
      );
    });

    test('non-local hosts are refused before any request', () async {
      var calls = 0;
      final client = MockClient((r) async {
        calls++;
        return http.Response.bytes(jobResponse(0), 200);
      });
      for (final uri in ['ipp://8.8.8.8:631/ipp/print', 'ipp://printer.example.com/ipp/print']) {
        await expectLater(
          printJob(Uri.parse(uri), Uint8List(1), format: 'image/urf', jobName: 'j', media: mediaA4, color: true, client: client),
          throwsA(isA<NotLocalNetwork>()),
        );
        await expectLater(getPrinterCaps(Uri.parse(uri), client: client), throwsA(isA<NotLocalNetwork>()));
        await expectLater(
          printPages(Uri.parse(uri),
                  pageCount: 1, loadPage: loaderFor([const PrintSource.blank()]), media: mediaA4, color: true, client: client)
              .drain<void>(),
          throwsA(isA<NotLocalNetwork>()),
        );
      }
      expect(calls, 0);
    });
  });

  group('capabilities', () {
    test('decode Get-Printer-Attributes', () {
      final caps = parsePrinterCaps(capsResponse(reasons: ['none', 'toner-low-report']));
      expect(caps.state, 'idle');
      expect(caps.stateReasons, ['toner-low-report']);
      expect(caps.makeAndModel, 'HP Color Laser MFP 178 179');
      expect(caps.documentFormats, ['application/pdf', 'image/urf', 'image/jpeg']);
      expect(caps.supportsUrf, isTrue);
      expect(caps.supportsJpeg, isTrue);
      expect(caps.mediaSupported, [mediaA4, mediaLetter]);
      expect(caps.mediaDefault, mediaLetter);
      expect(caps.colorSupported, isTrue);
      expect(caps.colorModes, ['color', 'monochrome']);
      expect(caps.sides, ['one-sided']);
      expect(caps.urfResolutions, [300, 600]);
      expect(caps.urfGray && caps.urfColor, isTrue);
      expect(parsePrinterCaps(capsResponse(color: false)).colorSupported, isFalse);
    });

    test('urf-supported resolutions', () {
      expect(urfResolutionsOf(['V1.4', 'RS300']), [300]);
      expect(urfResolutionsOf(['RS600-300', 'W8']), [300, 600]);
      expect(urfResolutionsOf(['W8']), isEmpty);
      PrinterCaps withRs(List<int> rs) => PrinterCaps(state: 'idle', stateReasons: const [], urfResolutions: rs);
      expect(urfDpiFor(null), 300);
      expect(urfDpiFor(withRs([])), 300);
      expect(urfDpiFor(withRs([300, 600])), 300);
      expect(urfDpiFor(withRs([150, 600])), 150);
      expect(urfDpiFor(withRs([600, 1200])), 600);
    });

    test('getPrinterCaps asks for the print attributes', () async {
      late http.Request seen;
      final client = MockClient((r) async {
        seen = r;
        return http.Response.bytes(capsResponse(), 200);
      });
      final caps = await getPrinterCaps(printer, client: client);
      expect(caps.urfResolutions, [300, 600]);
      final (_, attrs) = decodeIppResponse(seen.bodyBytes);
      expect(attrs['requested-attributes'],
          containsAll(['document-format-supported', 'media-supported', 'media-default', 'urf-supported']));
      await expectLater(
        getPrinterCaps(printer, client: MockClient((r) async => http.Response.bytes(jobResponse(0x0400), 200))),
        throwsA(isA<IppError>().having((e) => e.status, 'status', 0x0400)),
      );
    });
  });

  test('problemFromReasons', () {
    const table = <(List<String>, PrintProblem?)>[
      ([], null),
      (['none'], null),
      (['toner-low-report', 'media-low-warning'], null),
      (['media-empty-warning'], null), // another tray still has paper
      (['media-empty-error'], PrintProblem.mediaEmpty),
      (['media-empty'], PrintProblem.mediaEmpty),
      (['media-needed-error'], PrintProblem.mediaEmpty),
      (['media-jam-error'], PrintProblem.mediaJam),
      (['door-open-error'], PrintProblem.doorOpen),
      (['cover-open'], PrintProblem.doorOpen),
      (['interlock-open-error'], PrintProblem.doorOpen),
      (['toner-empty-error'], PrintProblem.tonerEmpty),
      (['marker-supply-empty-error'], PrintProblem.tonerEmpty),
      (['toner-empty-warning'], null),
      (['paused'], PrintProblem.paused),
      (['spool-area-full'], PrintProblem.busy),
      (['shutdown'], PrintProblem.other),
      (['something-new-error'], PrintProblem.other),
      (['something-new'], null), // unknown and not an error: no reason to refuse
      (['media-empty-error', 'media-jam-error'], PrintProblem.mediaJam), // jam first
      (['other-error', 'Toner-Empty-Error'], PrintProblem.tonerEmpty),
    ];
    for (final (reasons, expected) in table) {
      expect(problemFromReasons(reasons), expected, reason: reasons.join(','));
    }
  });

  group('printPages', () {
    final pages = [PrintSource.scan(solid(50, 80), 100), const PrintSource.blank()];
    Stream<PrintProgress> run(FakePrinter p, {bool color = true, int copies = 1}) => printPages(printer,
        pageCount: pages.length,
        loadPage: loaderFor(pages),
        media: mediaA4,
        color: color,
        copies: copies,
        jobName: 'Copy',
        client: p.client,
        settle: const Duration(milliseconds: 30),
        pollInterval: const Duration(milliseconds: 10));

    test('URF: one job with all pages, progress i of n', () async {
      final p = FakePrinter();
      final progress = await run(p, color: false, copies: 2).toList();
      expect(progress.where((e) => e.stage == PrintStage.preparing).map((e) => (e.page, e.total)),
          [(1, 2), (2, 2)]);
      expect(progress.map((e) => e.stage), contains(PrintStage.sending));
      expect(progress.last.stage, PrintStage.checking);
      expect(p.jobs, hasLength(1));
      final (attrs, doc) = p.jobs.single;
      final s = strings(attrs);
      expect(s['document-format'], 'image/urf');
      expect(s['print-color-mode'], 'monochrome');
      expect(s['job-name'], 'Copy');
      expect(attrs.firstWhere((a) => a.$3 == 'copies').$4, [0, 0, 0, 2]);
      final decoded = decodeUrf(doc);
      expect(decoded, hasLength(2));
      expect((decoded[0].width, decoded[0].height, decoded[0].numChannels), (2480, 3508, 1));
      // the scan is a 50 x 80 black patch at 100 dpi -> 150 x 240 at the top-left
      expect(bytesOf(decoded[0])[10 * 2480 + 10], 0);
      expect(bytesOf(decoded[0])[300 * 2480 + 300], 255);
      expect(p.infoCalls, greaterThan(1)); // state polled after sending
    });

    test('JPEG fallback: one job per page', () async {
      final p = FakePrinter()..capsOverride = capsResponse(formats: ['application/pdf', 'image/jpeg']);
      await run(p).drain<void>();
      expect(p.jobs, hasLength(2));
      expect(p.jobs.map((j) => strings(j.$1)['document-format']), ['image/jpeg', 'image/jpeg']);
      expect(p.jobs.map((j) => strings(j.$1)['job-name']), ['Copy (1/2)', 'Copy (2/2)']);
      final jpeg = p.jobs.first.$2;
      expect(jpeg.sublist(0, 2), [0xFF, 0xD8]);
      expect(jpeg.sublist(13, 18), [1, 1, 44, 1, 44]); // JFIF density 300 dpi
    });

    test('no supported format', () async {
      final p = FakePrinter()..capsOverride = capsResponse(formats: ['application/pdf']);
      await expectLater(run(p).drain<void>(), throwsA(isA<NoSupportedFormat>()));
      expect(p.jobs, isEmpty);
    });

    test('problem before sending: nothing is sent', () async {
      final p = FakePrinter()..capsOverride = capsResponse(reasons: ['media-empty-error']);
      await expectLater(run(p).drain<void>(),
          throwsA(isA<PrintFailed>().having((e) => e.problem, 'problem', PrintProblem.mediaEmpty)));
      expect(p.jobs, isEmpty);
    });

    test('problem after sending', () async {
      final p = FakePrinter(laterReasons: ['media-jam-error']);
      await expectLater(run(p).drain<void>(),
          throwsA(isA<PrintFailed>().having((e) => e.problem, 'problem', PrintProblem.mediaJam)));
      expect(p.jobs, hasLength(1));
    });

    test('busy printer', () async {
      final p = FakePrinter(jobStatus: ippStatusBusy);
      await expectLater(run(p).drain<void>(),
          throwsA(isA<PrintFailed>().having((e) => e.problem, 'problem', PrintProblem.busy)));
    });

    test('rejected job keeps the IPP status', () async {
      final p = FakePrinter(jobStatus: 0x040B);
      await expectLater(run(p).drain<void>(), throwsA(isA<IppError>().having((e) => e.status, 's', 0x040B)));
    });

    test('copy sources are scans', () {
      final s = copySources([ScannedPage(solid(4, 4), 200)]);
      expect(s.single, isA<ScanPrintSource>().having((e) => e.dpi, 'dpi', 200));
    });
  });
}

img.Image solid(int w, int h) {
  final out = blankImage(w, h, 3);
  bytesOf(out).fillRange(0, w * h * 3, 0);
  return out;
}
