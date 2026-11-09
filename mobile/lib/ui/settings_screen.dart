import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../i18n.dart';
import 'dialogs.dart';
import 'theme.dart';

const appVersion = '0.1.0';
const _company = 'ARFEP IT-Service';
final _legalNotice = Uri.parse('https://arfep.de/impressum');
final _privacy = Uri.parse('https://arfep.de/datenschutz-glassbed');
final _website = Uri.parse('https://arfep.de/');

/// Language and information about the app.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = Palette.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(tr('Settings'))),
      body: SafeArea(
        child: ValueListenableBuilder<String?>(
          valueListenable: languageSetting,
          builder: (context, language, _) => ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
            children: [
              _Header(tr('Language')),
              Card(
                child: RadioGroup<String>(
                  groupValue: language ?? '',
                  onChanged: (v) => setLanguage(v == null || v.isEmpty ? null : v),
                  child: Column(
                    children: [
                      RadioListTile<String>(value: '', title: Text(tr('System'))),
                      for (final e in supportedLanguages.entries)
                        RadioListTile<String>(value: e.key, title: Text(e.value)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              _Header(tr('About')),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Image.asset('assets/icon/glassbed.png', width: 56, height: 56),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('Glassbed', style: theme.textTheme.titleLarge),
                                Text(
                                  tr('Version {version} · MIT license', {'version': appVersion}),
                                  style: TextStyle(color: p.muted),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 14),
                      Text(tr('Glassbed is an open-source project by {company}.',
                          {'company': _company})),
                      const SizedBox(height: 6),
                      Text(
                        tr('Glassbed only talks to your printer on the local network. No accounts, no tracking.'),
                        style: TextStyle(color: p.muted),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    _LinkTile(
                      icon: Icons.business_outlined,
                      title: 'arfep.de',
                      subtitle: tr('IT service · Göttingen & nationwide'),
                      uri: _website,
                    ),
                    _LinkTile(icon: Icons.gavel_outlined, title: tr('Legal notice'), uri: _legalNotice),
                    _LinkTile(icon: Icons.privacy_tip_outlined, title: tr('Privacy'), uri: _privacy),
                    ListTile(
                      minTileHeight: 56,
                      leading: const Icon(Icons.description_outlined),
                      title: Text(tr('Third-party licenses')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showLicensePage(
                        context: context,
                        applicationName: 'Glassbed',
                        applicationVersion: appVersion,
                        applicationIcon: Padding(
                          padding: const EdgeInsets.all(8),
                          child: Image.asset('assets/icon/glassbed.png', width: 48, height: 48),
                        ),
                        applicationLegalese:
                            '© 2026 Halil Ayberk Bulut ($_company) and Glassbed contributors · MIT',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.icon, required this.title, required this.uri, this.subtitle});

  final IconData icon;
  final String title;
  final String? subtitle;
  final Uri uri;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      minTileHeight: 56,
      leading: Icon(icon),
      title: Text(title),
      subtitle: subtitle == null ? null : Text(subtitle!),
      trailing: const Icon(Icons.open_in_new, size: 20),
      // The browser is opened only on tap; the app itself never loads these pages.
      onTap: () async {
        final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!ok && context.mounted) showSnack(context, uri.toString());
      },
    );
  }
}
