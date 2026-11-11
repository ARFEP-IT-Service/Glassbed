import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'lan.dart';

// Minimal IPP/2.0 (RFC 8011) over HTTP: Get-Printer-Attributes for status, toner and
// capabilities, Print-Job for sending a document.

const ippPrintJob = 0x0002;
const ippGetPrinterAttributes = 0x000B;

const _groupOperation = 0x01;
const _groupJob = 0x02;
const _endOfAttributes = 0x03;

const tagInteger = 0x21;
const tagBoolean = 0x22;
const tagEnum = 0x23;
const tagRange = 0x33;
const tagText = 0x41;
const tagName = 0x42;
const tagKeyword = 0x44;
const tagUri = 0x45;
const tagCharset = 0x47;
const tagLanguage = 0x48;
const tagMimeType = 0x49;

// Status codes the app reacts to.
const ippStatusDocumentFormatNotSupported = 0x040A;
const ippStatusNotAcceptingJobs = 0x0506;
const ippStatusBusy = 0x0507;

const _printerStates = {3: 'idle', 4: 'processing', 5: 'stopped'};

const _statusNames = {
  0x0400: 'client-error-bad-request',
  0x0401: 'client-error-forbidden',
  0x0402: 'client-error-not-authenticated',
  0x0403: 'client-error-not-authorized',
  0x0404: 'client-error-not-possible',
  0x0405: 'client-error-timeout',
  0x0406: 'client-error-not-found',
  0x0407: 'client-error-gone',
  0x0408: 'client-error-request-entity-too-large',
  0x0409: 'client-error-request-value-too-long',
  0x040A: 'client-error-document-format-not-supported',
  0x040B: 'client-error-attributes-or-values-not-supported',
  0x040C: 'client-error-uri-scheme-not-supported',
  0x040D: 'client-error-charset-not-supported',
  0x040E: 'client-error-conflicting-attributes',
  0x040F: 'client-error-compression-not-supported',
  0x0410: 'client-error-compression-error',
  0x0411: 'client-error-document-format-error',
  0x0412: 'client-error-document-access-error',
  0x0500: 'server-error-internal-error',
  0x0501: 'server-error-operation-not-supported',
  0x0502: 'server-error-service-unavailable',
  0x0503: 'server-error-version-not-supported',
  0x0504: 'server-error-device-error',
  0x0505: 'server-error-temporary-error',
  0x0506: 'server-error-not-accepting-jobs',
  0x0507: 'server-error-busy',
  0x0508: 'server-error-job-canceled',
  0x0509: 'server-error-multiple-document-jobs-not-supported',
};

/// Name of an IPP status code, e.g. 0x040A -> "client-error-document-format-not-supported".
String ippStatusName(int status) =>
    _statusNames[status] ?? '0x${status.toRadixString(16).padLeft(4, '0')}';

/// Attributes the app asks for in [getPrinterInfo] (keeps the answer small).
const _infoAttributes = [
  'printer-state',
  'printer-state-reasons',
  'printer-make-and-model',
  'marker-names',
  'marker-levels',
  'marker-colors',
];

/// Attributes the app asks for in [getPrinterCaps].
const _capsAttributes = [
  'printer-state',
  'printer-state-reasons',
  'printer-make-and-model',
  'document-format-supported',
  'media-supported',
  'media-default',
  'color-supported',
  'print-color-mode-supported',
  'sides-supported',
  'urf-supported',
];

class IppError implements Exception {
  const IppError(this.message, {this.status});

  final String message;

  /// IPP status code of the printer's answer, null for transport errors.
  final int? status;

  @override
  String toString() => 'IppError: $message';
}

/// A toner/ink supply. [level] 0..100, -1 = unknown. [color] like "#000000".
class Marker {
  const Marker({required this.name, required this.color, required this.level});

  final String name;
  final String color;
  final int level;

  @override
  String toString() => 'Marker($name, $color, $level)';
}

class PrinterInfo {
  const PrinterInfo({
    required this.state,
    required this.stateReasons,
    required this.makeAndModel,
    required this.markers,
  });

  final String state; // idle, processing, stopped, unknown
  final List<String> stateReasons; // without "none"
  final String makeAndModel;
  final List<Marker> markers;
}

/// What the printer can print, from Get-Printer-Attributes.
class PrinterCaps {
  const PrinterCaps({
    required this.state,
    required this.stateReasons,
    this.makeAndModel = '',
    this.documentFormats = const [],
    this.mediaSupported = const [],
    this.mediaDefault,
    this.colorSupported = true,
    this.colorModes = const [],
    this.sides = const [],
    this.urfSupported = const [],
    this.urfResolutions = const [],
  });

  final String state; // idle, processing, stopped, unknown
  final List<String> stateReasons; // without "none"
  final String makeAndModel;
  final List<String> documentFormats; // e.g. image/urf, image/jpeg, application/pdf
  final List<String> mediaSupported; // e.g. iso_a4_210x297mm
  final String? mediaDefault;
  final bool colorSupported;
  final List<String> colorModes; // print-color-mode-supported
  final List<String> sides; // sides-supported
  final List<String> urfSupported; // raw urf-supported, e.g. V1.4, W8, SRGB24, RS300-600
  final List<int> urfResolutions; // from "RS300" / "RS300-600"

  bool get supportsUrf => documentFormats.contains('image/urf');
  bool get supportsJpeg => documentFormats.contains('image/jpeg');

  /// URF with 8-bit grey pages ("W8"); unknown (empty list) counts as yes.
  bool get urfGray => urfSupported.isEmpty || urfSupported.contains('W8');

  /// URF with 24-bit sRGB pages ("SRGB24"); unknown (empty list) counts as yes.
  bool get urfColor => urfSupported.isEmpty || urfSupported.contains('SRGB24');
}

/// Reasons a printer cannot print right now.
enum PrintProblem { mediaEmpty, mediaJam, doorOpen, tonerEmpty, paused, busy, other }

const _reasonProblems = {
  'media-jam': PrintProblem.mediaJam,
  'media-empty': PrintProblem.mediaEmpty,
  'media-needed': PrintProblem.mediaEmpty,
  'door-open': PrintProblem.doorOpen,
  'cover-open': PrintProblem.doorOpen,
  'interlock-open': PrintProblem.doorOpen,
  'toner-empty': PrintProblem.tonerEmpty,
  'marker-supply-empty': PrintProblem.tonerEmpty,
  'paused': PrintProblem.paused,
  'moving-to-paused': PrintProblem.paused,
  'spool-area-full': PrintProblem.busy,
  'shutdown': PrintProblem.other,
  'stopping': PrintProblem.other,
  'offline': PrintProblem.other,
  'fuser-over-temp': PrintProblem.other,
  'fuser-under-temp': PrintProblem.other,
  'input-tray-missing': PrintProblem.other,
  'output-tray-missing': PrintProblem.other,
  'output-area-full': PrintProblem.other,
  'marker-waste-full': PrintProblem.other,
};

/// Which problem to report when there are several (fix the jam before loading paper).
const _priority = [
  PrintProblem.mediaJam,
  PrintProblem.doorOpen,
  PrintProblem.mediaEmpty,
  PrintProblem.tonerEmpty,
  PrintProblem.paused,
  PrintProblem.busy,
  PrintProblem.other,
];

/// The most important blocking problem in printer-state-reasons, or null.
///
/// "none" and reasons ending in "-report" or "-warning" are ignored (e.g. toner low,
/// an empty second tray). "-error" is stripped before matching. Unknown reasons count
/// as [PrintProblem.other] only when they carry the "-error" suffix.
PrintProblem? problemFromReasons(List<String> reasons) {
  PrintProblem? best;
  for (final raw in reasons) {
    final r = raw.trim().toLowerCase();
    if (r.isEmpty || r == 'none' || r.endsWith('-report') || r.endsWith('-warning')) continue;
    final isError = r.endsWith('-error');
    final base = isError ? r.substring(0, r.length - '-error'.length) : r;
    final p = _reasonProblems[base] ?? (isError ? PrintProblem.other : null);
    if (p != null && (best == null || _priority.indexOf(p) < _priority.indexOf(best))) best = p;
  }
  return best;
}

class _Writer {
  final _b = BytesBuilder();

  void u8(int v) => _b.addByte(v & 0xff);
  void u16(int v) => _b
    ..addByte((v >> 8) & 0xff)
    ..addByte(v & 0xff);
  void u32(int v) {
    u16((v >> 16) & 0xffff);
    u16(v & 0xffff);
  }

  void attr(int tag, String name, List<int> value) {
    final n = ascii.encode(name);
    u8(tag);
    u16(n.length);
    _b.add(n);
    u16(value.length);
    _b.add(value);
  }

  void string(int tag, String name, String value) => attr(tag, name, utf8.encode(value));

  void integer(int tag, String name, int value) =>
      attr(tag, name, (ByteData(4)..setInt32(0, value)).buffer.asUint8List());

  /// The common start of every request: header, charset, language, printer-uri.
  void header(int operation, int requestId, String printerUri) {
    this
      ..u8(2) // version 2.0
      ..u8(0)
      ..u16(operation)
      ..u32(requestId)
      ..u8(_groupOperation)
      ..string(tagCharset, 'attributes-charset', 'utf-8')
      ..string(tagLanguage, 'attributes-natural-language', 'en')
      ..string(tagUri, 'printer-uri', printerUri);
  }

  Uint8List take() => _b.takeBytes();
}

var _nextRequestId = 1;

/// Encodes a Get-Printer-Attributes request for [printerUri] (ipp://...).
Uint8List encodeGetPrinterAttributes(String printerUri,
    {int requestId = 1, List<String> requested = _infoAttributes}) {
  final w = _Writer()..header(ippGetPrinterAttributes, requestId, printerUri);
  for (var i = 0; i < requested.length; i++) {
    // Additional values of a 1setOf have an empty name.
    w.string(tagKeyword, i == 0 ? 'requested-attributes' : '', requested[i]);
  }
  w.u8(_endOfAttributes);
  return w.take();
}

/// Encodes the attribute part of a Print-Job request; the document follows directly.
Uint8List encodePrintJob(
  String printerUri, {
  required String format,
  required String jobName,
  required String media,
  required bool color,
  int copies = 1,
  int requestId = 1,
}) {
  final name = jobName.length > 200 ? jobName.substring(0, 200) : jobName;
  final w = _Writer()
    ..header(ippPrintJob, requestId, printerUri)
    ..string(tagName, 'requesting-user-name', 'Glassbed')
    ..string(tagName, 'job-name', name)
    ..string(tagMimeType, 'document-format', format)
    ..u8(_groupJob)
    ..integer(tagInteger, 'copies', copies < 1 ? 1 : copies)
    ..string(tagKeyword, 'media', media)
    ..string(tagKeyword, 'print-color-mode', color ? 'color' : 'monochrome')
    ..string(tagKeyword, 'sides', 'one-sided')
    ..u8(_endOfAttributes);
  return w.take();
}

/// Decodes an IPP response: (status code, attributes). Groups are flattened.
(int, Map<String, List<Object>>) decodeIppResponse(Uint8List data) {
  if (data.length < 8) throw const IppError('Truncated IPP response');
  final bd = ByteData.sublistView(data);
  final status = bd.getUint16(2);
  final attrs = <String, List<Object>>{};
  var i = 8;
  String? name;
  while (i < data.length) {
    final tag = data[i++];
    if (tag == _endOfAttributes) break;
    if (tag < 0x10) continue; // group delimiter
    if (i + 2 > data.length) throw const IppError('Truncated IPP attribute');
    final nlen = bd.getUint16(i);
    i += 2;
    if (i + nlen + 2 > data.length) throw const IppError('Truncated IPP attribute');
    if (nlen > 0) {
      name = utf8.decode(data.sublist(i, i + nlen), allowMalformed: true);
      attrs[name] = [];
    }
    i += nlen;
    final vlen = bd.getUint16(i);
    i += 2;
    if (i + vlen > data.length) throw const IppError('Truncated IPP value');
    final raw = Uint8List.sublistView(data, i, i + vlen);
    i += vlen;
    final Object value;
    if ((tag == tagInteger || tag == tagEnum) && vlen == 4) {
      value = bd.getInt32(i - 4);
    } else if (tag == tagBoolean) {
      value = vlen > 0 && raw[0] == 1;
    } else if (tag == tagRange && vlen == 8) {
      value = (bd.getInt32(i - 8), bd.getInt32(i - 4));
    } else if ((tag >= 0x40 && tag <= 0x4F) || tag == 0x35 || tag == 0x36) {
      value = utf8.decode(raw, allowMalformed: true);
    } else {
      value = Uint8List.fromList(raw);
    }
    if (name != null) attrs[name]!.add(value);
  }
  return (status, attrs);
}

List<T> _list<T>(Map<String, List<Object>> a, String key) =>
    (a[key] ?? const []).whereType<T>().toList();

String _state(Map<String, List<Object>> a) {
  final s = _list<int>(a, 'printer-state');
  return s.isEmpty ? 'unknown' : (_printerStates[s.first] ?? 'unknown');
}

List<String> _reasons(Map<String, List<Object>> a) =>
    _list<String>(a, 'printer-state-reasons').where((r) => r != 'none').toList();

String _first(Map<String, List<Object>> a, String key) {
  final v = _list<String>(a, key);
  return v.isEmpty ? '' : v.first;
}

Map<String, List<Object>> _checked(Uint8List body, String operation) {
  final (status, a) = decodeIppResponse(body);
  if (status >= 0x0100) {
    final msg = _first(a, 'status-message');
    throw IppError('$operation failed (${ippStatusName(status)})${msg.isEmpty ? '' : ' $msg'}',
        status: status);
  }
  return a;
}

/// Builds [PrinterInfo] from a Get-Printer-Attributes response body.
PrinterInfo parsePrinterInfo(Uint8List body) {
  final a = _checked(body, 'Get-Printer-Attributes');
  final names = _list<String>(a, 'marker-names');
  final levels = _list<int>(a, 'marker-levels');
  final colors = _list<String>(a, 'marker-colors');
  return PrinterInfo(
    state: _state(a),
    stateReasons: _reasons(a),
    makeAndModel: _first(a, 'printer-make-and-model'),
    markers: [
      for (var k = 0; k < names.length; k++)
        Marker(
          // HP appends the serial number: "Black Cartridge_S/N_..." – not needed.
          name: names[k].split('_S/N_').first.trim(),
          level: k < levels.length ? levels[k] : -1,
          color: k < colors.length ? colors[k] : '#888888',
        ),
    ],
  );
}

/// Resolutions from urf-supported: "RS300" -> [300], "RS300-600" -> [300, 600].
List<int> urfResolutionsOf(List<String> urfSupported) {
  final out = <int>{};
  for (final v in urfSupported) {
    if (!v.startsWith('RS')) continue;
    for (final p in v.substring(2).split('-')) {
      final n = int.tryParse(p.trim());
      if (n != null && n > 0) out.add(n);
    }
  }
  return out.toList()..sort();
}

/// Builds [PrinterCaps] from a Get-Printer-Attributes response body.
PrinterCaps parsePrinterCaps(Uint8List body) {
  final a = _checked(body, 'Get-Printer-Attributes');
  final colorModes = _list<String>(a, 'print-color-mode-supported');
  final colorFlag = _list<bool>(a, 'color-supported');
  final urf = _list<String>(a, 'urf-supported');
  final mediaDefault = _first(a, 'media-default');
  return PrinterCaps(
    state: _state(a),
    stateReasons: _reasons(a),
    makeAndModel: _first(a, 'printer-make-and-model'),
    documentFormats: _list<String>(a, 'document-format-supported'),
    mediaSupported: _list<String>(a, 'media-supported'),
    mediaDefault: mediaDefault.isEmpty ? null : mediaDefault,
    colorSupported: colorFlag.isNotEmpty
        ? colorFlag.first
        : (colorModes.isEmpty || colorModes.contains('color')),
    colorModes: colorModes,
    sides: _list<String>(a, 'sides-supported'),
    urfSupported: urf,
    urfResolutions: urfResolutionsOf(urf),
  );
}

/// POSTs an IPP request to http://host:631/path (the ipp:// URI's port and path).
/// Redirects: only 307/308 to a local address (see [sendLocal]).
Future<Uint8List> _post(Uri ippUri, Uint8List body, http.Client? client, Duration timeout) async {
  checkLocal(ippUri);
  final httpUri = ippUri.replace(
    scheme: ippUri.scheme == 'ipps' ? 'https' : 'http',
    port: ippUri.hasPort ? ippUri.port : 631,
  );
  final c = client ?? http.Client();
  try {
    final r = await sendLocal(c, 'POST', httpUri,
            headers: {'Content-Type': 'application/ipp'}, body: body, error: IppError.new)
        .timeout(timeout);
    if (r.statusCode != 200) throw IppError('Printer answered HTTP ${r.statusCode}');
    return r.bodyBytes;
  } on TimeoutException {
    throw const IppError('The printer did not answer in time');
  } on http.ClientException catch (e) {
    throw IppError('Cannot reach the printer: ${e.message}');
  } finally {
    if (client == null) c.close();
  }
}

/// Asks the printer for state, reasons, model and toner levels.
/// [ippUri] like ipp://192.168.1.20:631/ipp/print; sent as HTTP POST to the same port/path.
Future<PrinterInfo> getPrinterInfo(
  Uri ippUri, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  checkLocal(ippUri);
  final body = encodeGetPrinterAttributes(ippUri.toString(), requestId: _nextRequestId++);
  return parsePrinterInfo(await _post(ippUri, body, client, timeout));
}

/// Asks the printer what it can print (formats, paper, colour, URF resolutions) and its state.
Future<PrinterCaps> getPrinterCaps(
  Uri ippUri, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  checkLocal(ippUri);
  final body = encodeGetPrinterAttributes(ippUri.toString(),
      requestId: _nextRequestId++, requested: _capsAttributes);
  return parsePrinterCaps(await _post(ippUri, body, client, timeout));
}

/// Sends [document] as one Print-Job (copies, media, colour/monochrome, one-sided).
/// Returns the job id (null if the printer did not report one).
/// Throws [IppError] with [IppError.status] when the printer rejects the job.
Future<int?> printJob(
  Uri ippUri,
  Uint8List document, {
  required String format,
  required String jobName,
  int copies = 1,
  required String media,
  required bool color,
  http.Client? client,
  Duration timeout = const Duration(minutes: 5),
}) async {
  checkLocal(ippUri);
  final header = encodePrintJob(ippUri.toString(),
      format: format,
      jobName: jobName,
      media: media,
      color: color,
      copies: copies,
      requestId: _nextRequestId++);
  final body = Uint8List(header.length + document.length)
    ..setRange(0, header.length, header)
    ..setRange(header.length, header.length + document.length, document);
  final a = _checked(await _post(ippUri, body, client, timeout), 'Print job');
  final ids = _list<int>(a, 'job-id');
  return ids.isEmpty ? null : ids.first;
}
