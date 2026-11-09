import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/pixels.dart';
import 'package:glassbed/core/print_layout.dart';
import 'package:image/image.dart' as img;

img.Image solid(int w, int h, int value, {int channels = 3}) {
  final out = blankImage(w, h, channels);
  bytesOf(out).fillRange(0, w * h * channels, value);
  return out;
}

int grey(img.Image page, int x, int y) => bytesOf(page)[y * page.width + x];

/// Bounding box (left, top, right, bottom exclusive) of the non-white pixels of a grey page.
(int, int, int, int) inkBox(img.Image page) {
  final d = bytesOf(page);
  var l = page.width, t = page.height, r = -1, b = -1;
  for (var y = 0; y < page.height; y++) {
    for (var x = 0; x < page.width; x++) {
      if (d[y * page.width + x] < 128) {
        if (x < l) l = x;
        if (x > r) r = x;
        if (y < t) t = y;
        if (y > b) b = y;
      }
    }
  }
  return (l, t, r + 1, b + 1);
}

void main() {
  test('paper sizes', () {
    expect(printDpi, 300);
    expect(mediaPixels(mediaA4, 300), (2480, 3508));
    expect(mediaPixels(mediaA4), (2480, 3508));
    expect(mediaPixels(mediaLetter, 300), (2550, 3300));
    expect(mediaPixels('iso_a5_148x210mm', 100), (583, 827));
    expect(mediaPixels('na_legal_8.5x14in', 300), (2550, 4200));
    expect(mediaPixels('jpn_hagaki_100x148mm', 300), (1181, 1748)); // generic PWG name
    expect(mediaPixels('na_index-4x6_4x6in', 300), (1200, 1800));
    expect(mediaSizeMm('custom_min_foo'), isNull);
    expect(() => mediaPixels('roll_max', 300), throwsArgumentError);
  });

  test('A4 page, grey and colour channel count, white background', () {
    final g = layoutForPrint(const PrintSource.blank(), mediaA4, false);
    expect((g.width, g.height, g.numChannels), (2480, 3508, 1));
    expect(bytesOf(g).every((v) => v == 255), isTrue);
    final c = layoutForPrint(const PrintSource.blank(), mediaA4, true, dpi: 100);
    expect((c.width, c.height, c.numChannels), (827, 1169, 3));
  });

  test('scan: actual size, top-left (copy)', () {
    // 2 x 3 inch black scan at 100 dpi -> 600 x 900 pixels at 300 dpi, at (0, 0)
    final page = layoutForPrint(PrintSource.scan(solid(200, 300, 0), 100), mediaA4, false);
    expect((page.width, page.height), (2480, 3508));
    expect(inkBox(page), (0, 0, 600, 900));
    expect(grey(page, 10, 10), 0);
  });

  test('scan larger than the paper is cut off, not shrunk', () {
    // full A4 at 100 dpi plus extra -> covers the page, top-left
    final page = layoutForPrint(PrintSource.scan(solid(900, 1300, 0), 100), mediaA4, false);
    expect((page.width, page.height), (2480, 3508));
    expect(inkBox(page), (0, 0, 2480, 3508));
  });

  test('image: fitted inside 5 mm margins, centred', () {
    // portrait image, aspect 1:2 -> height limited: box 2362 x 3390
    final page = layoutForPrint(PrintSource.image(solid(100, 200, 0)), mediaA4, false);
    final (l, t, r, b) = inkBox(page);
    expect(b - t, 3390);
    expect(r - l, 1695);
    expect(t, 59); // margin = round(5 mm at 300 dpi)
    expect(((l + r) / 2 - 1240).abs(), lessThanOrEqualTo(1));
  });

  test('image with known dpi is never enlarged beyond its size', () {
    // 1 x 1 inch at 100 dpi -> 300 x 300 at 300 dpi, centred
    final page = layoutForPrint(PrintSource.image(solid(100, 100, 0), dpi: 100), mediaA4, false);
    final (l, t, r, b) = inkBox(page);
    expect((r - l, b - t), (300, 300));
    expect((l, t), ((2480 - 300) ~/ 2, (3508 - 300) ~/ 2));
  });

  test('landscape image is rotated onto portrait paper', () {
    // black left half, white right half: rotated counter-clockwise -> black at the bottom
    final src = solid(400, 200, 255);
    final d = bytesOf(src);
    for (var y = 0; y < 200; y++) {
      d.fillRange(y * 400 * 3, (y * 400 + 200) * 3, 0);
    }
    final page = layoutForPrint(PrintSource.image(src), mediaA4, false);
    final (l, t, r, b) = inkBox(page);
    // rotated to 200 x 400, height limited: 1695 x 3390, the black half is the lower one
    expect((r - l, b - t), (1695, 1695));
    expect(b, 3508 - 59);
    expect(t, greaterThan(3508 ~/ 2 - 5));
    expect(grey(page, 1240, 3508 ~/ 2 + 600), 0);
    expect(grey(page, 1240, 3508 ~/ 2 - 600), 255);
  });

  test('PDF page: fitted 1:1, centred, landscape rotated', () {
    // A4 page rendered at 50 dpi -> scaled up to the full 300 dpi page
    final portrait = layoutForPrint(PrintSource.pdfPage(solid(413, 585, 0), 595.28, 841.89), mediaA4, false);
    expect(inkBox(portrait), (0, 0, 2480, 3508));

    // landscape A4 page, left half black -> rotated clockwise: black in the upper half
    final src = solid(842, 595, 255, channels: 1);
    final d = bytesOf(src);
    for (var y = 0; y < 595; y++) {
      d.fillRange(y * 842, y * 842 + 421, 0);
    }
    final land = layoutForPrint(PrintSource.pdfPage(src, 841.89, 595.28), mediaA4, false);
    final (l, t, r, b) = inkBox(land);
    expect((l, t, r), (0, 0, 2480));
    expect((b - 1754).abs(), lessThanOrEqualTo(3));
  });

  test('transparent pixels print white, colour is kept', () {
    final rgba = img.Image(width: 10, height: 10, numChannels: 4); // all transparent black
    final page = layoutForPrint(PrintSource.image(rgba, dpi: 300), mediaA4, true);
    expect(bytesOf(page).every((v) => v == 255), isTrue);

    final red = solid(10, 10, 0);
    final d = bytesOf(red);
    for (var i = 0; i < d.length; i += 3) {
      d[i] = 255;
    }
    final c = layoutForPrint(PrintSource.image(red, dpi: 300), mediaA4, true);
    final at = ((3508 ~/ 2) * 2480 + 1240) * 3;
    expect(bytesOf(c).sublist(at, at + 3), [255, 0, 0]);
  });

  test('resize keeps flat colours exact', () {
    final up = resizeImage(solid(7, 5, 77), 23, 31);
    expect(bytesOf(up).every((v) => v == 77), isTrue);
    final down = resizeImage(solid(301, 199, 200, channels: 1), 17, 9);
    expect(bytesOf(down).every((v) => v == 200), isTrue);
  });
}
