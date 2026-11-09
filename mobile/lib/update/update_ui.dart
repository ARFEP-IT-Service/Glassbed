import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../app_extras.dart';
import '../i18n.dart';
import '../ui/dialogs.dart';
import '../ui/theme.dart';
import 'update_client.dart' show UpdateError;
import 'update_controller.dart';
import 'update_texts.dart';

/// The privacy section on the update check (opens only on tap).
final learnMoreUrl = Uri.parse('https://arfep.de/datenschutz-glassbed#update-pruefung');

/// Opens [url] in the browser. Replaceable in tests.
typedef UrlOpener = Future<bool> Function(Uri url);

Future<bool> _openInBrowser(Uri url) => launchUrl(url, mode: LaunchMode.externalApplication);

/// The update notice of the GitHub build: one-time question, banner and settings rows.
class UpdateExtras implements AppExtras {
  UpdateExtras(this.controller, {UrlOpener? openUrl}) : openUrl = openUrl ?? _openInBrowser;

  final UpdateController controller;
  final UrlOpener openUrl;

  @override
  void onHomeReady(BuildContext context) => start(context);

  @override
  String? get privacyNote => tr(privacyNoteText);

  /// Asks the one-time question, or runs the daily check if it was already answered.
  Future<void> start(BuildContext context) async {
    await controller.load();
    if (!context.mounted) return;
    if (controller.needsQuestion) {
      await askConsent(context);
    } else {
      await controller.checkIfDue();
    }
  }

  /// "Check for updates?" – asked once. No is the default; back and tapping outside mean No.
  Future<void> askConsent(BuildContext context) async {
    await controller.markAsked();
    if (!context.mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Check for updates?')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr(consentText)),
            const SizedBox(height: 4),
            TextButton.icon(
              style: TextButton.styleFrom(padding: EdgeInsets.zero),
              icon: const Icon(Icons.open_in_new, size: 18),
              label: Text(tr('Learn more')),
              onPressed: () => openUrl(learnMoreUrl),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Yes'))),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('No')),
          ),
        ],
      ),
    );
    if (yes == true) {
      await controller.setEnabled(true);
      await controller.check(silent: true);
    }
  }

  @override
  Widget homeBanner(BuildContext context) => UpdateBanner(extras: this);

  @override
  List<Widget> settingsSection(BuildContext context) => [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
          child: Text(tr('Updates'), style: Theme.of(context).textTheme.titleSmall),
        ),
        UpdateSettings(extras: this),
        const SizedBox(height: 20),
      ];

  /// "Update": downloads and verifies the APK and hands it to Android's installer, which asks
  /// the user. Progress and the result appear in the banner. Without a verifiable APK in the
  /// release, the APK (or the release page) opens in the browser as before.
  Future<void> update(BuildContext context) async {
    final outcome = await controller.downloadAndInstall();
    if (outcome != UpdateOutcome.browser || !context.mounted) return;
    await openInBrowser(context);
  }

  /// "Update" in the settings: back to the home screen first, where the banner shows the
  /// progress. The navigator's own context stays mounted for the browser fallback.
  void updateFromSettings(BuildContext context) {
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    update(navigator.context);
  }

  bool _continuing = false;

  /// Back in the app: after "allow installing apps" the update goes on by itself (with the
  /// file verified before); otherwise the daily check runs if it is due.
  Future<void> onResumed(BuildContext context) async {
    if (controller.outcome == UpdateOutcome.needsPermission) {
      await continueAfterPermission(context);
    } else if (!controller.busy) {
      await controller.checkIfDue();
    }
  }

  /// Runs "Update" again once the user has allowed Glassbed to install apps. Without the
  /// permission nothing happens and the hint stays.
  Future<void> continueAfterPermission(BuildContext context) async {
    if (_continuing) return;
    _continuing = true;
    try {
      if (controller.busy || controller.outcome != UpdateOutcome.needsPermission) return;
      if (!await controller.canInstall()) return;
      if (!context.mounted || controller.busy) return;
      await update(context);
    } finally {
      _continuing = false;
    }
  }

  /// Opens the APK (or the release page) in the browser and explains the install.
  Future<void> openInBrowser(BuildContext context) async {
    final url = await controller.updateUrl();
    final ok = await openUrl(Uri.parse(url));
    if (!context.mounted) return;
    if (!ok) {
      showSnack(context, url);
      return;
    }
    final release = controller.release;
    if (release == null || url == release.pageUrl) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Glassbed {version} is downloading in your browser',
            {'version': release.version})),
        content: Text('${tr(installHint)}\n\n${tr(unknownAppsHint)}'),
        actions: [
          FilledButton(onPressed: () => Navigator.pop(context), child: Text(tr('Done'))),
        ],
      ),
    );
  }
}

/// Megabytes with one decimal, with a decimal comma in German and Turkish.
String megabytes(int bytes) {
  final text = (bytes / (1024 * 1024)).toStringAsFixed(1);
  return currentLanguage == 'en' ? text : text.replaceAll('.', ',');
}

/// "Glassbed X is available" under the printer card; empty while there is nothing to offer.
/// While an update downloads it shows the progress and "Cancel". Coming back to the app
/// continues an update that waited for the install permission.
class UpdateBanner extends StatefulWidget {
  const UpdateBanner({super.key, required this.extras});

  final UpdateExtras extras;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> with WidgetsBindingObserver {
  UpdateExtras get extras => widget.extras;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) extras.onResumed(context);
  }

  @override
  Widget build(BuildContext context) {
    final c = extras.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final release = c.release;
        if (!(c.showBanner || c.busy) || release == null) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.system_update_outlined, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          tr('Glassbed {version} is available', {'version': release.version}),
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (c.busy) ..._progress(context, c, release.version) else ...[
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        FilledButton(
                          onPressed: () => extras.update(context),
                          child: Text(tr('Update')),
                        ),
                        TextButton(
                          onPressed: () => extras.openUrl(Uri.parse(c.pageUrl)),
                          child: Text(tr("What's new")),
                        ),
                        TextButton(onPressed: c.later, child: Text(tr('Later'))),
                        TextButton(onPressed: c.skip, child: Text(tr('Skip this version'))),
                      ],
                    ),
                    if (_outcomeText(c, release.version) case final text?)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, bottom: 4),
                        child: Text(
                          text,
                          style: _isError(c.outcome)
                              ? TextStyle(color: Theme.of(context).colorScheme.error)
                              : null,
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  List<Widget> _progress(BuildContext context, UpdateController c, String version) {
    final downloading = c.phase == DownloadPhase.downloading;
    final total = c.total;
    final String label;
    if (!downloading) {
      label = tr(verifyingText);
    } else if (total != null && total > 0) {
      label = tr(downloadingOfText,
          {'version': version, 'done': megabytes(c.received), 'total': megabytes(total)});
    } else {
      label = tr(downloadingText, {'version': version, 'done': megabytes(c.received)});
    }
    return [
      Text(label),
      const SizedBox(height: 8),
      LinearProgressIndicator(
        value: downloading && total != null && total > 0 ? c.received / total : null,
      ),
      const SizedBox(height: 4),
      Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton(
          onPressed: downloading ? c.cancelDownload : null,
          child: Text(tr('Cancel')),
        ),
      ),
    ];
  }

  static bool _isError(UpdateOutcome? o) =>
      o == UpdateOutcome.checksumMismatch || o == UpdateOutcome.failed;

  static String? _outcomeText(UpdateController c, String version) => switch (c.outcome) {
        UpdateOutcome.installStarted => tr(installStartedText, {'version': version}),
        UpdateOutcome.needsPermission => tr(allowInstallText),
        UpdateOutcome.checksumMismatch => tr(checksumMismatchText),
        UpdateOutcome.failed => tr(downloadFailedText, {'error': c.error ?? ''}),
        _ => null,
      };
}

/// Settings rows: the switch, "Check now" with its result, and "Learn more".
class UpdateSettings extends StatefulWidget {
  const UpdateSettings({super.key, required this.extras});

  final UpdateExtras extras;

  @override
  State<UpdateSettings> createState() => _UpdateSettingsState();
}

class _UpdateSettingsState extends State<UpdateSettings> {
  String? _result;
  bool _resultOffers = false; // the result is "X is available" (the Update row says it then)

  UpdateController get _c => widget.extras.controller;

  @override
  void initState() {
    super.initState();
    _c.load().then((_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _checkNow() async {
    setState(() => _result = null);
    String text;
    var offers = false;
    try {
      final offered = await _c.check();
      offers = offered != null;
      text = offered != null
          ? tr('Glassbed {version} is available', {'version': offered.version})
          : tr('Glassbed {version} is up to date.', {'version': _c.currentVersion});
    } on UpdateError catch (e) {
      text = tr('Could not check for updates: {error}', {'error': e.message});
    }
    if (mounted) {
      setState(() {
        _result = text;
        _resultOffers = offers;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) {
        // The same offer as the banner on the home screen (also from the daily check).
        final offered = _c.showBanner || _c.busy ? _c.release : null;
        final result = offered != null && _resultOffers ? null : _result;
        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SwitchListTile(
                value: _c.enabled,
                title: Text(tr('Check for updates')),
                subtitle: Text(tr(settingsHint), style: TextStyle(color: p.muted)),
                onChanged: (v) async {
                  await _c.markAskedIfNeeded();
                  await _c.setEnabled(v);
                  if (mounted) setState(() => _result = null);
                },
              ),
              ListTile(
                minTileHeight: 56,
                enabled: _c.enabled && !_c.checking,
                leading: _c.checking
                    ? const SizedBox(
                        width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.refresh),
                title: Text(tr('Check now')),
                subtitle: _c.checking
                    ? Text(tr('Checking…'))
                    : (result == null ? null : Text(result)),
                onTap: _checkNow,
              ),
              if (offered != null)
                ListTile(
                  key: const ValueKey('settings-update'),
                  minTileHeight: 56,
                  enabled: !_c.busy,
                  leading: Icon(Icons.system_update_outlined,
                      color: _c.busy ? null : Theme.of(context).colorScheme.primary),
                  title: Text(tr('Update')),
                  subtitle: Text(tr('Glassbed {version} is available', {'version': offered.version})),
                  onTap: () => widget.extras.updateFromSettings(context),
                ),
              ListTile(
                minTileHeight: 56,
                leading: const Icon(Icons.privacy_tip_outlined),
                title: Text(tr('Learn more')),
                trailing: const Icon(Icons.open_in_new, size: 20),
                onTap: () => widget.extras.openUrl(learnMoreUrl),
              ),
            ],
          ),
        );
      },
    );
  }
}
