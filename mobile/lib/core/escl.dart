import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;
import 'package:xml/xml.dart';

import 'lan.dart';
import 'pixels.dart';

// Minimal eSCL (AirScan / Mopria scan) client: plain HTTP + XML.

const nsScan = 'http://schemas.hp.com/imaging/escl/2011/05/03';
const nsPwg = 'http://www.pwg.org/schemas/2010/12/sm';

/// A4 in 1/300 inch (the unit of eSCL scan regions).
const a4Width = 2480;
const a4Height = 3507;

/// Resolutions the app offers.
const scanDpiChoices = [100, 150, 200, 300];

/// Capabilities of one input source. Sizes in 1/300 inch.
class SourceCaps {
  const SourceCaps({
    required this.resolutions,
    required this.colorModes,
    required this.maxWidth,
    required this.maxHeight,
  });

  final List<int> resolutions; // sorted ascending
  final List<String> colorModes; // eSCL names: RGB24, Grayscale8, BlackAndWhite1
  final int maxWidth;
  final int maxHeight;

  /// Modes the app can scan with this source (B/W is scanned in grey, see [buildScanSettings]).
  List<ColorMode> get modes => [
        if (colorModes.contains('RGB24')) ColorMode.color,
        if (colorModes.contains('Grayscale8')) ColorMode.gray,
        if (colorModes.contains('Grayscale8')) ColorMode.bw,
      ];

  /// The app's resolutions (100/150/200/300) this source supports.
  List<int> get dpiChoices {
    final ok = scanDpiChoices.where(resolutions.contains).toList();
    return ok.isNotEmpty ? ok : [nearestResolution(300)];
  }

  /// The supported resolution closest to [dpi] (the higher one on a tie).
  int nearestResolution(int dpi) {
    if (resolutions.isEmpty) return dpi;
    var best = resolutions.first;
    for (final r in resolutions) {
      final d = (r - dpi).abs(), bd = (best - dpi).abs();
      if (d < bd || (d == bd && r > best)) best = r;
    }
    return best;
  }
}

class ScannerCaps {
  const ScannerCaps({this.makeAndModel = '', this.platen, this.adf, this.version = '2.0'});

  final String makeAndModel;
  final SourceCaps? platen;
  final SourceCaps? adf;
  final String version; // eSCL version, echoed in ScanSettings

  List<ScanSource> get sources => [
        if (platen != null) ScanSource.platen,
        if (adf != null) ScanSource.feeder,
      ];

  SourceCaps? source(ScanSource s) => s == ScanSource.platen ? platen : adf;
}

enum ScanSource { platen, feeder }

enum ColorMode { color, gray, bw }

class ScanSettings {
  ScanSettings({this.source = ScanSource.platen, this.mode = ColorMode.color, this.dpi = 300});

  ScanSource source;
  ColorMode mode;
  int dpi; // 100..300
}

class ScannedPage {
  const ScannedPage(this.image, this.dpi);

  final img.Image image;
  final int dpi;
}

class ScannerError implements Exception {
  const ScannerError([this.message = '']);

  final String message;

  @override
  String toString() => message.isEmpty ? '$runtimeType' : '$runtimeType: $message';
}

class ScannerBusy extends ScannerError {
  const ScannerBusy([super.message = 'The scanner is busy']);
}

class FeederEmpty extends ScannerError {
  const FeederEmpty([super.message = 'The document feeder is empty']);
}

class ScanCancelled extends ScannerError {
  const ScanCancelled([super.message = 'Scan cancelled']);
}

class CancelToken {
  final _done = Completer<void>();

  void cancel() {
    if (!_done.isCompleted) _done.complete();
  }

  bool get isCancelled => _done.isCompleted;

  /// Completes when [cancel] is called.
  Future<void> get whenCancelled => _done.future;
}

// -- pure helpers ------------------------------------------------------------

Iterable<XmlElement> _all(XmlNode node, String local) =>
    node.descendants.whereType<XmlElement>().where((e) => e.name.local == local);

XmlElement? _child(XmlNode node, String local) =>
    node.children.whereType<XmlElement>().where((e) => e.name.local == local).firstOrNull;

String _text(XmlElement? e, [String fallback = '']) {
  final t = e?.innerText.trim() ?? '';
  return t.isEmpty ? fallback : t;
}

XmlElement _root(String xml) {
  try {
    return XmlDocument.parse(xml).rootElement;
  } on XmlException catch (e) {
    throw ScannerError('Invalid XML from the scanner: ${e.message}');
  }
}

/// Parses eSCL ScannerCapabilities. Element names are matched without their
/// namespace prefix, as some firmwares use different prefixes.
ScannerCaps parseCapabilities(String xml) {
  final root = _root(xml);

  SourceCaps? source(String outer, String inner) {
    final o = _all(root, outer).firstOrNull;
    final node = o == null ? null : _all(o, inner).firstOrNull;
    if (node == null) return null;
    final res = <int>{
      for (final r in _all(node, 'DiscreteResolution'))
        ?int.tryParse(_text(_child(r, 'XResolution'))),
    }.toList()
      ..sort();
    final modes = <String>{
      for (final m in _all(node, 'ColorMode')) if (_text(m).isNotEmpty) _text(m),
    }.toList();
    return SourceCaps(
      resolutions: res.isEmpty ? [300] : res,
      colorModes: modes.isEmpty ? ['RGB24'] : modes,
      maxWidth: int.tryParse(_text(_child(node, 'MaxWidth'))) ?? 2550,
      maxHeight: int.tryParse(_text(_child(node, 'MaxHeight'))) ?? 3507,
    );
  }

  return ScannerCaps(
    makeAndModel: _text(_all(root, 'MakeAndModel').firstOrNull),
    version: _text(_child(root, 'Version'), '2.0'),
    platen: source('Platen', 'PlatenInputCaps'),
    adf: source('Adf', 'AdfSimplexInputCaps'),
  );
}

/// The scanner state from eSCL ScannerStatus, e.g. "Idle" or "Processing".
String parseScannerState(String xml) =>
    _text(_child(_root(xml), 'State') ?? _all(_root(xml), 'State').firstOrNull, 'Unknown');

/// The feeder state from eSCL ScannerStatus ("ScannerAdfLoaded", "ScannerAdfEmpty", ...),
/// or "" when the scanner does not report it.
String parseAdfState(String xml) => _text(_all(_root(xml), 'AdfState').firstOrNull);

String _esclColorMode(ColorMode m) => switch (m) {
      ColorMode.color => 'RGB24',
      // 1-bit JPEG does not exist; many devices (e.g. HP 178/179) fail the job.
      // Scan in grey and threshold on the phone instead.
      ColorMode.gray || ColorMode.bw => 'Grayscale8',
    };

/// The resolution actually requested for [s] (nearest one the source supports).
int effectiveDpi(ScanSettings s, ScannerCaps caps) =>
    caps.source(s.source)?.nearestResolution(s.dpi) ?? s.dpi;

/// eSCL ScanSettings XML for an A4 page (clipped to the source's maximum area).
String buildScanSettings(ScanSettings s, ScannerCaps caps) {
  final src = caps.source(s.source);
  final width = src == null ? a4Width : (src.maxWidth < a4Width ? src.maxWidth : a4Width);
  final height = src == null ? a4Height : (src.maxHeight < a4Height ? src.maxHeight : a4Height);
  final dpi = effectiveDpi(s, caps);
  final input = s.source == ScanSource.platen ? 'Platen' : 'Feeder';
  final version = caps.version.isEmpty ? '2.0' : caps.version;
  return '''<?xml version="1.0" encoding="UTF-8"?>
<scan:ScanSettings xmlns:scan="$nsScan" xmlns:pwg="$nsPwg">
  <pwg:Version>$version</pwg:Version>
  <scan:Intent>Document</scan:Intent>
  <pwg:ScanRegions>
    <pwg:ScanRegion>
      <pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>
      <pwg:XOffset>0</pwg:XOffset>
      <pwg:YOffset>0</pwg:YOffset>
      <pwg:Width>$width</pwg:Width>
      <pwg:Height>$height</pwg:Height>
    </pwg:ScanRegion>
  </pwg:ScanRegions>
  <pwg:InputSource>$input</pwg:InputSource>
  <scan:ColorMode>${_esclColorMode(s.mode)}</scan:ColorMode>
  <pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>
  <scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>
  <scan:XResolution>$dpi</scan:XResolution>
  <scan:YResolution>$dpi</scan:YResolution>
</scan:ScanSettings>
''';
}

/// Decodes one scanned document into an 8-bit page in the requested mode
/// (B/W is thresholded to pure black and white).
ScannedPage decodePage(Uint8List data, ColorMode mode, int dpi) {
  final decoded = img.decodeImage(data);
  if (decoded == null) throw const ScannerError('The scanner sent an unreadable image');
  final page = switch (mode) {
    ColorMode.color => toRgb(decoded),
    ColorMode.gray => toGray(decoded),
    ColorMode.bw => threshold(decoded),
  };
  stripMetadata(page);
  return ScannedPage(page, dpi);
}

// Kept top-level so the isolate closure captures only these arguments.
Future<ScannedPage> _decodeInIsolate(Uint8List data, ColorMode mode, int dpi) =>
    Isolate.run(() => decodePage(data, mode, dpi));

// -- client ------------------------------------------------------------------

class EsclClient {
  /// [base] like http://192.168.1.20/eSCL/. [busyWait]: how long a busy scanner
  /// (HTTP 503/409 on job creation) is retried before [ScannerBusy];
  /// [pageWait]: how long NextDocument may answer 503 ("still scanning").
  EsclClient(
    Uri base, {
    http.Client? client,
    this.timeout = const Duration(seconds: 20),
    this.busyWait = const Duration(seconds: 20),
    this.pageWait = const Duration(minutes: 3),
    this.retryDelay = const Duration(seconds: 1),
  })  : base = base.path.endsWith('/') ? base : base.replace(path: '${base.path}/'),
        _client = client ?? http.Client(),
        _ownsClient = client == null;

  final Uri base;
  final Duration timeout;
  final Duration busyWait;
  final Duration pageWait;
  final Duration retryDelay;
  final http.Client _client;
  final bool _ownsClient;
  ScannerCaps? _caps;

  /// Releases the HTTP client if this instance created it.
  void close() {
    if (_ownsClient) _client.close();
  }

  Future<http.Response> _send(
    String method,
    Uri uri, {
    String? body,
    Duration? timeout,
    CancelToken? cancel,
  }) async {
    checkLocal(uri);
    final req = http.Request(method, uri);
    if (body != null) {
      req.headers['Content-Type'] = 'text/xml';
      req.body = body;
    }
    final future = _client
        .send(req)
        .then(http.Response.fromStream)
        .timeout(timeout ?? this.timeout);
    try {
      return await _race(future, cancel);
    } on TimeoutException {
      throw const ScannerError('The scanner did not answer in time');
    } on http.ClientException catch (e) {
      throw ScannerError('Cannot reach the scanner: ${e.message}');
    }
  }

  Future<ScannerCaps> capabilities() async {
    if (_caps != null) return _caps!;
    final r = await _send('GET', base.resolve('ScannerCapabilities'));
    if (r.statusCode != 200) {
      throw ScannerError('ScannerCapabilities failed (HTTP ${r.statusCode})');
    }
    return _caps = parseCapabilities(r.body);
  }

  Future<String> _statusXml() async {
    final r = await _send('GET', base.resolve('ScannerStatus'));
    if (r.statusCode != 200) throw ScannerError('ScannerStatus failed (HTTP ${r.statusCode})');
    return r.body;
  }

  /// ScannerStatus state, e.g. "Idle".
  Future<String> state() async => parseScannerState(await _statusXml());

  /// Yields pages as they arrive. Feeder: until 404/410 (no more pages). B/W: scans
  /// Grayscale8 and thresholds locally (the HP rejects 1-bit JPEG with 410). Cancel via
  /// [cancel]: the job is deleted on the printer and [ScanCancelled] is thrown.
  Stream<ScannedPage> scan(ScanSettings s, {CancelToken? cancel}) async* {
    checkLocal(base);
    final caps = await capabilities();
    final src = caps.source(s.source);
    if (src == null) {
      throw ScannerError(s.source == ScanSource.feeder
          ? 'This scanner has no document feeder'
          : 'This scanner has no glass');
    }
    if (s.source == ScanSource.feeder) {
      String adf = '';
      try {
        adf = parseAdfState(await _statusXml());
      } on ScannerError {
        // Status is only a pre-check; the job itself tells us too.
      }
      if (adf.isNotEmpty && adf != 'ScannerAdfLoaded') throw const FeederEmpty();
    }
    _check(cancel);

    final dpi = effectiveDpi(s, caps);
    final job = await _createJob(buildScanSettings(s, caps), cancel);
    final next = job.replace(
        path: '${job.path.endsWith('/') ? job.path.substring(0, job.path.length - 1) : job.path}'
            '/NextDocument');
    var pages = 0;
    var done = false;
    try {
      while (true) {
        _check(cancel);
        final data = await _nextDocument(next, cancel);
        if (data == null) break;
        final page = await _race(_decodeInIsolate(data, s.mode, dpi), cancel);
        pages++;
        yield page;
      }
      done = true;
    } finally {
      // Cancelled, failed or the listener went away: free the scanner.
      if (!done) await _deleteJob(job);
    }
    if (pages == 0) {
      if (s.source == ScanSource.feeder) throw const FeederEmpty();
      throw const ScannerError('The scanner returned no pages');
    }
  }

  Future<Uri> _createJob(String body, CancelToken? cancel) async {
    final deadline = DateTime.now().add(busyWait);
    while (true) {
      final r = await _send('POST', base.resolve('ScanJobs'), body: body, cancel: cancel);
      if (r.statusCode == 201 || r.statusCode == 200) {
        final location = r.headers['location'];
        if (location == null || location.isEmpty) {
          throw const ScannerError('The scanner did not return a job location');
        }
        final job = base.resolve(location);
        checkLocal(job);
        return job;
      }
      if (r.statusCode == 503 || r.statusCode == 409) {
        if (DateTime.now().isBefore(deadline)) {
          await _race(Future<void>.delayed(retryDelay), cancel);
          continue;
        }
        throw const ScannerBusy();
      }
      throw ScannerError('The scanner rejected the scan job (HTTP ${r.statusCode})');
    }
  }

  /// The next page, or null when there are no more (404/410).
  Future<Uint8List?> _nextDocument(Uri url, CancelToken? cancel) async {
    final deadline = DateTime.now().add(pageWait);
    while (true) {
      _check(cancel);
      final r = await _send('GET', url, timeout: const Duration(minutes: 2), cancel: cancel);
      if (r.statusCode == 200) return r.bodyBytes;
      if (r.statusCode == 404 || r.statusCode == 410) return null;
      if (r.statusCode == 503 && DateTime.now().isBefore(deadline)) {
        await _race(Future<void>.delayed(retryDelay ~/ 2), cancel);
        continue;
      }
      throw ScannerError('Error while fetching the scan (HTTP ${r.statusCode})');
    }
  }

  Future<void> _deleteJob(Uri job) async {
    try {
      await _send('DELETE', job, timeout: const Duration(seconds: 5));
    } catch (_) {
      // Best effort: the job times out on the device anyway.
    }
  }
}

void _check(CancelToken? cancel) {
  if (cancel != null && cancel.isCancelled) throw const ScanCancelled();
}

/// Completes with [f], or throws [ScanCancelled] as soon as [cancel] fires.
Future<T> _race<T>(Future<T> f, CancelToken? cancel) {
  if (cancel == null) return f;
  _check(cancel);
  return Future.any<T>([
    f,
    cancel.whenCancelled.then<T>((_) => throw const ScanCancelled()),
  ]);
}
