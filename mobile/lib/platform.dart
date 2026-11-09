import 'package:flutter/services.dart';

import 'core/export.dart';

/// Dart side of the Android platform channel (see MainActivity.kt).
class Native {
  Native._();

  static const _channel = MethodChannel('de.arfep.glassbed/platform');

  /// mDNS answers arrive as multicast; Android drops them unless a multicast lock is held.
  static Future<void> acquireMulticastLock() async {
    try {
      await _channel.invokeMethod<void>('acquireMulticastLock');
    } on MissingPluginException {
      // Not on Android (tests, desktop debug): nothing to do.
    }
  }

  static Future<void> releaseMulticastLock() async {
    try {
      await _channel.invokeMethod<void>('releaseMulticastLock');
    } on MissingPluginException {
      // See above.
    }
  }

  /// Whether the app may reach devices on the local network (always true below Android 17).
  static Future<bool> localNetworkAllowed() async {
    try {
      return await _channel.invokeMethod<bool>('localNetworkAllowed') ?? false;
    } on MissingPluginException {
      return true;
    }
  }

  /// Asks for the Android 17 local network permission; true if granted.
  static Future<bool> requestLocalNetwork() async {
    try {
      return await _channel.invokeMethod<bool>('requestLocalNetwork') ?? false;
    } on MissingPluginException {
      return true;
    }
  }

  /// The device's preferred ABI (e.g. "arm64-v8a"); null if unknown.
  static Future<String?> deviceAbi() async {
    try {
      return await _channel.invokeMethod<String>('deviceAbi');
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Lets the user pick a target with the system file picker and writes [files] there.
  /// One file: "save as" dialog; several: a folder. Returns how many were saved (0 = cancelled).
  static Future<int> saveFiles(List<ExportedFile> files) async {
    final count = await _channel.invokeMethod<int>('saveFiles', {
      'files': [
        for (final f in files) {'name': f.name, 'mimeType': f.mimeType, 'bytes': f.bytes},
      ],
    });
    return count ?? 0;
  }

  /// Opens the system document picker for PDFs and JPEG/PNG images (several at once).
  /// Returns the chosen files; an empty list if the user cancelled.
  static Future<List<OpenedFile>> pickDocuments() async {
    final raw = await _channel.invokeListMethod<Object?>('pickDocuments');
    return _openedFiles(raw);
  }

  /// Files shared to Glassbed by another app (and not yet taken); empty if none.
  static Future<List<OpenedFile>> takeSharedFiles() async {
    try {
      final raw = await _channel.invokeListMethod<Object?>('takeSharedFiles');
      return _openedFiles(raw);
    } on MissingPluginException {
      return const [];
    }
  }

  /// Calls [onShared] whenever another app shares files while Glassbed is running;
  /// fetch them with [takeSharedFiles].
  static void listenForShares(void Function() onShared) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'sharedFilesAvailable') onShared();
    });
  }

  /// Number of pages of a PDF (rendered by Android's PdfRenderer).
  static Future<int> pdfPageCount(Uint8List bytes) async {
    return await _channel.invokeMethod<int>('pdfPageCount', {'bytes': bytes}) ?? 0;
  }

  /// Renders page [index] (0-based) of a PDF at [dpi] on a white background.
  static Future<PdfPageImage> renderPdfPage(Uint8List bytes, int index, int dpi) async {
    final m = await _channel.invokeMapMethod<String, Object?>(
        'renderPdfPage', {'bytes': bytes, 'index': index, 'dpi': dpi});
    if (m == null) throw PlatformException(code: 'pdf_failed');
    return PdfPageImage(
      rgba: m['rgba']! as Uint8List,
      width: m['width']! as int,
      height: m['height']! as int,
      widthPt: (m['widthPt']! as num).toDouble(),
      heightPt: (m['heightPt']! as num).toDouble(),
    );
  }

  static List<OpenedFile> _openedFiles(List<Object?>? raw) => [
        for (final item in raw ?? const [])
          if (item is Map)
            OpenedFile(
              name: item['name'] as String? ?? 'file',
              mimeType: item['mimeType'] as String? ?? '',
              bytes: item['bytes'] as Uint8List?,
            ),
      ];
}

/// A file from the document picker or a share. [bytes] is null if it could not be read.
class OpenedFile {
  const OpenedFile({required this.name, required this.mimeType, required this.bytes});

  final String name;
  final String mimeType;
  final Uint8List? bytes;
}

/// A rendered PDF page: RGBA pixels and the page size in points (1/72 inch).
class PdfPageImage {
  const PdfPageImage({
    required this.rgba,
    required this.width,
    required this.height,
    required this.widthPt,
    required this.heightPt,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final double widthPt;
  final double heightPt;
}
