import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'escl.dart' show ScannedPage;
import 'export.dart' show encodeJpeg;
import 'ipp.dart';
import 'print_layout.dart';
import 'urf.dart';

// High-level printing: lay out pages, encode them (Apple raster as one job, JPEG page
// by page as a fallback) and send them to the printer, watching its state.

enum PrintStage {
  /// Laying out and encoding page [PrintProgress.page] of [PrintProgress.total].
  preparing,

  /// Sending to the printer (JPEG: page [PrintProgress.page]; URF: the whole job).
  sending,

  /// Sent; watching the printer for a few seconds (paper, jam, door …).
  checking,
}

class PrintProgress {
  const PrintProgress(this.stage, this.page, this.total);

  final PrintStage stage;
  final int page; // 1-based
  final int total;

  @override
  String toString() => 'PrintProgress($stage, $page/$total)';
}

/// The printer reported a problem that stops printing.
class PrintFailed implements Exception {
  const PrintFailed(this.problem);

  final PrintProblem problem;

  @override
  String toString() => 'PrintFailed: ${problem.name}';
}

/// The printer accepts neither Apple raster (URF) nor JPEG.
class NoSupportedFormat implements Exception {
  const NoSupportedFormat(this.formats);

  final List<String> formats;

  @override
  String toString() => 'NoSupportedFormat: ${formats.join(', ')}';
}

/// Loads page [index] (0-based) of a print run, e.g. renders a PDF page on demand.
typedef PrintPageLoader = Future<PrintSource> Function(int index);

/// A loader over pages that are already in memory.
PrintPageLoader loaderFor(List<PrintSource> pages) => (i) async => pages[i];

/// Print sources for a copy: scans at 100 %, anchored top-left.
List<PrintSource> copySources(List<ScannedPage> pages) =>
    [for (final p in pages) PrintSource.scan(p.image, p.dpi)];

/// Manual duplex like the Windows app: fronts = 1st, 3rd, …; backs = 2nd, 4th, …
/// plus a blank back (null) when the count is odd, in reverse order (the printed
/// stack goes back into the tray as it comes out).
(List<int>, List<int?>) manualDuplexPlan(List<int> pages) {
  final fronts = [for (var i = 0; i < pages.length; i += 2) pages[i]];
  final backs = <int?>[for (var i = 1; i < pages.length; i += 2) pages[i]];
  if (backs.length < fronts.length) backs.add(null);
  return (fronts, backs.reversed.toList());
}

/// Resolution for URF pages: 300 dpi when supported (or unknown), else the closest
/// supported one at or below 300, else the lowest.
int urfDpiFor(PrinterCaps? caps) {
  final rs = caps?.urfResolutions ?? const <int>[];
  if (rs.isEmpty || rs.contains(printDpi)) return printDpi;
  final below = rs.where((r) => r <= printDpi);
  return below.isNotEmpty ? below.reduce((a, b) => a > b ? a : b) : rs.reduce((a, b) => a < b ? a : b);
}

/// Prints [pageCount] pages loaded with [loadPage] on the printer at [ippUri].
///
/// Asks the printer for its capabilities, refuses with [PrintFailed] when it already
/// reports a blocking problem, then sends one URF job (or one JPEG job per page if the
/// printer has no URF), and finally watches printer-state-reasons for [settle].
/// Errors: [PrintFailed], [NoSupportedFormat], [IppError], NotLocalNetwork.
/// Heavy work (layout, encoding) runs in a background isolate.
Stream<PrintProgress> printPages(
  Uri ippUri, {
  required int pageCount,
  required PrintPageLoader loadPage,
  required String media,
  required bool color,
  int copies = 1,
  String jobName = 'Glassbed',
  http.Client? client,
  Duration settle = const Duration(seconds: 4),
  Duration pollInterval = const Duration(seconds: 1),
}) async* {
  if (pageCount <= 0) return;

  PrinterCaps? caps;
  try {
    caps = await getPrinterCaps(ippUri, client: client);
  } on IppError {
    caps = null; // older printers may not answer – try URF like the Windows app
  }
  if (caps != null) {
    final p = problemFromReasons(caps.stateReasons);
    if (p != null) throw PrintFailed(p);
  }
  final useColor = color && (caps?.colorSupported ?? true);
  final formats = caps?.documentFormats ?? const <String>[];
  final urf = formats.isEmpty || caps!.supportsUrf;
  final jpeg = formats.contains('image/jpeg');
  if (!urf && !jpeg) throw NoSupportedFormat(formats);

  Future<void> send(Uint8List doc, String format, String name) async {
    try {
      await printJob(ippUri, doc,
          format: format,
          jobName: name,
          copies: copies,
          media: media,
          color: useColor,
          client: client);
    } on IppError catch (e) {
      if (e.status == ippStatusBusy || e.status == 0x0505) {
        throw const PrintFailed(PrintProblem.busy);
      }
      rethrow;
    }
  }

  var sent = false;
  if (urf) {
    final dpi = urfDpiFor(caps);
    // Bit depth the printer takes: grey pages as 24-bit only if it lacks W8, and the
    // other way round.
    final urfColor = useColor ? (caps?.urfColor ?? true) : !(caps?.urfGray ?? true);
    final doc = BytesBuilder(copy: false)..add(urfFileHeader(pageCount));
    for (var i = 0; i < pageCount; i++) {
      yield PrintProgress(PrintStage.preparing, i + 1, pageCount);
      final src = await loadPage(i);
      doc.add(await _urfInIsolate(src, media, useColor, dpi, urfColor));
    }
    yield PrintProgress(PrintStage.sending, pageCount, pageCount);
    try {
      await send(doc.takeBytes(), 'image/urf', jobName);
      sent = true;
    } on IppError catch (e) {
      // Unknown formats and the printer refuses URF: retry as JPEG below.
      if (!(e.status == ippStatusDocumentFormatNotSupported && formats.isEmpty)) rethrow;
    }
  }

  if (!sent) {
    for (var i = 0; i < pageCount; i++) {
      yield PrintProgress(PrintStage.preparing, i + 1, pageCount);
      final src = await loadPage(i);
      final data = await _jpegInIsolate(src, media, useColor);
      yield PrintProgress(PrintStage.sending, i + 1, pageCount);
      await send(data, 'image/jpeg', pageCount == 1 ? jobName : '$jobName (${i + 1}/$pageCount)');
    }
  }

  yield PrintProgress(PrintStage.checking, pageCount, pageCount);
  final watch = Stopwatch()..start();
  while (watch.elapsed < settle) {
    await Future<void>.delayed(pollInterval);
    PrinterInfo info;
    try {
      info = await getPrinterInfo(ippUri, client: client);
    } on IppError {
      continue; // a busy printer may not answer; the job is already accepted
    }
    final p = problemFromReasons(info.stateReasons);
    if (p != null) throw PrintFailed(p);
  }
}

Uint8List _urfPage(PrintSource src, String media, bool color, int dpi, bool urfColor) =>
    encodeUrfPage(layoutForPrint(src, media, color, dpi: dpi), dpi: dpi, color: urfColor);

Uint8List _jpegPage(PrintSource src, String media, bool color) =>
    jpegWithDpi(encodeJpeg(layoutForPrint(src, media, color), 92), printDpi);

/// Sets the JFIF density of [jpeg] to [dpi] (the encoder writes 1:1 aspect only), so
/// the printer knows the physical size. Leaves anything without a JFIF header alone.
Uint8List jpegWithDpi(Uint8List jpeg, int dpi) {
  const jfif = [0xFF, 0xD8, 0xFF, 0xE0, null, null, 0x4A, 0x46, 0x49, 0x46, 0x00];
  if (jpeg.length < 18) return jpeg;
  for (var i = 0; i < jfif.length; i++) {
    if (jfif[i] != null && jpeg[i] != jfif[i]) return jpeg;
  }
  jpeg[13] = 1; // units: dots per inch
  jpeg[14] = dpi >> 8;
  jpeg[15] = dpi & 0xff;
  jpeg[16] = dpi >> 8;
  jpeg[17] = dpi & 0xff;
  return jpeg;
}

// Top-level so the isolate closures capture only these arguments (not the stream state
// or the http client).
Future<Uint8List> _urfInIsolate(PrintSource src, String media, bool color, int dpi, bool urfColor) =>
    Isolate.run(() => _urfPage(src, media, color, dpi, urfColor));

Future<Uint8List> _jpegInIsolate(PrintSource src, String media, bool color) =>
    Isolate.run(() => _jpegPage(src, media, color));
