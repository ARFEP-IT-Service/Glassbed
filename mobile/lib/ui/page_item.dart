import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import '../core/edit.dart' as ed;
import '../core/escl.dart';
import 'image_work.dart';

/// One scanned page in the current session: the untouched original, its edits and the
/// downscaled copies used for the editor preview and the thumbnail.
class PageItem {
  PageItem(this.page) : id = _nextId++;

  static int _nextId = 0;

  final int id;
  final ScannedPage page;
  ed.Edits edits = ed.Edits();

  img.Image? preview;
  img.Image? thumbBase;
  ui.Image? thumbnail;
  int _thumbGeneration = 0;

  Future<void>? _bases;

  img.Image get original => page.image;

  /// Creates the downscaled copies once (off the UI thread).
  Future<void> ensureBases() => _bases ??= makeBases(original).then((b) {
        preview = b.preview;
        thumbBase = b.thumb;
      });

  /// (Re)renders the thumbnail with the current edits; calls [onReady] when it is available.
  Future<void> refreshThumbnail(void Function() onReady) async {
    final generation = ++_thumbGeneration;
    await ensureBases();
    final pixels = await renderEdited(thumbBase!, original.width, edits);
    final image = await toUiImage(pixels);
    if (generation != _thumbGeneration) {
      image.dispose(); // a newer edit is already being rendered
      return;
    }
    thumbnail?.dispose();
    thumbnail = image;
    onReady();
  }

  void dispose() {
    _thumbGeneration++;
    thumbnail?.dispose();
    thumbnail = null;
  }
}
