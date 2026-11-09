import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'pixels.dart';

// Apple raster (URF / "UNIRAST"), the raster format every AirPrint printer accepts.
// A file is "UNIRAST\0" + page count, then pages with a 32-byte header and
// PackBits-like lines:
//  * every line starts with a line-repeat byte (number of extra copies of the line)
//  * then packets: 0x00-0x7F -> next pixel repeated n+1 times,
//    0x81-0xFF -> 257-n literal pixels follow, 0x80 -> rest of the line is white.
// Byte-identical to the Windows app's encoder (glassbed/urf.py).

const urfColorSpaceGray = 0; // sGray
const urfColorSpaceRgb = 1; // sRGB
const _qualityNormal = 4;
const _duplexSimplex = 1;

final _magic = ascii.encode('UNIRAST\x00');

class _Out {
  final _b = BytesBuilder(copy: false);

  void u8(int v) => _b.addByte(v & 0xff);
  void u32(int v) => _b.add([(v >> 24) & 0xff, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff]);
  void bytes(List<int> b) => _b.add(b);
  void range(Uint8List b, int start, int end) => _b.add(Uint8List.sublistView(b, start, end));
  Uint8List take() => _b.takeBytes();
}

/// File header: magic + page count.
Uint8List urfFileHeader(int pageCount) {
  final o = _Out()
    ..bytes(_magic)
    ..u32(pageCount);
  return o.take();
}

void _pageHeader(_Out o, int width, int height, int dpi, bool color) {
  o
    ..u8(color ? 24 : 8)
    ..u8(color ? urfColorSpaceRgb : urfColorSpaceGray)
    ..u8(_duplexSimplex)
    ..u8(_qualityNormal)
    ..u32(0)
    ..u32(0)
    ..u32(width)
    ..u32(height)
    ..u32(dpi)
    ..u32(0)
    ..u32(0);
}

/// Encodes one page (header + lines). The image is converted to 8-bit grey or RGB first.
Uint8List encodeUrfPage(img.Image page, {required int dpi, required bool color}) {
  final o = _Out();
  _encodePage(o, page, dpi, color);
  return o.take();
}

/// Encodes [pages] as one URF document at [dpi]: 24-bit sRGB when [color], else 8-bit sGray.
Uint8List encodeUrf(List<img.Image> pages, {required int dpi, required bool color}) {
  final o = _Out()
    ..bytes(_magic)
    ..u32(pages.length);
  for (final p in pages) {
    _encodePage(o, p, dpi, color);
  }
  return o.take();
}

void _encodePage(_Out o, img.Image page, int dpi, bool color) {
  final src = color ? toRgb(page) : toGray(page);
  final w = src.width, h = src.height, bpp = color ? 3 : 1;
  final data = bytesOf(src);
  final stride = w * bpp;
  _pageHeader(o, w, h, dpi, color);
  var y = 0;
  while (y < h) {
    var repeat = 0;
    while (repeat < 255 && y + repeat + 1 < h && _sameRow(data, stride, y, y + repeat + 1)) {
      repeat++;
    }
    o.u8(repeat);
    _encodeLine(o, data, y * stride, w, bpp);
    y += repeat + 1;
  }
}

bool _sameRow(Uint8List d, int stride, int a, int b) {
  final ia = a * stride, ib = b * stride;
  for (var i = 0; i < stride; i++) {
    if (d[ia + i] != d[ib + i]) return false;
  }
  return true;
}

/// Pixel [x] of the line at [base] equals pixel [x2]?
bool _samePixel(Uint8List d, int base, int bpp, int x, int x2) {
  final a = base + x * bpp, b = base + x2 * bpp;
  for (var k = 0; k < bpp; k++) {
    if (d[a + k] != d[b + k]) return false;
  }
  return true;
}

bool _isWhite(Uint8List d, int base, int bpp, int x) {
  final a = base + x * bpp;
  for (var k = 0; k < bpp; k++) {
    if (d[a + k] != 255) return false;
  }
  return true;
}

void _literal(_Out o, Uint8List d, int base, int bpp, int from, int upto) {
  var s = from;
  while (s < upto) {
    final n = upto - s < 128 ? upto - s : 128;
    o.u8(n == 1 ? 0 : 257 - n);
    o.range(d, base + s * bpp, base + (s + n) * bpp);
    s += n;
  }
}

/// One line without the repeat byte, exactly like urf.py's _encode_line.
void _encodeLine(_Out o, Uint8List d, int base, int width, int bpp) {
  var end = width;
  while (end > 0 && _isWhite(d, base, bpp, end - 1)) {
    end--;
  }
  if (end == 0) {
    o.u8(0x80);
    return;
  }

  // Runs of identical pixels within [0, end).
  final starts = <int>[0];
  for (var x = 1; x < end; x++) {
    if (!_samePixel(d, base, bpp, x, x - 1)) starts.add(x);
  }

  if (starts.length > end ~/ 3) {
    // Noisy line (photo): runs don't pay off, emit literal chunks.
    _literal(o, d, base, bpp, 0, end);
  } else {
    int? litStart;
    for (var i = 0; i < starts.length; i++) {
      final s = starts[i];
      var n = (i + 1 < starts.length ? starts[i + 1] : end) - s;
      if (n == 1) {
        litStart ??= s;
        continue;
      }
      if (litStart != null) {
        _literal(o, d, base, bpp, litStart, s);
        litStart = null;
      }
      final px = base + s * bpp;
      while (n > 0) {
        final r = n < 128 ? n : 128;
        o.u8(r - 1);
        o.range(d, px, px + bpp);
        n -= r;
      }
    }
    if (litStart != null) _literal(o, d, base, bpp, litStart, end);
  }

  if (end < width) o.u8(0x80);
}

/// Decodes a URF document back to images (1 channel for 8-bit, 3 for 24-bit pages).
/// Throws [FormatException] for anything that is not well-formed URF.
List<img.Image> decodeUrf(Uint8List data) {
  if (data.length < 12 || !_startsWithMagic(data)) {
    throw const FormatException('not a URF file');
  }
  final bd = ByteData.sublistView(data);
  final count = bd.getUint32(8);
  var i = 12;
  final pages = <img.Image>[];
  int next() {
    if (i >= data.length) throw const FormatException('truncated URF data');
    return data[i++];
  }

  for (var p = 0; p < count; p++) {
    if (i + 32 > data.length) throw const FormatException('truncated URF page header');
    final bits = data[i];
    final w = bd.getUint32(i + 12), h = bd.getUint32(i + 16);
    i += 32;
    if (bits != 8 && bits != 24) throw FormatException('unsupported URF bit depth $bits');
    final bpp = bits ~/ 8;
    final out = blankImage(w, h, bpp);
    final px = bytesOf(out);
    final stride = w * bpp;
    var y = 0;
    while (y < h) {
      final repeat = next();
      final line = Uint8List(stride);
      var pos = 0;
      while (pos < stride) {
        final c = next();
        if (c == 0x80) {
          line.fillRange(pos, stride, 255);
          pos = stride;
        } else if (c < 0x80) {
          if (i + bpp > data.length || pos + (c + 1) * bpp > stride) {
            throw const FormatException('bad URF run');
          }
          for (var r = 0; r <= c; r++) {
            line.setRange(pos, pos + bpp, data, i);
            pos += bpp;
          }
          i += bpp;
        } else {
          final n = (257 - c) * bpp;
          if (i + n > data.length || pos + n > stride) {
            throw const FormatException('bad URF literal');
          }
          line.setRange(pos, pos + n, data, i);
          pos += n;
          i += n;
        }
      }
      for (var r = 0; r <= repeat && y < h; r++, y++) {
        px.setRange(y * stride, (y + 1) * stride, line);
      }
    }
    pages.add(out);
  }
  return pages;
}

bool _startsWithMagic(Uint8List d) {
  for (var k = 0; k < _magic.length; k++) {
    if (d[k] != _magic[k]) return false;
  }
  return true;
}
