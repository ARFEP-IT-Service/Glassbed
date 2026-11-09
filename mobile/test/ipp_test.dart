import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/ipp.dart';
import 'package:glassbed/core/lan.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Tiny IPP encoder for building printer responses in tests.
class IppBuilder {
  final _b = BytesBuilder();

  IppBuilder(int status, {int requestId = 1}) {
    _b.add([2, 0, status >> 8, status & 0xff]);
    _u32(requestId);
  }

  void _u16(int v) => _b.add([(v >> 8) & 0xff, v & 0xff]);
  void _u32(int v) {
    _u16((v >> 16) & 0xffff);
    _u16(v & 0xffff);
  }

  void group(int tag) => _b.addByte(tag);

  void _value(int tag, String name, List<int> value) {
    _b.addByte(tag);
    final n = ascii.encode(name);
    _u16(n.length);
    _b.add(n);
    _u16(value.length);
    _b.add(value);
  }

  void strings(int tag, String name, List<String> values) {
    for (var i = 0; i < values.length; i++) {
      _value(tag, i == 0 ? name : '', utf8.encode(values[i]));
    }
  }

  void ints(int tag, String name, List<int> values) {
    for (var i = 0; i < values.length; i++) {
      final v = ByteData(4)..setInt32(0, values[i]);
      _value(tag, i == 0 ? name : '', v.buffer.asUint8List());
    }
  }

  void bools(String name, List<bool> values) {
    for (var i = 0; i < values.length; i++) {
      _value(tagBoolean, i == 0 ? name : '', [values[i] ? 1 : 0]);
    }
  }

  Uint8List done() {
    _b.addByte(0x03);
    return _b.takeBytes();
  }
}

Uint8List hpResponse({int state = 3}) {
  final b = IppBuilder(0x0000)
    ..group(0x01)
    ..strings(tagCharset, 'attributes-charset', ['utf-8'])
    ..strings(tagLanguage, 'attributes-natural-language', ['en'])
    ..group(0x04)
    ..ints(tagEnum, 'printer-state', [state])
    ..strings(tagKeyword, 'printer-state-reasons', ['toner-low-report', 'media-empty-warning'])
    ..strings(tagText, 'printer-make-and-model', ['HP Color Laser MFP 178 179'])
    ..strings(tagName, 'marker-names', [
      'Black Toner_S/N_CRUM-19072512345',
      'Cyan Toner_S/N_CRUM-19072512346',
      'Magenta Toner',
      'Yellow Toner',
    ])
    ..ints(tagInteger, 'marker-levels', [80, 45, 10, -1])
    ..strings(tagName, 'marker-colors', ['#000000', '#00FFFF', '#FF00FF', '#FFFF00']);
  return b.done();
}

void main() {
  test('encode Get-Printer-Attributes', () {
    const uri = 'ipp://192.168.178.33:631/ipp/print';
    final req = encodeGetPrinterAttributes(uri, requestId: 7);
    expect(req.sublist(0, 8), [2, 0, 0x00, 0x0B, 0, 0, 0, 7]);
    expect(req[8], 0x01); // operation attributes
    expect(req.last, 0x03); // end of attributes
    // decodable with our own decoder; charset/language first, as RFC 8011 requires
    final (_, attrs) = decodeIppResponse(req);
    expect(attrs.keys.take(3), ['attributes-charset', 'attributes-natural-language', 'printer-uri']);
    expect(attrs['attributes-charset'], ['utf-8']);
    expect(attrs['printer-uri'], [uri]);
    expect(attrs['requested-attributes'], containsAll(['printer-state', 'marker-levels']));
  });

  test('decode a printer response', () {
    final info = parsePrinterInfo(hpResponse());
    expect(info.state, 'idle');
    expect(info.stateReasons, ['toner-low-report', 'media-empty-warning']);
    expect(info.makeAndModel, 'HP Color Laser MFP 178 179');
    expect(info.markers.map((m) => m.name),
        ['Black Toner', 'Cyan Toner', 'Magenta Toner', 'Yellow Toner']);
    expect(info.markers.map((m) => m.level), [80, 45, 10, -1]);
    expect(info.markers.map((m) => m.color), ['#000000', '#00FFFF', '#FF00FF', '#FFFF00']);
  });

  test('state names, "none" reason dropped, error status', () {
    expect(parsePrinterInfo(hpResponse(state: 4)).state, 'processing');
    expect(parsePrinterInfo(hpResponse(state: 5)).state, 'stopped');
    final none = (IppBuilder(0)
          ..group(0x04)
          ..ints(tagEnum, 'printer-state', [3])
          ..strings(tagKeyword, 'printer-state-reasons', ['none']))
        .done();
    final info = parsePrinterInfo(none);
    expect(info.stateReasons, isEmpty);
    expect(info.markers, isEmpty);
    expect(() => parsePrinterInfo((IppBuilder(0x0400)).done()), throwsA(isA<IppError>()));
    expect(() => decodeIppResponse(Uint8List(4)), throwsA(isA<IppError>()));
  });

  test('getPrinterInfo posts to http://host:631/path', () async {
    late http.Request seen;
    final client = MockClient((r) async {
      seen = r;
      return http.Response.bytes(hpResponse(), 200, headers: {'content-type': 'application/ipp'});
    });
    final info = await getPrinterInfo(Uri.parse('ipp://192.168.178.33:631/ipp/print'), client: client);
    expect(seen.method, 'POST');
    expect(seen.url.toString(), 'http://192.168.178.33:631/ipp/print');
    expect(seen.headers['Content-Type'], 'application/ipp');
    expect(info.markers, hasLength(4));
  });

  test('getPrinterInfo refuses hosts outside the LAN', () async {
    var calls = 0;
    final client = MockClient((r) async {
      calls++;
      return http.Response.bytes(hpResponse(), 200);
    });
    await expectLater(getPrinterInfo(Uri.parse('ipp://8.8.8.8:631/ipp/print'), client: client),
        throwsA(isA<NotLocalNetwork>()));
    await expectLater(getPrinterInfo(Uri.parse('ipp://example.com/ipp/print'), client: client),
        throwsA(isA<NotLocalNetwork>()));
    expect(calls, 0);
  });
}
