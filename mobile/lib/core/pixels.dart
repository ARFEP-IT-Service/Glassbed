import 'dart:typed_data';

import 'package:image/image.dart' as img;

// Small, fast pixel helpers working on the raw byte buffer of 8-bit images.
// All core code keeps pages as uint8 with 1 (grey) or 3 (RGB) channels.

/// A fresh 8-bit image with [channels] (1 or 3) and no metadata.
img.Image blankImage(int width, int height, int channels) =>
    img.Image(width: width, height: height, numChannels: channels);

/// Raw bytes (row-major, interleaved channels) of an image made by [normalize]/[blankImage].
Uint8List bytesOf(img.Image image) => image.toUint8List();

/// uint8 with 1 or 3 channels, without palette, alpha, EXIF or ICC data.
/// Returns [image] itself when it already fits (metadata is cleared in place).
img.Image normalize(img.Image image) {
  var out = image;
  if (out.hasPalette ||
      out.format != img.Format.uint8 ||
      (out.numChannels != 1 && out.numChannels != 3) ||
      out.numFrames > 1) {
    final grey = out.numChannels <= 2 && !out.hasPalette;
    out = out.convert(
      format: img.Format.uint8,
      numChannels: grey ? 1 : 3,
      noAnimation: true,
    );
  }
  stripMetadata(out);
  return out;
}

/// Removes everything an encoder could write besides the pixels.
void stripMetadata(img.Image image) {
  image.exif = img.ExifData();
  image.iccProfile = null;
  image.textData = null;
}

/// Luminance copy with one channel (ITU-R 601 weights, like most scanners).
img.Image toGray(img.Image image) {
  final src = normalize(image);
  if (src.numChannels == 1) return src;
  final out = blankImage(src.width, src.height, 1);
  final s = bytesOf(src), d = bytesOf(out);
  for (var i = 0, j = 0; j < d.length; i += 3, j++) {
    d[j] = (s[i] * 299 + s[i + 1] * 587 + s[i + 2] * 114 + 500) ~/ 1000;
  }
  return out;
}

/// Pure black/white (one channel, values 0 or 255).
img.Image threshold(img.Image image, {int level = 160}) {
  final out = toGray(image);
  final copy = identical(out, image) ? out.clone() : out;
  final d = bytesOf(copy);
  for (var i = 0; i < d.length; i++) {
    d[i] = d[i] > level ? 255 : 0;
  }
  return copy;
}

/// True when a one-channel image contains only 0 and 255 (a B/W scan).
bool isBlackAndWhite(img.Image image) {
  if (image.numChannels != 1 || image.format != img.Format.uint8) return false;
  final d = bytesOf(image);
  for (var i = 0; i < d.length; i++) {
    final v = d[i];
    if (v != 0 && v != 255) return false;
  }
  return true;
}

/// Three-channel copy (grey is replicated into R, G and B).
img.Image toRgb(img.Image image) {
  final src = normalize(image);
  if (src.numChannels == 3) return src;
  final out = blankImage(src.width, src.height, 3);
  final s = bytesOf(src), d = bytesOf(out);
  for (var i = 0, j = 0; i < s.length; i++, j += 3) {
    d[j] = d[j + 1] = d[j + 2] = s[i];
  }
  return out;
}
