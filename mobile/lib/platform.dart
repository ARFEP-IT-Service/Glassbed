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
}
