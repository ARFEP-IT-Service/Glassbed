import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glassbed/core/escl.dart';
import 'package:glassbed/core/export.dart';
import 'package:image/image.dart' as img;

/// A page that carries metadata, to prove the exporter drops it.
ScannedPage pageWithMetadata({int channels = 3}) {
  final image = img.Image(width: 120, height: 170, numChannels: channels);
  for (final p in image) {
    p.setRgb(p.x * 2, p.y, 255 - p.x);
  }
  image.exif.imageIfd['ImageDescription'] = img.IfdValueAscii('secret description');
  image.exif.imageIfd['Make'] = img.IfdValueAscii('HP');
  image.textData = {'Comment': 'secret comment', 'Author': 'someone'};
  return ScannedPage(image, 100);
}

String latin(Uint8List b) => latin1.decode(b);

/// The PDF without the bytes of its image streams (JPEG data could contain any byte
/// sequence by chance), plus the decoded non-image content streams.
({String structure, List<String> contents}) splitPdf(Uint8List pdf) {
  final s = latin(pdf);
  final structure = StringBuffer();
  final contents = <String>[];
  var pos = 0;
  final streamStart = RegExp(r'stream\r?\n');
  while (true) {
    final m = streamStart
        .allMatches(s, pos)
        .where((m) => m.start < 3 || s.substring(m.start - 3, m.start) != 'end')
        .firstOrNull;
    if (m == null) break;
    final end = s.indexOf('endstream', m.end);
    final dict = s.substring(s.lastIndexOf(' obj', m.start), m.start);
    structure.write(s.substring(pos, m.start));
    if (!dict.contains('/DCTDecode')) contents.add(s.substring(m.end, end));
    pos = end + 'endstream'.length;
  }
  structure.write(s.substring(pos));
  return (structure: structure.toString(), contents: contents);
}

int pageCount(String structure) => RegExp(r'/Type\s*/Page(?![a-zA-Z])').allMatches(structure).length;

/// JPEG marker segments from SOI to SOS.
List<int> jpegMarkers(Uint8List b) {
  expect(b.sublist(0, 2), [0xFF, 0xD8]);
  final markers = <int>[];
  var i = 2;
  while (i + 4 <= b.length) {
    expect(b[i], 0xFF);
    final m = b[i + 1];
    markers.add(m);
    if (m == 0xDA) break; // start of scan: entropy-coded data follows
    i += 2 + ((b[i + 2] << 8) | b[i + 3]);
  }
  return markers;
}

List<String> pngChunks(Uint8List b) {
  final chunks = <String>[];
  var i = 8;
  while (i + 8 <= b.length) {
    final len = ByteData.sublistView(b, i, i + 4).getUint32(0);
    chunks.add(ascii.decode(b.sublist(i + 4, i + 8)));
    i += 12 + len;
  }
  return chunks;
}

bool containsBytes(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var k = 0; k < needle.length; k++) {
      if (haystack[i + k] != needle[k]) continue outer;
    }
    return true;
  }
  return false;
}

void main() {
  final pages = [pageWithMetadata(), pageWithMetadata(channels: 1)];

  group('PDF', () {
    final files = exportPages(pages, ExportFormat.pdf, baseName: 'Scan_2026-11-09_10-00');

    test('one file with two image-only pages', () {
      expect(files, hasLength(1));
      final f = files.single;
      expect(f.name, 'Scan_2026-11-09_10-00.pdf');
      expect(f.mimeType, 'application/pdf');
      expect(latin(f.bytes.sublist(0, 5)), '%PDF-');
      expect(latin(f.bytes).trimRight(), endsWith('%%EOF'));
      final pdf = splitPdf(f.bytes);
      expect(pageCount(pdf.structure), 2);
      expect(RegExp(r'/Subtype\s*/Image').allMatches(pdf.structure).length, 2);
      expect(pdf.structure, contains('/DCTDecode'));
      // page size from pixels and dpi: 120 x 170 px at 100 dpi = 86.4 x 122.4 pt
      expect(pdf.structure, matches(RegExp(r'/MediaBox\s*\[\s*0\s+0\s+86\.4\s+122\.4\s*\]')));
      // each page content only places its image
      expect(pdf.contents, hasLength(2));
      for (final c in pdf.contents) {
        expect(c, contains(' cm'));
        expect(c, contains(' Do'));
        expect(RegExp(r'\b(BT|ET|Tj|TJ|Tf)\b').hasMatch(c), isFalse, reason: c);
      }
    });

    test('no text, no fonts, no metadata', () {
      final pdf = splitPdf(files.single.bytes);
      final all = latin(files.single.bytes);
      for (final banned in [
        '/Font',
        '/Info',
        '/Producer',
        '/Creator',
        '/Title',
        '/Author',
        '/CreationDate',
        '/ModDate',
        '/Metadata',
        'dart_pdf',
        'secret',
        'Exif',
      ]) {
        expect(pdf.structure, isNot(contains(banned)), reason: banned);
        expect(all, isNot(contains(banned)), reason: banned);
      }
    });

    test('split: one PDF per page', () {
      final split = exportPages(pages, ExportFormat.pdf, baseName: 'Scan', splitPdf: true);
      expect(split.map((f) => f.name), ['Scan_001.pdf', 'Scan_002.pdf']);
      for (final f in split) {
        expect(latin(f.bytes.sublist(0, 5)), '%PDF-');
        expect(pageCount(splitPdf(f.bytes).structure), 1);
      }
    });

    test('a single page split is just Scan.pdf', () {
      final one = exportPages(pages.take(1).toList(), ExportFormat.pdf, baseName: 'Scan', splitPdf: true);
      expect(one.single.name, 'Scan.pdf');
    });
  });

  group('JPG', () {
    final files = exportPages(pages, ExportFormat.jpg, baseName: 'Scan', jpegQuality: 80);

    test('one file per page, names', () {
      expect(files.map((f) => f.name), ['Scan_001.jpg', 'Scan_002.jpg']);
      expect(files.every((f) => f.mimeType == 'image/jpeg'), isTrue);
    });

    test('no EXIF/APP1, no text, decodes back', () {
      for (final f in files) {
        final markers = jpegMarkers(f.bytes);
        expect(markers, isNot(contains(0xE1)), reason: 'APP1 (EXIF/XMP)');
        expect(markers, isNot(contains(0xE2)), reason: 'APP2 (ICC)');
        expect(markers, isNot(contains(0xFE)), reason: 'COM');
        expect(containsBytes(f.bytes, ascii.encode('Exif')), isFalse);
        expect(containsBytes(f.bytes, ascii.encode('secret')), isFalse);
        final back = img.decodeJpg(f.bytes)!;
        expect((back.width, back.height), (120, 170));
        expect(back.exif.isEmpty, isTrue);
      }
    });

    test('colours survive (grey pages stay grey)', () {
      final colour = img.decodeJpg(files[0].bytes)!.getPixel(50, 50);
      expect([colour.r, colour.g, colour.b], [closeTo(100, 6), closeTo(50, 6), closeTo(205, 6)]);
      final grey = img.decodeJpg(files[1].bytes)!.getPixel(50, 50);
      expect([grey.r, grey.g, grey.b], everyElement(closeTo(100, 4)));
    });
  });

  group('PNG', () {
    final files = exportPages(pages, ExportFormat.png, baseName: 'Scan');

    test('no text/EXIF chunks, decodes back', () {
      expect(files.map((f) => f.name), ['Scan_001.png', 'Scan_002.png']);
      for (final f in files) {
        expect(f.mimeType, 'image/png');
        final chunks = pngChunks(f.bytes);
        expect(chunks.first, 'IHDR');
        expect(chunks.last, 'IEND');
        for (final banned in ['tEXt', 'iTXt', 'zTXt', 'eXIf', 'iCCP', 'tIME']) {
          expect(chunks, isNot(contains(banned)));
        }
        expect(containsBytes(f.bytes, ascii.encode('secret')), isFalse);
        final back = img.decodePng(f.bytes)!;
        expect((back.width, back.height), (120, 170));
        final p = back.getPixel(50, 50);
        expect(p.r, 100);
      }
    });

    test('one page keeps the plain name', () {
      final one = exportPages(pages.take(1).toList(), ExportFormat.png, baseName: 'a/b:c');
      expect(one.single.name, 'a_b_c.png');
    });
  });

  test('no pages, no files', () {
    expect(exportPages(const [], ExportFormat.pdf, baseName: 'x'), isEmpty);
  });
}
