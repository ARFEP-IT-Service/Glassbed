import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/edit.dart';
import 'package:image/image.dart' as img;

const w = 200, h = 160;
const secret = Rect(60, 40, 140, 100); // where the "text" is, original pixels

/// White page (RGB) with text-like black/white stripes inside [secret].
img.Image page({int channels = 3}) {
  final image = img.Image(width: w, height: h, numChannels: channels);
  final d = image.toUint8List();
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final inside = x >= secret.left && x < secret.right && y >= secret.top && y < secret.bottom;
      // 2px stripes, broken every 6 rows like lines of text
      final v = inside && (x ~/ 2).isEven && y % 6 != 0 ? 0 : 255;
      for (var k = 0; k < channels; k++) {
        d[(y * w + x) * channels + k] = v;
      }
    }
  }
  return image;
}

/// Luminance values of the pixels whose centres lie inside [r] (output pixels).
List<int> valuesIn(img.Image image, Rect r, {double inset = 0}) {
  final out = <int>[];
  final d = image.toUint8List();
  final ch = image.numChannels;
  for (var y = 0; y < image.height; y++) {
    for (var x = 0; x < image.width; x++) {
      final cx = x + 0.5, cy = y + 0.5;
      if (cx > r.left + inset && cx < r.right - inset && cy > r.top + inset && cy < r.bottom - inset) {
        var s = 0;
        for (var k = 0; k < ch; k++) {
          s += d[(y * image.width + x) * ch + k];
        }
        out.add(s ~/ ch);
      }
    }
  }
  return out;
}

double variance(List<int> v) {
  final m = v.reduce((a, b) => a + b) / v.length;
  return v.map((x) => (x - m) * (x - m)).reduce((a, b) => a + b) / v.length;
}

/// Bounding box of [r] (original pixels) in the output of [applyEdits].
Rect outputRect(img.Image original, Edits e, Rect r) {
  final pts = [
    Point(r.left, r.top),
    Point(r.right, r.top),
    Point(r.right, r.bottom),
    Point(r.left, r.bottom),
  ].map((p) => toOutput(original, e, p));
  return Rect(pts.map((p) => p.x).reduce(math.min), pts.map((p) => p.y).reduce(math.min),
      pts.map((p) => p.x).reduce(math.max), pts.map((p) => p.y).reduce(math.max));
}

Edits redact(RedactStyle style) => Edits(redactions: [Redaction.rect(secret, style)]);

void main() {
  test('the fixture really has detail in the secret area', () {
    final v = valuesIn(page(), secret);
    expect(v.toSet(), {0, 255});
    expect(variance(v), greaterThan(10000));
  });

  test('black redaction is burned in', () {
    final out = applyEdits(page(), redact(RedactStyle.black));
    expect(valuesIn(out, secret).toSet(), {0});
    // outside untouched
    expect(valuesIn(out, const Rect(0, 0, 50, 30)).toSet(), {255});
  });

  test('tone cannot reveal or grey a black redaction', () {
    for (final (b, c) in [(1.5, 0.5), (1.5, 1.5), (0.5, 0.5), (1.0, 0.5)]) {
      final e = redact(RedactStyle.black)
        ..brightness = b
        ..contrast = c;
      final out = applyEdits(page(), e);
      expect(valuesIn(out, secret).toSet(), {0}, reason: 'brightness $b contrast $c');
    }
  });

  test('rotate 90 + crop: redacted content is not recoverable', () {
    final original = page();
    final e = redact(RedactStyle.black)
      ..rotate = 90
      ..crop = const Rect(0.1, 0.2, 0.9, 0.85)
      ..brightness = 1.5
      ..contrast = 0.5;
    final out = applyEdits(original, e);
    expect(out.width, (0.9 * h).round() - (0.1 * h).round());
    expect(out.height, (0.85 * w).round() - (0.2 * w).round());
    final r = outputRect(original, e, secret);
    final inside = valuesIn(out, r);
    expect(inside, isNotEmpty);
    expect(inside.toSet(), {0});
    // no stripe survives anywhere: the only dark pixels are the redaction itself
    final dark = valuesIn(out, Rect(0, 0, out.width.toDouble(), out.height.toDouble()))
        .where((v) => v < 128)
        .length;
    expect(dark, inside.length);
  });

  test('straighten: redaction stays solid', () {
    final original = page();
    final e = redact(RedactStyle.black)
      ..angle = 4.0
      ..contrast = 0.5;
    final out = applyEdits(original, e);
    expect(out.width, w);
    expect(out.height, h);
    // the rotated rectangle, slightly inset to stay clear of its slanted edges
    final r = outputRect(original, e, secret);
    final pts = valuesIn(out, r, inset: 6);
    expect(pts, isNotEmpty);
    expect(pts.toSet(), {0});
  });

  test('white redaction', () {
    final out = applyEdits(page(), redact(RedactStyle.white)..contrast = 1.5);
    expect(valuesIn(out, secret).toSet(), {255});
  });

  test('blur destroys the detail', () {
    for (final ch in [1, 3]) {
      final original = page(channels: ch);
      final before = variance(valuesIn(original, secret));
      final out = applyEdits(original, redact(RedactStyle.blur));
      final after = variance(valuesIn(out, secret));
      expect(after, lessThan(25), reason: 'channels $ch: $before -> $after');
      // no pixel keeps the pure black of the stripes
      expect(valuesIn(out, secret).every((v) => v > 60), isTrue);
    }
  });

  test('blur with rotate + tone stays unreadable', () {
    final out = applyEdits(
        page(), redact(RedactStyle.blur)..rotate = 270..contrast = 1.5..brightness = 0.7);
    final e = redact(RedactStyle.blur)..rotate = 270;
    final r = outputRect(page(), e, secret);
    expect(variance(valuesIn(out, r, inset: 1)), lessThan(25));
  });

  test('toFrame/fromFrame roundtrip', () {
    final original = page();
    final rnd = math.Random(1);
    for (final rotate in [0, 90, 180, 270]) {
      for (final angle in [0.0, -7.5, 4.0]) {
        final e = Edits(rotate: rotate, angle: angle);
        for (var i = 0; i < 20; i++) {
          final p = Point(rnd.nextDouble() * w, rnd.nextDouble() * h);
          final back = fromFrame(original, e, toFrame(original, e, p));
          expect(back.x, closeTo(p.x, 1e-9));
          expect(back.y, closeTo(p.y, 1e-9));
          final o = fromOutput(original, e..crop = const Rect(0.1, 0.1, 0.8, 0.9),
              toOutput(original, e, p));
          expect(o.x, closeTo(p.x, 1e-9));
          expect(o.y, closeTo(p.y, 1e-9));
          e.crop = null;
        }
      }
    }
  });

  test('toFrame matches where pixels really go (clockwise)', () {
    final original = img.Image(width: w, height: h, numChannels: 1)..clear(img.ColorUint8.rgb(255, 255, 255));
    original.setPixelRgb(10, 20, 0, 0, 0);
    for (final rotate in [90, 180, 270]) {
      final e = Edits(rotate: rotate, brightness: 1.01);
      final out = applyEdits(original, e);
      final p = toFrame(original, e, const Point(10.5, 20.5));
      expect(out.getPixel(p.x.floor(), p.y.floor()).r, 0, reason: 'rotate $rotate');
    }
    // 90 clockwise: the top-left corner goes to the top-right
    final p = toFrame(original, Edits(rotate: 90), const Point(0, 0));
    expect((p.x, p.y), (h.toDouble(), 0.0));
  });

  test('rotateBy turns the crop with the page', () {
    final original = img.Image(width: w, height: h, numChannels: 1)..clear(img.ColorUint8.rgb(255, 255, 255));
    for (var y = 30; y < 40; y++) {
      for (var x = 20; x < 30; x++) {
        original.setPixelRgb(x, y, 0, 0, 0);
      }
    }
    final e = Edits(crop: const Rect(0.05, 0.1, 0.3, 0.4));
    final dark = applyEdits(original, e).toUint8List().where((v) => v == 0).length;
    expect(dark, 100);
    for (final turn in [90, 90, -90, 180]) {
      e.rotateBy(turn);
      final out = applyEdits(original, e);
      expect(out.toUint8List().where((v) => v == 0).length, 100, reason: 'rotate ${e.rotate}');
    }
  });

  test('B/W pages stay pure black/white after straighten and tone', () {
    final bw = page(channels: 1);
    final out = applyEdits(bw, Edits(angle: 3, contrast: 1.2));
    expect(out.toUint8List().toSet().difference({0, 255}), isEmpty);
  });

  test('identity, copy and scaled', () {
    final e = Edits();
    expect(e.isIdentity, isTrue);
    final original = page();
    expect(applyEdits(original, e).toUint8List(), original.toUint8List());
    final r = redact(RedactStyle.black);
    expect(r.isIdentity, isFalse);
    final c = r.copy()..redactions.clear();
    expect(r.redactions, hasLength(1));
    expect(c.isIdentity, isTrue);
    final s = r.scaled(0.5);
    expect(s.redactions.single.bounds, const Rect(30, 20, 70, 50));
    expect(r.redactions.single.bounds, secret);
  });
}
