import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/device_check.dart';
import '../../i18n.dart';
import '../../platform.dart';
import '../../version.dart';
import '../dialogs.dart';
import '../theme.dart';

/// Runs the device check for a host and returns the report text.
typedef DeviceChecker = Future<String> Function(String host);

/// The default checker: the real network check of this build. Android drops the mDNS and
/// WS-Discovery answers unless the multicast lock is held, so it is held throughout.
Future<String> runDeviceCheck(String host) async {
  try {
    await Native.acquireMulticastLock();
    return await deviceReport(host, appVersion: appVersion, flavor: appFlavor ?? 'unknown');
  } finally {
    await Native.releaseMulticastLock();
  }
}

/// "Device check": runs the check for [host], then shows the report to copy or share.
class DeviceCheckScreen extends StatefulWidget {
  const DeviceCheckScreen({super.key, required this.host, this.check = runDeviceCheck});

  final String host;

  /// Replaced in tests.
  final DeviceChecker check;

  @override
  State<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends State<DeviceCheckScreen> {
  String? _report;

  @override
  void initState() {
    super.initState();
    _run();
  }

  Future<void> _run() async {
    String report;
    try {
      report = await widget.check(widget.host).timeout(const Duration(seconds: 25));
    } catch (e) {
      report = 'Glassbed device check\nHost: ${widget.host}\nError: ${shortError(e)}\n';
    }
    if (mounted) setState(() => _report = report);
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report!));
    if (mounted) showSnack(context, tr('Copied.'));
  }

  Future<void> _share() async {
    await SharePlus.instance.share(ShareParams(text: _report!, subject: 'Glassbed device check'));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = Palette.of(context);
    final report = _report;
    return Scaffold(
      appBar: AppBar(title: Text(tr('Device check'))),
      body: SafeArea(
        child: report == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(tr('Checking the device…')),
                    const SizedBox(height: 4),
                    Text(widget.host, style: TextStyle(color: p.muted)),
                  ],
                ),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: SelectableText(
                        report.trimRight(),
                        style: const TextStyle(fontFamily: 'monospace', fontSize: 12.5, height: 1.4),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    tr("Send this report to the developer if the device does not work with Glassbed. It contains the device's address, model and supported protocols – nothing else."),
                    style: theme.textTheme.bodyMedium?.copyWith(color: p.muted),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: _copy,
                        icon: const Icon(Icons.copy),
                        label: Text(tr('Copy report')),
                      ),
                      FilledButton.icon(
                        onPressed: _share,
                        icon: const Icon(Icons.share),
                        label: Text(tr('Share report')),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
