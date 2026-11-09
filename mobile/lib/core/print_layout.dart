import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'pixels.dart';

/// Resolution of the page bitmaps sent to the printer (same as the Windows app).
const int printDpi = 300;

const mediaA4 = 'iso_a4_210x297mm';
const mediaLetter = 'na_letter_8.5x11in';

/// Margin around photos/images; PDFs and scans use the whole page.
const double imageMarginMm = 5.0;

const _knownMedia = {
  mediaA4: (210.0, 297.0),
  mediaLetter: (215.9, 279.4),
  'na_legal_8.5x14in': (215.9, 355.6),
  'iso_a5_148x210mm': (148.0, 210.0),
};

/// Size in millimetres of an IPP/PWG media name ("iso_a4_210x297mm", "na_letter_8.5x11in",
/// any self-describing "class_name_WxHmm|in"). Returns null for names without a size.
(double, double)? mediaSizeMm(String media) {
  final known = _knownMedia[media];
  if (known != null) return known;
  final m = RegExp(r'_(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)(mm|in)$').firstMatch(media);
  if (m == null) return null;
  final f = m.group(3) == 'in' ? 25.4 : 1.0;
  final w = double.parse(m.group(1)!) * f, h = double.parse(m.group(2)!) * f;
  if (w <= 0 || h <= 0) return null;
  return (w, h);
}

/// Page size in pixels at [dpi]; A4 at 300 dpi = (2480, 3508).
/// Throws [ArgumentError] for media names without a size.
(int, int) mediaPixels(String media, [int dpi = printDpi]) {
  final mm = mediaSizeMm(media);
  if (mm == null) throw ArgumentError.value(media, 'media', 'unknown paper size');
  return ((mm.$1 / 25.4 * dpi).round(), (mm.$2 / 25.4 * dpi).round());
}

/// What to put on a printed page. See [layoutForPrint].
sealed class PrintSource {
  const PrintSource();

  /// A PDF page rendered to [bitmap] (any resolution, white background); its page size
  /// is [widthPt] x [heightPt] points (1/72 in). Fitted to the paper, centred, rotated
  /// when the orientation differs.
  const factory PrintSource.pdfPage(img.Image bitmap, double widthPt, double heightPt) =
      PdfPagePrintSource;

  /// A photo or image file. Fitted inside 5 mm margins, centred, rotated when that fits
  /// better; never enlarged beyond its own physical size when [dpi] is known.
  const factory PrintSource.image(img.Image image, {double? dpi}) = ImagePrintSource;

  /// A scan (copy): actual size, anchored top-left like the original on the glass,
  /// cut off at the paper edge.
  const factory PrintSource.scan(img.Image image, int dpi) = ScanPrintSource;

  /// An empty sheet (back side of an odd page count in manual duplex).
  const factory PrintSource.blank() = BlankPrintSource;
}

class PdfPagePrintSource extends PrintSource {
  const PdfPagePrintSource(this.bitmap, this.widthPt, this.heightPt);

  final img.Image bitmap;
  final double widthPt;
  final double heightPt;
}

class ImagePrintSource extends PrintSource {
  const ImagePrintSource(this.image, {this.dpi});

  final img.Image image;
  final double? dpi;
}

class ScanPrintSource extends PrintSource {
  const ScanPrintSource(this.image, this.dpi);

  final img.Image image;
  final int dpi;
}

class BlankPrintSource extends PrintSource {
  const BlankPrintSource();
}

/// A full-page bitmap of exactly the media size at [dpi], like render_for_print in the
/// Windows app. 3 channels when [color], else 1 channel (grey).
img.Image layoutForPrint(PrintSource src, String media, bool color, {int dpi = printDpi}) {
  final (pageW, pageH) = mediaPixels(media, dpi);
  final ch = color ? 3 : 1;
  final canvas = blankImage(pageW, pageH, ch);
  bytesOf(canvas).fillRange(0, pageW * pageH * ch, 255);
  final pagePortrait = pageW <= pageH;

  switch (src) {
    case BlankPrintSource():
      break;

    case PdfPagePrintSource(:final bitmap, :final widthPt, :final heightPt):
      var pw = widthPt, ph = heightPt;
      var page = _prepare(bitmap, color);
      if ((pw > ph) != !pagePortrait) {
        page = _rotate90(page, clockwise: true);
        (pw, ph) = (ph, pw);
      }
      final scale = math.min(pageW / (pw / 72 * dpi), pageH / (ph / 72 * dpi));
      // A page of the paper's own size fills it completely (points vs. mm rounding).
      var w = (pw / 72 * dpi * scale).round().clamp(1, pageW);
      var h = (ph / 72 * dpi * scale).round().clamp(1, pageH);
      if (w >= pageW - 1) w = pageW;
      if (h >= pageH - 1) h = pageH;
      page = resizeImage(page, w, h);
      _paste(canvas, page, (pageW - w) ~/ 2, (pageH - h) ~/ 2);

    case ScanPrintSource(:final image, dpi: final srcDpi):
      final f = dpi / srcDpi;
      // Crop before scaling: only the part that lands on the paper is resampled.
      final cw = math.min(image.width, (pageW / f).ceil());
      final cht = math.min(image.height, (pageH / f).ceil());
      var page = _prepare(image, color);
      if (cw < page.width || cht < page.height) page = _crop(page, cw, cht);
      page = resizeImage(page, math.max(1, (cw * f).round()), math.max(1, (cht * f).round()));
      _paste(canvas, page, 0, 0);

    case ImagePrintSource(:final image, dpi: final srcDpi):
      var page = _prepare(image, color);
      if ((page.width > page.height) != !pagePortrait) {
        page = _rotate90(page, clockwise: false);
      }
      final margin = (imageMarginMm / 25.4 * dpi).round();
      final boxW = pageW - 2 * margin, boxH = pageH - 2 * margin;
      var f = math.min(boxW / page.width, boxH / page.height);
      if (srcDpi != null && srcDpi > 1) f = math.min(f, dpi / srcDpi);
      final w = math.max(1, (page.width * f).round());
      final h = math.max(1, (page.height * f).round());
      page = resizeImage(page, w, h);
      _paste(canvas, page, (pageW - w) ~/ 2, (pageH - h) ~/ 2);
  }
  stripMetadata(canvas);
  return canvas;
}

/// Flattens transparency onto white and converts to grey or RGB.
img.Image _prepare(img.Image image, bool color) {
  var src = image;
  if (src.hasAlpha || (src.hasPalette && (src.palette?.numChannels ?? 3) == 4)) {
    final rgba = src.convert(format: img.Format.uint8, numChannels: 4, noAnimation: true);
    final out = blankImage(rgba.width, rgba.height, 3);
    final s = rgba.toUint8List(), d = bytesOf(out);
    for (var i = 0, j = 0; j < d.length; i += 4, j += 3) {
      final a = s[i + 3];
      if (a == 255) {
        d[j] = s[i];
        d[j + 1] = s[i + 1];
        d[j + 2] = s[i + 2];
      } else {
        final inv = 255 - a;
        d[j] = (s[i] * a + 255 * inv + 127) ~/ 255;
        d[j + 1] = (s[i + 1] * a + 255 * inv + 127) ~/ 255;
        d[j + 2] = (s[i + 2] * a + 255 * inv + 127) ~/ 255;
      }
    }
    src = out;
  }
  return color ? toRgb(src) : toGray(src);
}

void _paste(img.Image canvas, img.Image part, int left, int top) {
  final ch = canvas.numChannels, cw = canvas.width;
  final w = math.min(part.width, cw - left), h = math.min(part.height, canvas.height - top);
  if (w <= 0 || h <= 0) return;
  final s = bytesOf(part), d = bytesOf(canvas);
  for (var y = 0; y < h; y++) {
    final from = y * part.width * ch;
    final to = ((top + y) * cw + left) * ch;
    d.setRange(to, to + w * ch, s, from);
  }
}

img.Image _crop(img.Image src, int width, int height) {
  final ch = src.numChannels;
  final out = blankImage(width, height, ch);
  final s = bytesOf(src), d = bytesOf(out);
  for (var y = 0; y < height; y++) {
    d.setRange(y * width * ch, (y + 1) * width * ch, s, y * src.width * ch);
  }
  return out;
}

img.Image _rotate90(img.Image src, {required bool clockwise}) {
  final w = src.width, h = src.height, ch = src.numChannels;
  final out = blankImage(h, w, ch);
  final s = bytesOf(src), d = bytesOf(out);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // clockwise: (x, y) -> (h-1-y, x); counter-clockwise: (x, y) -> (y, w-1-x)
      final di = clockwise ? (x * h + (h - 1 - y)) * ch : ((w - 1 - x) * h + y) * ch;
      final si = (y * w + x) * ch;
      for (var k = 0; k < ch; k++) {
        d[di + k] = s[si + k];
      }
    }
  }
  return out;
}

/// Resamples a 1- or 3-channel 8-bit image to [width] x [height] with a separable
/// triangle filter (bilinear when enlarging, area-weighted when shrinking).
img.Image resizeImage(img.Image src, int width, int height) {
  final s0 = normalize(src);
  if (s0.width == width && s0.height == height) return s0;
  final ch = s0.numChannels;
  final tmp = _resample(bytesOf(s0), s0.width, s0.height, ch, width, horizontal: true);
  final out = blankImage(width, height, ch);
  final res = _resample(tmp, width, s0.height, ch, height, horizontal: false);
  bytesOf(out).setRange(0, res.length, res);
  return out;
}

/// One pass along x ([horizontal]) or y, from [w] x [h] to the new length [n].
Uint8List _resample(Uint8List s, int w, int h, int ch, int n, {required bool horizontal}) {
  final len = horizontal ? w : h;
  if (len == n) return s;
  final scale = n / len;
  final support = scale < 1 ? 1 / scale : 1.0;
  // Precomputed contributions per output position (fixed point, 14 bits).
  final first = Int32List(n);
  final counts = Int32List(n);
  final weights = <Int32List>[];
  for (var o = 0; o < n; o++) {
    final centre = (o + 0.5) / scale - 0.5;
    var lo = (centre - support).floor() + 1, hi = (centre + support).ceil() - 1;
    lo = math.max(lo, 0);
    hi = math.min(hi, len - 1);
    if (hi < lo) lo = hi = centre.round().clamp(0, len - 1);
    final ws = Float64List(hi - lo + 1);
    var sum = 0.0;
    for (var i = lo; i <= hi; i++) {
      final v = 1 - (i - centre).abs() / support;
      ws[i - lo] = v > 0 ? v : 0;
      sum += ws[i - lo];
    }
    final fixed = Int32List(ws.length);
    if (sum <= 0) {
      fixed[0] = 1 << 14;
    } else {
      var acc = 0;
      for (var k = 0; k < ws.length; k++) {
        fixed[k] = (ws[k] / sum * (1 << 14)).round();
        acc += fixed[k];
      }
      fixed[ws.length ~/ 2] += (1 << 14) - acc; // weights add up to exactly 1.0
    }
    first[o] = lo;
    counts[o] = ws.length;
    weights.add(fixed);
  }

  final ow = horizontal ? n : w, oh = horizontal ? h : n;
  final d = Uint8List(ow * oh * ch);
  const round = 1 << 13;
  if (horizontal) {
    for (var y = 0; y < h; y++) {
      final row = y * w * ch, orow = y * n * ch;
      for (var o = 0; o < n; o++) {
        final wt = weights[o], lo = first[o], c = counts[o];
        for (var k = 0; k < ch; k++) {
          var acc = 0;
          for (var i = 0; i < c; i++) {
            acc += s[row + (lo + i) * ch + k] * wt[i];
          }
          final v = (acc + round) >> 14;
          d[orow + o * ch + k] = v < 0 ? 0 : (v > 255 ? 255 : v);
        }
      }
    }
  } else {
    final stride = w * ch;
    for (var o = 0; o < n; o++) {
      final wt = weights[o], lo = first[o], c = counts[o];
      final orow = o * stride;
      for (var x = 0; x < stride; x++) {
        var acc = 0;
        for (var i = 0; i < c; i++) {
          acc += s[(lo + i) * stride + x] * wt[i];
        }
        final v = (acc + round) >> 14;
        d[orow + x] = v < 0 ? 0 : (v > 255 ? 255 : v);
      }
    }
  }
  return d;
}
