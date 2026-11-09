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

  /// "Update": opens the APK (or the release page) in the browser – nothing is downloaded
  /// or installed by the app itself.
  Future<void> update(BuildContext context) async {
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

/// "Glassbed X is available" under the printer card; empty while there is nothing to offer.
class UpdateBanner extends StatelessWidget {
  const UpdateBanner({super.key, required this.extras});

  final UpdateExtras extras;

  @override
  Widget build(BuildContext context) {
    final c = extras.controller;
    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final release = c.release;
        if (!c.showBanner || release == null) return const SizedBox.shrink();
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
                ],
              ),
            ),
          ),
        );
      },
    );
  }
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
    try {
      final offered = await _c.check();
      text = offered != null
          ? tr('Glassbed {version} is available', {'version': offered.version})
          : tr('Glassbed {version} is up to date.', {'version': _c.currentVersion});
    } on UpdateError catch (e) {
      text = tr('Could not check for updates: {error}', {'error': e.message});
    }
    if (mounted) setState(() => _result = text);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return ListenableBuilder(
      listenable: _c,
      builder: (context, _) => Card(
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
                  : (_result == null ? null : Text(_result!)),
              onTap: _checkNow,
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
      ),
    );
  }
}
