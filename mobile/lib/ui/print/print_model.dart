import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/device.dart';
import '../../core/page_range.dart';
import '../../core/print_layout.dart';
import '../../platform.dart';
import '../image_work.dart';
import 'print_runner.dart';

const _prefMedia = 'print_media';
const _prefColor = 'print_color';

/// Resolution of the page thumbnails of PDFs (A4 → about 300 × 420 pixels).
const _thumbDpi = 36;

enum DocKind { pdf, image }

/// A file on the print list: its bytes, page count and page thumbnails.
class PrintDoc {
  PrintDoc._(this.name, this.bytes, this.kind, this.pageCount)
      : id = _nextId++,
        thumbs = List<ui.Image?>.filled(pageCount, null);

  static int _nextId = 0;

  final int id;
  final String name;
  final Uint8List bytes;
  final DocKind kind;
  final int pageCount;
  final List<ui.Image?> thumbs;
  bool _disposed = false;

  void _dispose() {
    _disposed = true;
    for (var i = 0; i < thumbs.length; i++) {
      thumbs[i]?.dispose();
      thumbs[i] = null;
    }
  }
}

/// One page of the print list: page [index] of [doc].
typedef PrintPageRef = ({PrintDoc doc, int index});

/// State of the Print section: files, options and the running job.
class PrintModel extends ChangeNotifier {
  final List<PrintDoc> docs = [];
  final pageRange = TextEditingController();

  int copies = 1;
  bool color = true;
  bool manualDuplex = false;
  String media = mediaA4;

  /// Paper sizes offered: from the printer if known, else A4 and Letter.
  List<String> mediaChoices = const [mediaA4, mediaLetter];

  int _opening = 0;
  bool get opening => _opening > 0;

  /// While a job runs: the progress text (key + args) and 0..1 (null = indeterminate).
  PrintStatus? status;
  bool get busy => status != null;

  PrintModel() {
    pageRange.addListener(notifyListeners);
    _restore();
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    color = prefs.getBool(_prefColor) ?? color;
    final m = prefs.getString(_prefMedia);
    if (m != null && mediaSizeMm(m) != null) media = m;
    notifyListeners();
  }

  Future<void> _store() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefColor, color);
    await prefs.setString(_prefMedia, media);
  }

  @override
  void dispose() {
    for (final d in docs) {
      d._dispose();
    }
    pageRange.dispose();
    super.dispose();
  }

  // ------------------------------------------------------------------ options

  void setCopies(int v) {
    copies = v.clamp(1, 99);
    notifyListeners();
  }

  void setColor(bool v) {
    color = v;
    _store();
    notifyListeners();
  }

  void setMedia(String v) {
    media = v;
    _store();
    notifyListeners();
  }

  void setManualDuplex(bool v) {
    manualDuplex = v;
    notifyListeners();
  }

  /// Takes the paper sizes of the connected printer; keeps the choice if it is supported.
  void setPrinterMedia(List<String> supported, String? defaultMedia) {
    final known = [
      for (final m in supported)
        if (mediaLabels.containsKey(m)) m,
    ];
    mediaChoices = known.isEmpty ? const [mediaA4, mediaLetter] : known;
    if (!mediaChoices.contains(media)) {
      media = defaultMedia != null && mediaChoices.contains(defaultMedia)
          ? defaultMedia
          : mediaChoices.first;
    }
    notifyListeners();
  }

  // ------------------------------------------------------------------ files

  List<PrintPageRef> get pages => [
        for (final d in docs)
          for (var i = 0; i < d.pageCount; i++) (doc: d, index: i),
      ];

  int get pageCount => docs.fold(0, (n, d) => n + d.pageCount);

  /// The 0-based pages the range field selects, or null if the text is invalid.
  Set<int>? get selectedPages {
    try {
      return parsePageRange(pageRange.text, pageCount).toSet();
    } on FormatException {
      return null;
    }
  }

  /// Adds the files; returns user messages for those that could not be opened.
  Future<List<PrintMessage>> addFiles(List<OpenedFile> files) async {
    final problems = <PrintMessage>[];
    _opening++;
    notifyListeners();
    try {
      for (final f in files) {
        final kind = _kindOf(f);
        final bytes = f.bytes;
        if (kind == null) {
          problems.add(PrintMessage('Only PDF, JPEG and PNG files can be printed.'));
          continue;
        }
        if (bytes == null || bytes.isEmpty) {
          problems.add(PrintMessage('Could not open file', {'name': f.name}));
          continue;
        }
        try {
          final count = kind == DocKind.pdf ? await Native.pdfPageCount(bytes) : 1;
          if (count < 1) throw const FormatException('No pages');
          final doc = PrintDoc._(f.name, bytes, kind, count);
          docs.add(doc);
          notifyListeners();
          _loadThumbnails(doc);
        } catch (_) {
          problems.add(PrintMessage('Could not open file', {'name': f.name}));
        }
      }
    } finally {
      _opening--;
      notifyListeners();
    }
    return problems;
  }

  static DocKind? _kindOf(OpenedFile f) {
    final mime = f.mimeType.toLowerCase();
    final ext = f.name.contains('.') ? f.name.split('.').last.toLowerCase() : '';
    if (mime == 'application/pdf' || ext == 'pdf') return DocKind.pdf;
    if (mime == 'image/jpeg' || mime == 'image/png' || const {'jpg', 'jpeg', 'png'}.contains(ext)) {
      return DocKind.image;
    }
    return null;
  }

  Future<void> _loadThumbnails(PrintDoc doc) async {
    for (var i = 0; i < doc.pageCount; i++) {
      if (doc._disposed) return;
      try {
        final Pixels pixels;
        if (doc.kind == DocKind.pdf) {
          final p = await Native.renderPdfPage(doc.bytes, i, _thumbDpi);
          pixels = (rgba: p.rgba, width: p.width, height: p.height);
        } else {
          pixels = await imageFileThumbnail(doc.bytes);
        }
        final image = await toUiImage(pixels);
        if (doc._disposed) {
          image.dispose();
          return;
        }
        doc.thumbs[i] = image;
        notifyListeners();
      } catch (e) {
        debugPrint('thumbnail ${doc.name} #$i: $e');
      }
    }
  }

  void remove(PrintDoc doc) {
    docs.remove(doc);
    doc._dispose();
    notifyListeners();
  }

  void clear() {
    for (final d in docs) {
      d._dispose();
    }
    docs.clear();
    notifyListeners();
  }

  // ------------------------------------------------------------------ printing

  /// Prints the selected pages. With manual duplex the fronts go first; [askBackSides]
  /// asks the user to reinsert the stack and decides whether the backs follow.
  /// Throws [PrintMessage] for input problems and the core errors for printer problems.
  Future<void> printSelected(Device device, {required Future<bool> Function() askBackSides}) async {
    final all = pages;
    final List<int> selected;
    try {
      selected = parsePageRange(pageRange.text, all.length);
    } on FormatException {
      throw const PrintMessage('Invalid page range.');
    }
    if (selected.isEmpty) throw const PrintMessage('Nothing to print.');
    final jobName = docs.length == 1 ? docs.first.name : 'Glassbed';

    if (manualDuplex && selected.length > 1) {
      final (fronts, backs) = duplexPlan(selected);
      // Each pass is one stack of single sheets: copies would mix up the order.
      await _send(device, [for (final i in fronts) all[i]], copies: 1, jobName: jobName);
      if (!await askBackSides()) return;
      await _send(device, [for (final i in backs) i == null ? null : all[i]],
          copies: 1, jobName: jobName);
    } else {
      await _send(device, [for (final i in selected) all[i]], copies: copies, jobName: jobName);
    }
  }

  /// [pages] null entries are blank sheets.
  Future<void> _send(Device device, List<PrintPageRef?> pages,
      {required int copies, required String jobName}) async {
    status = const PrintStatus.preparing(0, 0);
    notifyListeners();
    try {
      await runPrint(
        device: device,
        count: pages.length,
        source: (i) => _source(pages[i]),
        media: media,
        color: color,
        copies: copies,
        jobName: jobName,
        onStatus: (s) {
          status = s;
          notifyListeners();
        },
      );
    } finally {
      status = null;
      notifyListeners();
    }
  }

  Future<PrintSource> _source(PrintPageRef? ref) async {
    if (ref == null) return const PrintSource.blank();
    final doc = ref.doc;
    if (doc.kind == DocKind.pdf) {
      final p = await Native.renderPdfPage(doc.bytes, ref.index, printDpi);
      final rgba = p.rgba, w = p.width, h = p.height;
      final bitmap = await Isolate.run(() => rgbaToRgb(rgba, w, h));
      return PrintSource.pdfPage(bitmap, p.widthPt, p.heightPt);
    }
    final bytes = doc.bytes;
    return PrintSource.image(await Isolate.run(() => decodeImageFile(bytes)));
  }

  /// A preview of page [ref] as it lands on the paper (low resolution).
  Future<Pixels> preview(PrintPageRef ref) async {
    const dpi = 100;
    final PrintSource src;
    if (ref.doc.kind == DocKind.pdf) {
      final p = await Native.renderPdfPage(ref.doc.bytes, ref.index, dpi);
      final rgba = p.rgba, w = p.width, h = p.height;
      src = PrintSource.pdfPage(await Isolate.run(() => rgbaToRgb(rgba, w, h)), p.widthPt, p.heightPt);
    } else {
      final bytes = ref.doc.bytes;
      src = PrintSource.image(await Isolate.run(() => downscale(decodeImageFile(bytes), 1600)));
    }
    final media = this.media, color = this.color;
    return Isolate.run(() => pixelsOf(layoutForPrint(src, media, color, dpi: dpi)));
  }
}

/// Short names of the paper sizes the app offers.
const mediaLabels = {
  mediaA4: 'A4',
  mediaLetter: 'Letter',
  'na_legal_8.5x14in': 'Legal',
  'iso_a5_148x210mm': 'A5',
};
