import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../platform.dart';
import '../version.dart';
import 'download.dart';
import 'installer.dart';
import 'release.dart';
import 'update_client.dart';

const keyAsked = 'update_asked';
const keyEnabled = 'update_enabled';
const keyLastCheck = 'update_last_check';
const keySkipped = 'update_skipped';

/// Where "Update" stands.
enum DownloadPhase { idle, downloading, verifying, installing }

/// What "Update" did, for the UI.
enum UpdateOutcome {
  /// No verifiable APK in this release (or no installer): open [UpdateController.updateUrl]
  /// in the browser as before.
  browser,

  /// Android's installer asks the user now.
  installStarted,

  /// The user first has to allow Glassbed to install apps, then tap "Update" again.
  needsPermission,

  cancelled,
  checksumMismatch,
  failed,

  /// A download is already running.
  busy,
}

/// State of the optional update check. Nothing connects to GitHub unless the user agreed
/// ([enabled]). An update is downloaded only when the user taps "Update", and Android's own
/// installer asks the user before anything is installed.
class UpdateController extends ChangeNotifier {
  UpdateController({
    http.Client Function()? newClient,
    Future<String?> Function()? deviceAbi,
    DateTime Function()? clock,
    ApkInstaller? installer,
    this.currentVersion = appVersion,
  })  : _newClient = newClient ?? http.Client.new,
        _deviceAbi = deviceAbi ?? Native.deviceAbi,
        _clock = clock ?? DateTime.now,
        _installer = installer ?? const PlatformApkInstaller();

  final http.Client Function() _newClient;
  final Future<String?> Function() _deviceAbi;
  final DateTime Function() _clock;
  final ApkInstaller _installer;
  final String currentVersion;

  /// Download state shown in the banner.
  DownloadPhase phase = DownloadPhase.idle;
  int received = 0;
  int? total;

  /// Result of the last "Update" (shown under the banner's buttons); null = nothing to say.
  UpdateOutcome? outcome;

  /// Message of the last failure ([UpdateOutcome.failed]).
  String? error;

  CancelToken? _token;
  http.Client? _downloadClient;
  int _notified = 0;

  /// The last verified APK (kept while the user allows installing apps).
  File? _verified;
  String? _verifiedVersion;
  String? _verifiedHash;

  bool get busy => phase != DownloadPhase.idle;

  bool _loaded = false;
  bool asked = false;
  bool enabled = false;
  String? skipped;
  String? lastCheck;

  /// The newest release from the last check (null before a check or if there is none).
  AndroidRelease? release;
  bool checking = false;
  bool _dismissed = false;   // "Later": hidden until the next check
  bool _forced = false;      // "Check now" also offers a skipped version

  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await _prefs;
    asked = prefs.getBool(keyAsked) ?? false;
    enabled = prefs.getBool(keyEnabled) ?? false;
    skipped = prefs.getString(keySkipped);
    lastCheck = prefs.getString(keyLastCheck);
    _loaded = true;
  }

  bool get needsQuestion => !asked;

  /// Called the moment the one-time question appears: it is never asked again, and
  /// whatever happens to it (back, closing the app) leaves the check switched off.
  Future<void> markAsked() async {
    asked = true;
    enabled = false;
    final prefs = await _prefs;
    await prefs.setBool(keyAsked, true);
    await prefs.setBool(keyEnabled, false);
  }

  /// Switching the check on or off in the settings also answers the question.
  Future<void> markAskedIfNeeded() async {
    if (asked) return;
    asked = true;
    await (await _prefs).setBool(keyAsked, true);
  }

  Future<void> setEnabled(bool value) async {
    enabled = value;
    await (await _prefs).setBool(keyEnabled, value);
    if (!value) {
      release = null;
      _forced = false;
    }
    notifyListeners();
  }

  /// The automatic check at start: only if switched on and the last one is a day old.
  Future<void> checkIfDue() async {
    await load();
    if (enabled && checkDue(lastCheck, _clock())) {
      try {
        await check(silent: true);
      } on UpdateError {
        // Silent: the next start tries again tomorrow.
      }
    }
  }

  /// Asks GitHub once (only if switched on). Returns the release if the banner offers it.
  /// [silent] (start-up check) never throws; otherwise an [UpdateError] is passed on.
  Future<AndroidRelease?> check({bool silent = false}) async {
    await load();
    if (!enabled || checking) return null;
    checking = true;
    notifyListeners();
    // Also counts when offline, so a failing check is not repeated at every start.
    lastCheck = _clock().toUtc().toIso8601String();
    await (await _prefs).setString(keyLastCheck, lastCheck!);
    final client = _newClient();
    try {
      final found = await fetchLatest(client);
      release = found;
      _dismissed = false;
      _forced = !silent && found != null && isNewer(found.version, currentVersion);
      return showBanner ? found : null;
    } on UpdateError {
      if (silent) return null;
      rethrow;
    } finally {
      client.close();
      checking = false;
      notifyListeners();
    }
  }

  bool get showBanner {
    final r = release;
    return r != null &&
        !_dismissed &&
        (_forced || shouldNotify(r, currentVersion, skipped)) &&
        isNewer(r.version, currentVersion);
  }

  /// Hides the banner until the next check.
  void later() {
    _dismissed = true;
    outcome = null;
    notifyListeners();
  }

  /// Never offers this version again (a newer one is offered).
  Future<void> skip() async {
    final r = release;
    if (r != null) {
      skipped = r.version;
      await (await _prefs).setString(keySkipped, r.version);
    }
    _dismissed = true;
    outcome = null;
    notifyListeners();
  }

  /// "Update": downloads the APK for this device and its checksum, verifies it and hands it
  /// to Android's installer (which asks the user). [UpdateOutcome.browser] means: no
  /// verifiable APK here – the caller opens [updateUrl] instead.
  Future<UpdateOutcome> downloadAndInstall() async {
    final r = release;
    if (r == null) return UpdateOutcome.browser;
    if (busy) return UpdateOutcome.busy;
    final abi = r.abiFor(await _deviceAbi());
    if (abi == null || !r.canInstallFor(abi)) return UpdateOutcome.browser;
    final dir = await _installer.updatesDir();
    if (dir == null) return UpdateOutcome.browser;

    outcome = null;
    error = null;
    received = 0;
    total = null;
    _notified = 0;
    phase = DownloadPhase.downloading;
    notifyListeners();
    try {
      final file = await _reuseVerified(r) ?? await _download(r, abi, dir);
      phase = DownloadPhase.installing;
      notifyListeners();
      final result = await _installer.install(file);
      return _finish(switch (result) {
        InstallResult.started => UpdateOutcome.installStarted,
        InstallResult.needsPermission => UpdateOutcome.needsPermission,
        InstallResult.unsupported => UpdateOutcome.browser,
      });
    } on DownloadCancelled {
      return _finish(UpdateOutcome.cancelled);
    } on ChecksumMismatch {
      return _finish(UpdateOutcome.checksumMismatch);
    } on UpdateError catch (e) {
      error = e.message;
      return _finish(UpdateOutcome.failed);
    } catch (e) {
      error = e.toString();
      return _finish(UpdateOutcome.failed);
    }
  }

  UpdateOutcome _finish(UpdateOutcome result) {
    phase = DownloadPhase.idle;
    _token = null;
    _downloadClient?.close();
    _downloadClient = null;
    outcome = result == UpdateOutcome.cancelled || result == UpdateOutcome.browser ? null : result;
    notifyListeners();
    return result;
  }

  /// A file verified by an earlier tap (e.g. before the user allowed installing apps), if it
  /// is still there and unchanged.
  Future<File?> _reuseVerified(AndroidRelease r) async {
    final file = _verified;
    if (file == null || _verifiedVersion != r.version || !await file.exists()) return null;
    phase = DownloadPhase.verifying;
    notifyListeners();
    if (await sha256OfFile(file) == _verifiedHash) return file;
    await file.delete();
    _verified = null;
    return null;
  }

  Future<File> _download(AndroidRelease r, String abi, Directory dir) async {
    phase = DownloadPhase.downloading;
    final token = _token = CancelToken();
    final client = _downloadClient = _newClient();
    final apk = await downloadUpdate(
      client,
      release: r,
      abi: abi,
      dir: dir,
      cancel: token,
      onProgress: (got, all) {
        received = got;
        total = all;
        // Not for every network chunk: about every 256 KB.
        if (got == 0 || got - _notified >= 256 * 1024 || got == all) {
          _notified = got;
          notifyListeners();
        }
      },
      onVerifying: () {
        phase = DownloadPhase.verifying;
        notifyListeners();
      },
    );
    _verified = apk.file;
    _verifiedVersion = r.version;
    _verifiedHash = apk.sha256;
    return apk.file;
  }

  /// Stops a running download; its partial file is deleted.
  void cancelDownload() {
    _token?.cancel();
    _downloadClient?.close();
  }

  /// What "Update" opens: the APK for this device, or the release page.
  Future<String> updateUrl() async {
    final r = release;
    if (r == null) return releasesPage;
    return r.updateUrl(await _deviceAbi());
  }

  String get pageUrl => release?.pageUrl ?? releasesPage;
}
