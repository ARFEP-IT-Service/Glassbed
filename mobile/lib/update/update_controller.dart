import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../platform.dart';
import '../version.dart';
import 'release.dart';
import 'update_client.dart';

const keyAsked = 'update_asked';
const keyEnabled = 'update_enabled';
const keyLastCheck = 'update_last_check';
const keySkipped = 'update_skipped';

/// State of the optional update check. Nothing connects to GitHub unless the user agreed
/// ([enabled]); the app downloads and installs nothing itself.
class UpdateController extends ChangeNotifier {
  UpdateController({
    http.Client Function()? newClient,
    Future<String?> Function()? deviceAbi,
    DateTime Function()? clock,
    this.currentVersion = appVersion,
  })  : _newClient = newClient ?? http.Client.new,
        _deviceAbi = deviceAbi ?? Native.deviceAbi,
        _clock = clock ?? DateTime.now;

  final http.Client Function() _newClient;
  final Future<String?> Function() _deviceAbi;
  final DateTime Function() _clock;
  final String currentVersion;

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
    notifyListeners();
  }

  /// What "Update" opens: the APK for this device, or the release page.
  Future<String> updateUrl() async {
    final r = release;
    if (r == null) return releasesPage;
    return r.updateUrl(await _deviceAbi());
  }

  String get pageUrl => release?.pageUrl ?? releasesPage;
}
