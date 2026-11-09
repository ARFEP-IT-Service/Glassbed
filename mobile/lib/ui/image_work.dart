import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../core/edit.dart' as ed;
import '../core/escl.dart';
import '../core/export.dart';

/// Long side of the editor preview; edits are previewed on a copy this size for speed.
const previewLongSide = 1600;

/// Long side of the copy used for page thumbnails.
const thumbLongSide = 420;

/// RGBA pixels produced in a background isolate, ready for [ui.decodeImageFromPixels].
typedef Pixels = ({Uint8List rgba, int width, int height});

img.Image downscale(img.Image src, int longSide) {
  final long = src.width > src.height ? src.width : src.height;
  if (long <= longSide) return src;
  return src.width >= src.height
      ? img.copyResize(src, width: longSide, interpolation: img.Interpolation.average)
      : img.copyResize(src, height: longSide, interpolation: img.Interpolation.average);
}

/// RGBA bytes of an edited page. Core images are uint8 with 1 (grey) or 3 (RGB) channels.
Pixels _toPixels(img.Image im) {
  final n = im.width * im.height;
  final out = Uint8List(n * 4);
  if (im.format == img.Format.uint8 && (im.numChannels == 1 || im.numChannels == 3)) {
    final src = im.toUint8List();
    if (im.numChannels == 1) {
      for (var i = 0, o = 0; i < n; i++, o += 4) {
        final v = src[i];
        out[o] = v;
        out[o + 1] = v;
        out[o + 2] = v;
        out[o + 3] = 255;
      }
    } else {
      for (var i = 0, s = 0, o = 0; i < n; i++, s += 3, o += 4) {
        out[o] = src[s];
        out[o + 1] = src[s + 1];
        out[o + 2] = src[s + 2];
        out[o + 3] = 255;
      }
    }
  } else {
    final gray = im.numChannels < 3 && !im.hasPalette;
    int c(num v) => (v * 255).round().clamp(0, 255);
    var o = 0;
    for (final p in im) {
      out[o] = c(p.rNormalized);
      out[o + 1] = c(gray ? p.rNormalized : p.gNormalized);
      out[o + 2] = c(gray ? p.rNormalized : p.bNormalized);
      out[o + 3] = 255;
      o += 4;
    }
  }
  return (rgba: out, width: im.width, height: im.height);
}

/// Builds the preview and thumbnail copies of a freshly scanned page (off the UI thread).
Future<({img.Image preview, img.Image thumb})> makeBases(img.Image original) {
  return Isolate.run(() {
    final preview = downscale(original, previewLongSide);
    final thumb = downscale(preview, thumbLongSide);
    return (preview: preview, thumb: thumb);
  });
}

/// Applies [edits] (for the full-size original of width [originalWidth]) to the
/// downscaled [base] and returns its pixels. Runs in a background isolate.
Future<Pixels> renderEdited(img.Image base, int originalWidth, ed.Edits edits) {
  final scaled = edits.scaled(base.width / originalWidth);
  return Isolate.run(() => _toPixels(ed.applyEdits(base, scaled)));
}

/// Pixels to a GPU image for [RawImage].
Future<ui.Image> toUiImage(Pixels p) {
  final done = Completer<ui.Image>();
  ui.decodeImageFromPixels(p.rgba, p.width, p.height, ui.PixelFormat.rgba8888, done.complete);
  return done.future;
}

/// A page to export: full-size original plus its edits.
typedef ExportJob = ({img.Image image, int dpi, ed.Edits edits});

/// Burns all edits in at full resolution and builds the output files (background isolate).
Future<List<ExportedFile>> exportJobs(
  List<ExportJob> jobs,
  ExportFormat format, {
  required String baseName,
  required bool splitPdf,
}) {
  return Isolate.run(() {
    final pages = [
      for (final j in jobs)
        ScannedPage(j.edits.isIdentity ? j.image : ed.applyEdits(j.image, j.edits), j.dpi),
    ];
    return exportPages(pages, format, baseName: baseName, splitPdf: splitPdf);
  });
}
