import 'dart:async';

import '../../core/device.dart';
import '../../core/ipp.dart';
import '../../core/print_layout.dart';
import '../../core/printing.dart';
import '../../i18n.dart';
import '../dialogs.dart';

export '../../core/print_layout.dart' show PrintSource;

/// A message for the user (key of [tr]) with optional placeholders.
class PrintMessage implements Exception {
  const PrintMessage(this.key, [this.args = const {}]);

  final String key;
  final Map<String, Object?> args;
}

/// Progress of a print or copy job for the UI.
class PrintStatus {
  const PrintStatus.scanning(this.page)
      : _phase = _Phase.scanning,
        total = 0;
  const PrintStatus.preparing(this.page, this.total) : _phase = _Phase.preparing;
  const PrintStatus.sending()
      : _phase = _Phase.sending,
        page = 0,
        total = 0;

  final _Phase _phase;
  final int page;
  final int total;

  String get text => switch (_phase) {
        _Phase.scanning => '${tr('Scanning…')} ${tr('{n} page(s)', {'n': page})}',
        _Phase.preparing when total > 0 => tr('Preparing page {i} of {n}…', {'i': page, 'n': total}),
        _ => tr('Printing…'),
      };

  /// 0..1 while pages are prepared; null (indeterminate) otherwise.
  double? get fraction =>
      _phase == _Phase.preparing && total > 0 ? (page / total).clamp(0.0, 1.0) : null;
}

enum _Phase { scanning, preparing, sending }

/// Paper sizes of the printer (null if it does not answer).
Future<({List<String> supported, String? defaultMedia})?> loadPrinterMedia(Device device) async {
  try {
    final caps = await getPrinterCaps(device.ippUri, timeout: const Duration(seconds: 6));
    return (supported: caps.mediaSupported, defaultMedia: caps.mediaDefault);
  } catch (_) {
    return null;
  }
}

/// Manual duplex: (fronts, backs) as page indices; a null back is a blank sheet.
(List<int>, List<int?>) duplexPlan(List<int> selected) => manualDuplexPlan(selected);

/// Prints [count] pages; [source] delivers page i (0-based) when it is needed, so only
/// one full-size page is in memory at a time. Throws the errors of [printPages].
Future<void> runPrint({
  required Device device,
  required int count,
  required Future<PrintSource> Function(int i) source,
  required String media,
  required bool color,
  required int copies,
  required String jobName,
  required void Function(PrintStatus status) onStatus,
}) async {
  onStatus(PrintStatus.preparing(0, count));
  await for (final p in printPages(
    device.ippUri,
    pageCount: count,
    loadPage: source,
    media: media,
    color: color,
    copies: copies,
    jobName: jobName,
  )) {
    onStatus(p.stage == PrintStage.preparing
        ? PrintStatus.preparing(p.page, p.total)
        : const PrintStatus.sending());
  }
}

/// Text for a [PrintMessage]; "Could not open file" gets the file name appended.
String messageText(PrintMessage m) {
  final name = m.args['name'];
  final text = tr(m.key, m.args);
  return name == null ? text : '$text: $name';
}

/// User-facing text for an error while printing or copying.
String printErrorText(Object e) {
  if (e is PrintMessage) return messageText(e);
  if (e is PrintFailed) return problemText(e.problem);
  if (e is NoSupportedFormat) return tr('The printer cannot print this format.');
  if (e is IppError) {
    // client-error-document-format-not-supported / -attributes-or-values-not-supported
    if (e.status == 0x040A || e.status == 0x040B) {
      return tr('The printer cannot print this format.');
    }
    if (e.status == 0x0507 || e.status == 0x0506) return problemText(PrintProblem.busy);
    if (e.status != null) return tr('The printer rejected the job.');
  }
  return errorText(e, fallback: 'Print failed');
}

String problemText(PrintProblem p) => tr(switch (p) {
      PrintProblem.mediaEmpty => 'The printer is out of paper. Load paper and try again.',
      PrintProblem.mediaJam => 'Paper jam. Remove the jammed paper and try again.',
      PrintProblem.doorOpen => 'A cover or door of the printer is open. Close it and try again.',
      PrintProblem.tonerEmpty => 'The toner is empty. Replace the cartridge and try again.',
      PrintProblem.paused => 'The printer is paused. Resume it on the printer and try again.',
      PrintProblem.busy => 'The printer is busy. Try again in a moment.',
      PrintProblem.other => "The printer reports a problem. Check the printer's display.",
    });
