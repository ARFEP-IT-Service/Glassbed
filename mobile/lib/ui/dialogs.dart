import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../core/escl.dart';
import '../core/lan.dart';
import '../i18n.dart';
import '../platform.dart';

void showSnack(BuildContext context, String text, {bool error = false}) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(
      content: Text(text),
      backgroundColor: error ? Theme.of(context).colorScheme.error : null,
    ));
}

/// Messages of core errors that mean "no answer from the device".
final _unreachable = RegExp(r'did not answer in time|Cannot reach the', caseSensitive: false);

/// User-facing text for an error from the printer/scanner layer.
String errorText(Object e, {String fallback = 'Scan failed'}) {
  if (e is NotLocalNetwork) {
    return tr('Only devices on the local network can be used ({host}).', {'host': e.host});
  }
  if (e is ScannerBusy) return tr('The scanner is busy. Try again in a moment.');
  if (e is FeederEmpty) return tr('The document feeder is empty. Insert pages or use the glass.');
  if (e is ScanCancelled) return tr('Scan cancelled.');
  if (e is TimeoutException ||
      e is SocketException ||
      e is http.ClientException ||
      _unreachable.hasMatch(e.toString())) {
    return tr('The printer does not respond. Check the address and the Wi-Fi connection.');
  }
  return tr(fallback);
}

/// Yes/no question; true only if the user confirmed.
Future<bool> confirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool destructive = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) {
      final scheme = Theme.of(context).colorScheme;
      return AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(tr('Cancel')),
          ),
          FilledButton(
            style: destructive
                ? FilledButton.styleFrom(backgroundColor: scheme.error, foregroundColor: scheme.onError)
                : null,
            onPressed: () => Navigator.pop(context, true),
            child: Text(confirmLabel),
          ),
        ],
      );
    },
  );
  return result ?? false;
}

/// Makes sure the app may use the local network (Android 17+ runtime permission).
/// Explains why before the system dialog appears. Returns false if access is denied.
Future<bool> ensureLocalNetwork(BuildContext context) async {
  if (await Native.localNetworkAllowed()) return true;
  if (!context.mounted) return false;
  final go = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      icon: const Icon(Icons.wifi_find_outlined),
      title: Text(tr('Local network')),
      content: Text(tr(
          'Glassbed needs access to your local network to find and use your printer. It connects to nothing else.')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Not now'))),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Continue'))),
      ],
    ),
  );
  if (go != true) return false;
  final granted = await Native.requestLocalNetwork();
  if (!granted && context.mounted) {
    showSnack(
      context,
      tr('Without access to the local network Glassbed cannot reach your printer. You can allow it in the system settings.'),
      error: true,
    );
  }
  return granted;
}
