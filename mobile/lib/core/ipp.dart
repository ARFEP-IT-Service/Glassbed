import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'lan.dart';

// Minimal IPP/2.0 (RFC 8011): Get-Printer-Attributes over HTTP, for status and toner.

const ippGetPrinterAttributes = 0x000B;

const _groupOperation = 0x01;
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

const _printerStates = {3: 'idle', 4: 'processing', 5: 'stopped'};

/// Attributes the app asks for (keeps the answer small).
const _requested = [
  'printer-state',
  'printer-state-reasons',
  'printer-make-and-model',
  'marker-names',
  'marker-levels',
  'marker-colors',
];

class IppError implements Exception {
  const IppError(this.message);

  final String message;

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

  Uint8List take() => _b.takeBytes();
}

/// Encodes a Get-Printer-Attributes request for [printerUri] (ipp://...).
Uint8List encodeGetPrinterAttributes(String printerUri, {int requestId = 1}) {
  final w = _Writer()
    ..u8(2) // version 2.0
    ..u8(0)
    ..u16(ippGetPrinterAttributes)
    ..u32(requestId)
    ..u8(_groupOperation)
    ..attr(tagCharset, 'attributes-charset', utf8.encode('utf-8'))
    ..attr(tagLanguage, 'attributes-natural-language', utf8.encode('en'))
    ..attr(tagUri, 'printer-uri', utf8.encode(printerUri));
  for (var i = 0; i < _requested.length; i++) {
    // Additional values of a 1setOf have an empty name.
    w.attr(tagKeyword, i == 0 ? 'requested-attributes' : '', utf8.encode(_requested[i]));
  }
  w.u8(_endOfAttributes);
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

/// Builds [PrinterInfo] from a Get-Printer-Attributes response body.
PrinterInfo parsePrinterInfo(Uint8List body) {
  final (status, a) = decodeIppResponse(body);
  if (status >= 0x0100) {
    throw IppError('Get-Printer-Attributes failed (0x${status.toRadixString(16).padLeft(4, '0')})');
  }
  List<T> list<T>(String key) => (a[key] ?? const []).whereType<T>().toList();
  final names = list<String>('marker-names');
  final levels = list<int>('marker-levels');
  final colors = list<String>('marker-colors');
  final state = list<int>('printer-state');
  final models = list<String>('printer-make-and-model');
  return PrinterInfo(
    state: state.isEmpty ? 'unknown' : (_printerStates[state.first] ?? 'unknown'),
    stateReasons: list<String>('printer-state-reasons').where((r) => r != 'none').toList(),
    makeAndModel: models.isEmpty ? '' : models.first,
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

/// Asks the printer for state, reasons, model and toner levels.
/// [ippUri] like ipp://192.168.1.20:631/ipp/print; sent as HTTP POST to the same port/path.
Future<PrinterInfo> getPrinterInfo(
  Uri ippUri, {
  http.Client? client,
  Duration timeout = const Duration(seconds: 10),
}) async {
  checkLocal(ippUri);
  final httpUri = ippUri.replace(
    scheme: ippUri.scheme == 'ipps' ? 'https' : 'http',
    port: ippUri.hasPort ? ippUri.port : 631,
  );
  final c = client ?? http.Client();
  try {
    final r = await c
        .post(
          httpUri,
          headers: {'Content-Type': 'application/ipp'},
          body: encodeGetPrinterAttributes(ippUri.toString()),
        )
        .timeout(timeout);
    if (r.statusCode != 200) throw IppError('Printer answered HTTP ${r.statusCode}');
    return parsePrinterInfo(r.bodyBytes);
  } on TimeoutException {
    throw const IppError('The printer did not answer in time');
  } on http.ClientException catch (e) {
    throw IppError('Cannot reach the printer: ${e.message}');
  } finally {
    if (client == null) c.close();
  }
}
