import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'pixels.dart';

// Non-destructive page edits: rotate, straighten, crop, brightness, contrast, redact.
// The original scan is kept; [Edits] describes what to do with it, so a page can be
// re-edited or reset at any time. Redactions live in ORIGINAL pixel coordinates and are
// burned into the original before anything else, so covered pixels never reach a file.

/// A point in pixel coordinates (no dart:ui, so core runs without Flutter).
class Point {
  const Point(this.x, this.y);

  final double x, y;

  Point operator *(double f) => Point(x * f, y * f);

  @override
  bool operator ==(Object other) => other is Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Point($x, $y)';
}

/// A rectangle given by its edges.
class Rect {
  const Rect(this.left, this.top, this.right, this.bottom);

  static const full = Rect(0, 0, 1, 1);

  final double left, top, right, bottom;

  double get width => right - left;
  double get height => bottom - top;

  @override
  bool operator ==(Object other) =>
      other is Rect &&
      other.left == left &&
      other.top == top &&
      other.right == right &&
      other.bottom == bottom;

  @override
  int get hashCode => Object.hash(left, top, right, bottom);

  @override
  String toString() => 'Rect($left, $top, $right, $bottom)';
}

enum RedactStyle { black, white, blur }

/// A covered area, as a polygon in ORIGINAL image pixels.
class Redaction {
  const Redaction(this.polygon, this.style);

  /// An axis-aligned rectangle in original pixels.
  factory Redaction.rect(Rect r, RedactStyle style) => Redaction([
        Point(r.left, r.top),
        Point(r.right, r.top),
        Point(r.right, r.bottom),
        Point(r.left, r.bottom),
      ], style);

  final List<Point> polygon;
  final RedactStyle style;

  Rect get bounds {
    var l = double.infinity, t = double.infinity;
    var r = double.negativeInfinity, b = double.negativeInfinity;
    for (final p in polygon) {
      l = math.min(l, p.x);
      t = math.min(t, p.y);
      r = math.max(r, p.x);
      b = math.max(b, p.y);
    }
    return Rect(l, t, r, b);
  }

  Redaction scaled(double f) => Redaction([for (final p in polygon) p * f], style);
}

class Edits {
  Edits({
    this.rotate = 0,
    this.angle = 0,
    this.crop,
    this.brightness = 1.0,
    this.contrast = 1.0,
    List<Redaction>? redactions,
  }) : redactions = redactions ?? [];

  int rotate; // 0, 90, 180, 270 (clockwise)
  double angle; // straighten, -10..10 degrees (clockwise)
  Rect? crop; // normalised 0..1 in the rotated+straightened frame; null = whole page
  double brightness; // 1.0 = unchanged (0.5..1.5)
  double contrast; // 1.0 = unchanged (0.5..1.5)
  List<Redaction> redactions;

  bool get isIdentity =>
      _quarters(rotate) == 0 &&
      angle.abs() < 0.01 &&
      (crop == null || crop == Rect.full) &&
      (brightness - 1).abs() < 0.005 &&
      (contrast - 1).abs() < 0.005 &&
      redactions.isEmpty;

  Edits copy() => Edits(
        rotate: rotate,
        angle: angle,
        crop: crop,
        brightness: brightness,
        contrast: contrast,
        redactions: List.of(redactions),
      );

  /// Quarter-turns the page by [degrees] (multiple of 90, clockwise; negative = left).
  /// The crop rectangle turns with it, redactions follow automatically.
  void rotateBy(int degrees) {
    final steps = _quarters(degrees);
    rotate = (rotate + steps * 90) % 360;
    var c = crop;
    if (c != null) {
      for (var i = 0; i < steps; i++) {
        c = Rect(1 - c!.bottom, c.left, 1 - c.top, c.right);
      }
      crop = c;
    }
  }

  /// A copy for an image scaled by [factor] (e.g. a downscaled preview): redaction
  /// polygons are scaled, everything else is relative and stays the same.
  Edits scaled(double factor) => copy()
    ..redactions = [for (final r in redactions) r.scaled(factor)];
}

int _quarters(int degrees) => ((degrees ~/ 90) % 4 + 4) % 4;

// -- coordinates ---------------------------------------------------------------

/// Size of the rotated+straightened frame (straightening keeps the canvas size).
({int width, int height}) frameSize(img.Image original, Edits e) =>
    _quarters(e.rotate).isOdd
        ? (width: original.height, height: original.width)
        : (width: original.width, height: original.height);

/// Maps a point in original pixels into the rotated+straightened frame (pixels), the
/// frame the crop rectangle refers to.
Point toFrame(img.Image original, Edits e, Point p) {
  var w = original.width.toDouble(), h = original.height.toDouble();
  var x = p.x, y = p.y;
  for (var i = 0; i < _quarters(e.rotate); i++) {
    final nx = h - y; // one clockwise quarter turn
    y = x;
    x = nx;
    final t = w;
    w = h;
    h = t;
  }
  if (e.angle.abs() >= 0.01) {
    final a = e.angle * math.pi / 180, c = math.cos(a), s = math.sin(a);
    final dx = x - w / 2, dy = y - h / 2;
    x = w / 2 + dx * c - dy * s;
    y = h / 2 + dx * s + dy * c;
  }
  return Point(x, y);
}

/// Inverse of [toFrame] – used when the user draws on the edited view.
Point fromFrame(img.Image original, Edits e, Point p) {
  final f = frameSize(original, e);
  var w = f.width.toDouble(), h = f.height.toDouble();
  var x = p.x, y = p.y;
  if (e.angle.abs() >= 0.01) {
    final a = e.angle * math.pi / 180, c = math.cos(a), s = math.sin(a);
    final dx = x - w / 2, dy = y - h / 2;
    x = w / 2 + dx * c + dy * s;
    y = h / 2 - dx * s + dy * c;
  }
  for (var i = 0; i < _quarters(e.rotate); i++) {
    final ny = w - x; // one counter-clockwise quarter turn
    x = y;
    y = ny;
    final t = w;
    w = h;
    h = t;
  }
  return Point(x, y);
}

/// The crop in frame pixels: (left, top, width, height), at least 1×1.
({int x, int y, int width, int height}) cropBox(img.Image original, Edits e) {
  final f = frameSize(original, e);
  final c = e.crop ?? Rect.full;
  int px(double v, int size) => (v.clamp(0.0, 1.0) * size).round();
  final l = math.min(px(c.left, f.width), f.width - 1);
  final t = math.min(px(c.top, f.height), f.height - 1);
  final r = math.max(l + 1, px(c.right, f.width));
  final b = math.max(t + 1, px(c.bottom, f.height));
  return (x: l, y: t, width: r - l, height: b - t);
}

/// Maps a point in original pixels into the final (cropped) image of [applyEdits].
Point toOutput(img.Image original, Edits e, Point p) {
  final q = toFrame(original, e, p);
  final box = cropBox(original, e);
  return Point(q.x - box.x, q.y - box.y);
}

/// Inverse of [toOutput].
Point fromOutput(img.Image original, Edits e, Point p) {
  final box = cropBox(original, e);
  return fromFrame(original, e, Point(p.x + box.x, p.y + box.y));
}

// -- applying ------------------------------------------------------------------

/// Burns redactions into the ORIGINAL first (so no geometry can leak them), applies
/// rotate, straighten, crop, tone, then burns the transformed redactions again (tone
/// cannot reveal them). Blur destroys detail (coarse cells + smoothing), not just softens.
/// The result is 8-bit with 1 (grey) or 3 (RGB) channels and no metadata.
img.Image applyEdits(img.Image original, Edits e) {
  final src = normalize(original);
  if (e.isIdentity) return src;
  final wasBw = isBlackAndWhite(src);

  var out = src.clone();
  _paintRedactions(out, e.redactions);
  final q = _quarters(e.rotate);
  if (q != 0) out = _rotateQuarters(out, q);
  if (e.angle.abs() >= 0.01) out = _straighten(out, e.angle);
  final box = cropBox(original, e);
  if (box.x != 0 || box.y != 0 || box.width != out.width || box.height != out.height) {
    out = _crop(out, box.x, box.y, box.width, box.height);
  }
  _tone(out, e.brightness, e.contrast);

  final solid = [
    for (final r in e.redactions)
      if (r.style != RedactStyle.blur)
        Redaction([for (final p in r.polygon) toOutput(original, e, p)], r.style),
  ];
  _paintRedactions(out, solid);

  if (wasBw) {
    final d = bytesOf(out);
    for (var i = 0; i < d.length; i++) {
      d[i] = d[i] > 128 ? 255 : 0;
    }
  }
  return out;
}

/// Calls [span] for each row with the pixel range [x0, x1] whose centres lie inside
/// [poly] (even-odd rule), clipped to width × height.
void _spans(List<Point> poly, int width, int height, void Function(int y, int x0, int x1) span) {
  if (poly.length < 3) return;
  var minY = double.infinity, maxY = double.negativeInfinity;
  for (final p in poly) {
    minY = math.min(minY, p.y);
    maxY = math.max(maxY, p.y);
  }
  final y0 = math.max(0, (minY - 0.5).ceil());
  final y1 = math.min(height - 1, (maxY - 0.5).floor());
  final xs = <double>[];
  for (var y = y0; y <= y1; y++) {
    final yc = y + 0.5;
    xs.clear();
    for (var i = 0; i < poly.length; i++) {
      final a = poly[i], b = poly[(i + 1) % poly.length];
      if ((a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc)) {
        xs.add(a.x + (yc - a.y) * (b.x - a.x) / (b.y - a.y));
      }
    }
    xs.sort();
    for (var k = 0; k + 1 < xs.length; k += 2) {
      final x0 = math.max(0, (xs[k] - 0.5).ceil());
      final x1 = math.min(width - 1, (xs[k + 1] - 0.5).ceil() - 1);
      if (x1 >= x0) span(y, x0, x1);
    }
  }
}

void _paintRedactions(img.Image image, List<Redaction> redactions) {
  final d = bytesOf(image);
  final ch = image.numChannels, w = image.width, h = image.height;
  for (final r in redactions) {
    if (r.style == RedactStyle.blur) {
      _blurPolygon(image, r.polygon);
      continue;
    }
    final v = r.style == RedactStyle.black ? 0 : 255;
    _spans(r.polygon, w, h, (y, x0, x1) {
      d.fillRange((y * w + x0) * ch, (y * w + x1 + 1) * ch, v);
    });
  }
}

/// Frosted-glass blur strong enough that text inside cannot be read: the area is
/// averaged into a few coarse cells (that is what destroys the detail), then
/// enlarged smoothly and softened so it looks like frosted glass, not a mosaic.
void _blurPolygon(img.Image image, List<Point> poly) {
  final w = image.width, h = image.height, ch = image.numChannels;
  final bounds = Redaction(poly, RedactStyle.blur).bounds;
  final l = math.max(0, bounds.left.floor()), t = math.max(0, bounds.top.floor());
  final r = math.min(w, bounds.right.ceil()), b = math.min(h, bounds.bottom.ceil());
  final bw = r - l, bh = b - t;
  if (bw < 1 || bh < 1) return;
  final d = bytesOf(image);

  // 1. coarse cell averages
  final cell = math.max(24.0, math.min(bw, bh) / 1.5);
  final gx = math.max(1, (bw / cell).round()), gy = math.max(1, (bh / cell).round());
  final sums = Float64List(gx * gy * ch);
  final counts = Int32List(gx * gy);
  for (var y = 0; y < bh; y++) {
    final cy = y * gy ~/ bh;
    for (var x = 0; x < bw; x++) {
      final cx = x * gx ~/ bw, c = cy * gx + cx;
      final o = ((t + y) * w + l + x) * ch;
      counts[c]++;
      for (var k = 0; k < ch; k++) {
        sums[c * ch + k] += d[o + k];
      }
    }
  }
  for (var c = 0; c < gx * gy; c++) {
    for (var k = 0; k < ch; k++) {
      sums[c * ch + k] /= math.max(1, counts[c]);
    }
  }

  // 2. bilinear enlargement between cell centres
  final region = Float64List(bw * bh * ch);
  for (var y = 0; y < bh; y++) {
    final fy = ((y + 0.5) * gy / bh - 0.5).clamp(0.0, gy - 1.0);
    final y0 = fy.floor(), y1 = math.min(gy - 1, y0 + 1), wy = fy - y0;
    for (var x = 0; x < bw; x++) {
      final fx = ((x + 0.5) * gx / bw - 0.5).clamp(0.0, gx - 1.0);
      final x0 = fx.floor(), x1 = math.min(gx - 1, x0 + 1), wx = fx - x0;
      for (var k = 0; k < ch; k++) {
        final a = sums[(y0 * gx + x0) * ch + k], bb = sums[(y0 * gx + x1) * ch + k];
        final c = sums[(y1 * gx + x0) * ch + k], dd = sums[(y1 * gx + x1) * ch + k];
        region[(y * bw + x) * ch + k] =
            (a * (1 - wx) + bb * wx) * (1 - wy) + (c * (1 - wx) + dd * wx) * wy;
      }
    }
  }

  // 3. soften (separable box blur)
  final radius = math.max(4, (math.min(bw, bh) * 0.12).round());
  _boxBlur(region, bw, bh, ch, radius);

  // 4. paste inside the polygon only
  _spans(poly, w, h, (y, x0, x1) {
    for (var x = x0; x <= x1; x++) {
      final ry = y - t, rx = x - l;
      if (ry < 0 || ry >= bh || rx < 0 || rx >= bw) continue;
      for (var k = 0; k < ch; k++) {
        d[(y * w + x) * ch + k] = region[(ry * bw + rx) * ch + k].round().clamp(0, 255);
      }
    }
  });
}

void _boxBlur(Float64List a, int w, int h, int ch, int r) {
  final line = Float64List(math.max(w, h) * ch);
  void pass(int len, int count, int Function(int i, int j) index) {
    for (var j = 0; j < count; j++) {
      for (var k = 0; k < ch; k++) {
        // running sum over the window [i - r, i + r], clipped to the line
        var s = 0.0;
        for (var m = 0; m <= math.min(len - 1, r); m++) {
          s += a[index(m, j) * ch + k];
        }
        for (var i = 0; i < len; i++) {
          final lo = math.max(0, i - r), hi = math.min(len - 1, i + r);
          line[i * ch + k] = s / (hi - lo + 1);
          if (i + r + 1 < len) s += a[index(i + r + 1, j) * ch + k];
          if (i - r >= 0) s -= a[index(i - r, j) * ch + k];
        }
      }
      for (var i = 0; i < len; i++) {
        for (var k = 0; k < ch; k++) {
          a[index(i, j) * ch + k] = line[i * ch + k];
        }
      }
    }
  }

  pass(w, h, (i, j) => j * w + i); // rows
  pass(h, w, (i, j) => i * w + j); // columns
}

img.Image _rotateQuarters(img.Image src, int q) {
  final w = src.width, h = src.height, ch = src.numChannels;
  final odd = q.isOdd;
  final out = blankImage(odd ? h : w, odd ? w : h, ch);
  final s = bytesOf(src), d = bytesOf(out);
  final ow = out.width;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      // destination of source pixel (x, y), clockwise
      final int nx, ny;
      switch (q) {
        case 1:
          nx = h - 1 - y;
          ny = x;
        case 2:
          nx = w - 1 - x;
          ny = h - 1 - y;
        default:
          nx = y;
          ny = w - 1 - x;
      }
      final si = (y * w + x) * ch, di = (ny * ow + nx) * ch;
      for (var k = 0; k < ch; k++) {
        d[di + k] = s[si + k];
      }
    }
  }
  return out;
}

/// Rotates by [degrees] clockwise around the centre, same canvas, white outside.
img.Image _straighten(img.Image src, double degrees) {
  final w = src.width, h = src.height, ch = src.numChannels;
  final out = blankImage(w, h, ch);
  final s = bytesOf(src), d = bytesOf(out);
  final a = degrees * math.pi / 180, c = math.cos(a), sn = math.sin(a);
  final cx = w / 2, cy = h / 2;
  for (var y = 0; y < h; y++) {
    final dy = y + 0.5 - cy;
    for (var x = 0; x < w; x++) {
      final dx = x + 0.5 - cx;
      // inverse rotation: where does this pixel come from?
      final fx = cx + dx * c + dy * sn - 0.5;
      final fy = cy - dx * sn + dy * c - 0.5;
      final di = (y * w + x) * ch;
      if (fx < -0.5 || fy < -0.5 || fx > w - 0.5 || fy > h - 0.5) {
        d.fillRange(di, di + ch, 255);
        continue;
      }
      final x0 = fx.floor(), y0 = fy.floor();
      final wx = fx - x0, wy = fy - y0;
      final xa = x0.clamp(0, w - 1), xb = (x0 + 1).clamp(0, w - 1);
      final ya = y0.clamp(0, h - 1), yb = (y0 + 1).clamp(0, h - 1);
      for (var k = 0; k < ch; k++) {
        final p00 = s[(ya * w + xa) * ch + k], p10 = s[(ya * w + xb) * ch + k];
        final p01 = s[(yb * w + xa) * ch + k], p11 = s[(yb * w + xb) * ch + k];
        d[di + k] =
            ((p00 * (1 - wx) + p10 * wx) * (1 - wy) + (p01 * (1 - wx) + p11 * wx) * wy).round();
      }
    }
  }
  return out;
}

img.Image _crop(img.Image src, int x, int y, int width, int height) {
  final ch = src.numChannels, sw = src.width;
  final out = blankImage(width, height, ch);
  final s = bytesOf(src), d = bytesOf(out);
  for (var row = 0; row < height; row++) {
    final from = ((y + row) * sw + x) * ch;
    d.setRange(row * width * ch, (row + 1) * width * ch, s, from);
  }
  return out;
}

/// Brightness scales towards black; contrast scales around the mean grey (like the
/// Windows app, which uses Pillow's ImageEnhance).
void _tone(img.Image image, double brightness, double contrast) {
  final bOn = (brightness - 1).abs() >= 0.005, cOn = (contrast - 1).abs() >= 0.005;
  if (!bOn && !cOn) return;
  final d = bytesOf(image);
  final lut = Uint8List(256);
  for (var v = 0; v < 256; v++) {
    lut[v] = (v * brightness).round().clamp(0, 255);
  }
  if (cOn) {
    // mean luminance after brightness, sampled for speed
    final ch = image.numChannels;
    final pixels = d.length ~/ ch;
    final step = math.max(1, pixels ~/ 200000);
    var sum = 0.0;
    var n = 0;
    for (var p = 0; p < pixels; p += step) {
      final i = p * ch;
      sum += ch == 1
          ? lut[d[i]]
          : (lut[d[i]] * 299 + lut[d[i + 1]] * 587 + lut[d[i + 2]] * 114) / 1000;
      n++;
    }
    final mean = n == 0 ? 128.0 : sum / n;
    for (var v = 0; v < 256; v++) {
      lut[v] = (mean + (lut[v] - mean) * contrast).round().clamp(0, 255);
    }
  }
  for (var i = 0; i < d.length; i++) {
    d[i] = lut[d[i]];
  }
}
