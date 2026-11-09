import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/pixels.dart';
import 'package:glassbed/core/urf.dart';
import 'package:image/image.dart' as img;

// Fixtures written by test/fixtures/urf_fixture.py with the Windows app's encoder
// (glassbed/urf.py). patternPixel mirrors pattern_pixel there.
const width = 600;

int patternPixel(int x, int y, int c, int seed) {
  final band = (y ~/ 3) % 8;
  switch (band) {
    case 0:
      return 255;
    case 1:
      return (5 + c + seed) & 0xFF;
    case 2:
      final v = (x * 2654435761 + y * 40503 + c * 977 + seed * 7919) & 0xFFFFFFFF;
      return (v >> 13) & 0xFF;
    case 3:
      return x == width - 1 ? 0 : 255;
    case 4:
      if (x >= 400) return 255;
      if (x >= 200 && x < 206) return (x * 5 + c + seed) & 0xFF;
      if (x % 37 == 0) return 128;
      return (x ~/ 8 + seed) % 3 == 0 ? 0 : 255;
    case 5:
      if (x < 130) return (x * 3 + c + seed) & 0xFF;
      return ((x ~/ 10) * 17 + c * 40 + seed) & 0xFF;
    case 6:
      return (x + y + c * 60) & 0xFF;
    default:
      return x < 150 ? 255 : (y * 9 + c) & 0xFF;
  }
}

img.Image make(int height, bool color, int seed) {
  final ch = color ? 3 : 1;
  final out = blankImage(width, height, ch);
  final d = bytesOf(out);
  var i = 0;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      for (var c = 0; c < ch; c++) {
        d[i++] = patternPixel(x, y, c, seed);
      }
    }
  }
  return out;
}

Uint8List fixture(String name) => File('test/fixtures/$name').readAsBytesSync();

void main() {
  test('colour document is byte-identical to the Windows encoder', () {
    final pages = [make(48, true, 0), make(48, true, 1)];
    expect(encodeUrf(pages, dpi: 300, color: true), fixture('urf_color.urf'));
  });

  test('grey page with > 256 repeated lines is byte-identical', () {
    final grey = make(48, false, 2);
    final tall = blankImage(width, 600, 1);
    final d = bytesOf(tall)..fillRange(0, width * 600, 255);
    final g = bytesOf(grey);
    d.setRange(0, g.length, g);
    d.setRange(552 * width, 552 * width + g.length, g);
    expect(encodeUrf([tall], dpi: 600, color: false), fixture('urf_gray.urf'));
  });

  test('headers and an all-white page', () {
    final white = blankImage(8, 4, 1);
    bytesOf(white).fillRange(0, 32, 255);
    final data = encodeUrf([white], dpi: 300, color: false);
    expect(String.fromCharCodes(data.sublist(0, 7)), 'UNIRAST');
    expect(data[7], 0);
    final bd = ByteData.sublistView(data);
    expect(bd.getUint32(8), 1);
    expect([data[12], data[13], data[14], data[15]], [8, 0, 1, 4]); // bits, sGray, simplex, normal
    expect([bd.getUint32(24), bd.getUint32(28), bd.getUint32(32)], [8, 4, 300]);
    expect(data.sublist(44), [3, 0x80]); // 4 equal white lines -> repeat 3, rest white
    final rgb = encodeUrf([white], dpi: 300, color: true);
    expect([rgb[12], rgb[13]], [24, 1]); // 24 bit sRGB
  });

  test('roundtrip colour and grey', () {
    for (final color in [true, false]) {
      final page = make(48, color, 3);
      final out = decodeUrf(encodeUrf([page, page], dpi: 300, color: color));
      expect(out, hasLength(2));
      for (final p in out) {
        expect(p.numChannels, color ? 3 : 1);
        expect(bytesOf(p), bytesOf(page));
      }
    }
  });

  test('colour input encoded as grey, grey input as colour', () {
    final grey = make(12, false, 4);
    final asRgb = decodeUrf(encodeUrf([grey], dpi: 300, color: true)).single;
    expect(bytesOf(asRgb), bytesOf(toRgb(grey)));
    final rgb = make(12, true, 4);
    final asGrey = decodeUrf(encodeUrf([rgb], dpi: 300, color: false)).single;
    expect(bytesOf(asGrey), bytesOf(toGray(rgb)));
  });

  test('page header + page encoder build the same document', () {
    final a = make(24, true, 5), b = make(24, true, 6);
    final joined = BytesBuilder()
      ..add(urfFileHeader(2))
      ..add(encodeUrfPage(a, dpi: 300, color: true))
      ..add(encodeUrfPage(b, dpi: 300, color: true));
    expect(joined.takeBytes(), encodeUrf([a, b], dpi: 300, color: true));
  });

  test('decoder rejects garbage', () {
    expect(() => decodeUrf(Uint8List.fromList([1, 2, 3])), throwsFormatException);
    final data = encodeUrf([make(6, false, 0)], dpi: 300, color: false);
    expect(() => decodeUrf(Uint8List.sublistView(data, 0, data.length - 5)), throwsFormatException);
  });
}
