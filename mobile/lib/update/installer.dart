import 'dart:io';

import 'package:flutter/services.dart';

/// What happened when a verified APK was handed to Android.
enum InstallResult {
  /// Android's package installer is open and asks the user to confirm.
  started,

  /// Glassbed may not install apps yet; Android's settings page for that was opened.
  needsPermission,

  /// This build cannot install updates (no installer on this platform).
  unsupported,
}

/// Hands a downloaded APK to Android. Replaceable in tests.
abstract class ApkInstaller {
  /// The private cache folder for downloads (cache/updates), or null if unavailable.
  Future<Directory?> updatesDir();

  /// Opens Android's installer for [apk] (a file in [updatesDir]).
  Future<InstallResult> install(File apk);

  /// Whether Glassbed may install apps now (after [InstallResult.needsPermission]).
  Future<bool> canInstall();
}

/// The Android side lives in UpdateInstaller.kt (github build only; the play build has a
/// twin that installs nothing).
class PlatformApkInstaller implements ApkInstaller {
  const PlatformApkInstaller();

  static const _channel = MethodChannel('de.arfep.glassbed/platform');

  @override
  Future<Directory?> updatesDir() async {
    try {
      final path = await _channel.invokeMethod<String>('updatesDir');
      return path == null ? null : Directory(path);
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<bool> canInstall() async {
    try {
      return await _channel.invokeMethod<bool>('canInstallUpdates') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<InstallResult> install(File apk) async {
    try {
      final r = await _channel.invokeMethod<String>('installUpdate', {'path': apk.path});
      return switch (r) {
        'started' => InstallResult.started,
        'needs_permission' => InstallResult.needsPermission,
        _ => InstallResult.unsupported,
      };
    } on MissingPluginException {
      return InstallResult.unsupported;
    }
  }
}
