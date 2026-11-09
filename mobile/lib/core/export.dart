import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

import 'escl.dart';
import 'pixels.dart';

// Writes scanned pages as PDF/JPG/PNG with nothing but the pixels: no text layer,
// no fonts, no document info, no XMP, no EXIF, no PNG text chunks.

enum ExportFormat { pdf, jpg, png }

class ExportedFile {
  const ExportedFile({required this.name, required this.mimeType, required this.bytes});

  final String name;
  final String mimeType;
  final Uint8List bytes;
}

/// One PDF with all pages, or one file per page (name_001.pdf …); JPG/PNG always one per page.
/// pages = already edited images (applyEdits) with their dpi. Page size from pixels/dpi.
List<ExportedFile> exportPages(
  List<ScannedPage> pages,
  ExportFormat f, {
  required String baseName,
  bool splitPdf = false,
  int jpegQuality = 85,
}) {
  if (pages.isEmpty) return const [];
  final base = _safeName(baseName);
  final quality = jpegQuality.clamp(1, 100);
  final perPage = f != ExportFormat.pdf || splitPdf;
  String name(int i, String ext) =>
      perPage && pages.length > 1 ? '${base}_${(i + 1).toString().padLeft(3, '0')}.$ext' : '$base.$ext';

  switch (f) {
    case ExportFormat.pdf:
      if (!splitPdf) {
        return [ExportedFile(name: name(0, 'pdf'), mimeType: 'application/pdf', bytes: buildPdf(pages, quality))];
      }
      return [
        for (var i = 0; i < pages.length; i++)
          ExportedFile(
            name: name(i, 'pdf'),
            mimeType: 'application/pdf',
            bytes: buildPdf([pages[i]], quality),
          ),
      ];
    case ExportFormat.jpg:
      return [
        for (var i = 0; i < pages.length; i++)
          ExportedFile(name: name(i, 'jpg'), mimeType: 'image/jpeg', bytes: encodeJpeg(pages[i].image, quality)),
      ];
    case ExportFormat.png:
      return [
        for (var i = 0; i < pages.length; i++)
          ExportedFile(name: name(i, 'png'), mimeType: 'image/png', bytes: encodePngClean(pages[i].image)),
      ];
  }
}

/// JPEG without EXIF/ICC (the encoder only writes what the image carries).
/// The encoder always writes YCbCr and reads G/B as 0 from one-channel images,
/// so grey pages are expanded to RGB first.
Uint8List encodeJpeg(img.Image image, int quality) =>
    img.encodeJpg(toRgb(image), quality: quality);

/// PNG without text/EXIF/ICC chunks.
Uint8List encodePngClean(img.Image image) => img.encodePng(normalize(image));

/// A PDF whose pages each show exactly one JPEG image at the page's physical size.
Uint8List buildPdf(List<ScannedPage> pages, int jpegQuality) {
  // Uncompressed classic PDF 1.4: images are JPEG (DCT) anyway, the rest is a few
  // hundred bytes, and the file stays inspectable. No PdfInfo object is created,
  // so there is no /Info dictionary (Producer, CreationDate, ...) and no XMP.
  final doc = PdfDocument(compress: false, version: PdfVersion.pdf_1_4);
  for (final page in pages) {
    final image = PdfImage.jpeg(doc, image: encodeJpeg(page.image, jpegQuality));
    final dpi = page.dpi > 0 ? page.dpi : 300;
    final w = image.width * 72.0 / dpi, h = image.height * 72.0 / dpi;
    final p = PdfPage(doc, pageFormat: PdfPageFormat(w, h));
    p.getGraphics().drawImage(image, 0, 0, w, h);
  }
  final out = PdfStream();
  // write() is async only for optional event-loop balancing and signatures, neither
  // of which is used: the whole document is serialised synchronously before the
  // future is returned. The check below guarantees that.
  doc.write(out).ignore();
  final bytes = out.output();
  if (!_endsWith(bytes, '%%EOF\n')) throw StateError('PDF was not written completely');
  _blankLibraryComment(bytes);
  return bytes;
}

/// The pdf package writes its project URL as a comment in the header. Overwrite it with
/// spaces of the same length so all byte offsets (xref table) stay valid.
void _blankLibraryComment(Uint8List bytes) {
  final marker = ascii.encode('https://github.com/DavBfr/dart_pdf');
  final limit = bytes.length < 256 ? bytes.length : 256; // only in the header
  for (var i = 0; i + marker.length <= limit; i++) {
    var hit = true;
    for (var k = 0; k < marker.length; k++) {
      if (bytes[i + k] != marker[k]) {
        hit = false;
        break;
      }
    }
    if (hit) {
      bytes.fillRange(i, i + marker.length, 0x20);
      return;
    }
  }
}

bool _endsWith(Uint8List bytes, String suffix) {
  final s = ascii.encode(suffix);
  if (bytes.length < s.length) return false;
  for (var i = 0; i < s.length; i++) {
    if (bytes[bytes.length - s.length + i] != s[i]) return false;
  }
  return true;
}

String _safeName(String name) {
  final cleaned = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1f]'), '_');
  return cleaned.isEmpty ? 'Scan' : cleaned;
}
