import 'package:flutter/material.dart';

import '../../core/escl.dart';
import '../../i18n.dart';
import '../print/copies_stepper.dart';

const allResolutions = [100, 150, 200, 300];

/// Sources the scanner reports (both if capabilities are unknown).
List<ScanSource> availableSources(ScannerCaps? caps) {
  final sources = caps?.sources ?? const <ScanSource>[];
  return sources.isEmpty ? ScanSource.values : sources;
}

/// Colour modes of the source (B/W is made from a grey scan); all if unknown.
List<ColorMode> availableModes(ScannerCaps? caps, ScanSource source) {
  final modes = caps?.source(source)?.modes ?? const <ColorMode>[];
  return modes.isEmpty ? ColorMode.values : modes;
}

/// The app's resolutions (100/150/200/300) the source supports; all if unknown.
List<int> availableResolutions(ScannerCaps? caps, ScanSource source) {
  final dpis = caps?.source(source)?.dpiChoices ?? const <int>[];
  return dpis.isEmpty ? allResolutions : dpis;
}

/// Scan options and the big scan button (or progress with cancel while scanning).
class ScanCard extends StatelessWidget {
  const ScanCard({
    super.key,
    required this.caps,
    required this.source,
    required this.mode,
    required this.dpi,
    required this.scanning,
    required this.pagesThisRun,
    required this.hasPages,
    required this.onSource,
    required this.onMode,
    required this.onDpi,
    required this.onScan,
    required this.onCancel,
    required this.copyCopies,
    required this.onCopyCopies,
    required this.onCopy,
    required this.copyStatus,
    required this.onCancelCopy,
    this.available = true,
  });

  final ScannerCaps? caps;
  final ScanSource source;
  final ColorMode mode;
  final int dpi;
  final bool scanning;
  final int pagesThisRun;
  final bool hasPages;
  final ValueChanged<ScanSource> onSource;
  final ValueChanged<ColorMode> onMode;
  final ValueChanged<int> onDpi;
  final VoidCallback? onScan;
  final VoidCallback onCancel;

  /// Copy: scan and print right away at 100 %, without adding pages.
  final int copyCopies;
  final ValueChanged<int> onCopyCopies;
  final VoidCallback? onCopy;

  /// Progress text while a copy runs; null when no copy runs.
  final String? copyStatus;

  /// Cancels the copy; null while it cannot be cancelled any more (pages are being sent).
  final VoidCallback? onCancelCopy;

  /// False for a device without a scanner: options, scan and copy are shown but locked.
  final bool available;

  bool get _busy => scanning || copyStatus != null;

  /// Options and buttons are locked while busy or without a scanner.
  bool get _locked => _busy || !available;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sources = availableSources(caps);
    final modes = availableModes(caps, source);
    final resolutions = availableResolutions(caps, source);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Label(tr('Source')),
            SegmentedButton<ScanSource>(
              segments: [
                for (final s in sources)
                  ButtonSegment(
                    value: s,
                    icon: Icon(s == ScanSource.platen ? Icons.crop_landscape : Icons.layers_outlined),
                    label: Text(tr(s == ScanSource.platen ? 'Glass' : 'Feeder')),
                  ),
              ],
              selected: {source},
              showSelectedIcon: false,
              onSelectionChanged: _locked ? null : (v) => onSource(v.first),
            ),
            const SizedBox(height: 14),
            _Label(tr('Mode')),
            SegmentedButton<ColorMode>(
              segments: [
                for (final m in modes)
                  ButtonSegment(
                    value: m,
                    label: Text(tr(switch (m) {
                      ColorMode.color => 'Color',
                      ColorMode.gray => 'Gray',
                      ColorMode.bw => 'B/W',
                    })),
                  ),
              ],
              selected: {mode},
              showSelectedIcon: false,
              onSelectionChanged: _locked ? null : (v) => onMode(v.first),
            ),
            const SizedBox(height: 14),
            _Label(tr('Resolution')),
            SegmentedButton<int>(
              segments: [
                for (final r in resolutions) ButtonSegment(value: r, label: Text('$r')),
              ],
              selected: {dpi},
              showSelectedIcon: false,
              onSelectionChanged: _locked ? null : (v) => onDpi(v.first),
            ),
            const SizedBox(height: 18),
            if (scanning)
              _Progress(
                title: tr('Scanning…'),
                detail: tr('{n} page(s)', {'n': pagesThisRun}),
                onCancel: onCancel,
              )
            else if (copyStatus != null)
              _Progress(title: tr('Print copy'), detail: copyStatus!, onCancel: onCancelCopy)
            else
              SizedBox(
                height: 64,
                child: FilledButton.icon(
                  onPressed: available ? onScan : null,
                  icon: const Icon(Icons.document_scanner_outlined, size: 28),
                  label: Text(tr('Scan'), style: const TextStyle(fontSize: 20)),
                ),
              ),
            if (hasPages && !_locked) ...[
              const SizedBox(height: 8),
              Text(
                tr('Next scan is added to the current pages.'),
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 16),
            Divider(height: 1, color: theme.dividerColor),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: OutlinedButton.icon(
                      onPressed: _locked ? null : onCopy,
                      icon: const Icon(Icons.content_copy_outlined),
                      label: Text(tr('Print copy')),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                CopiesStepper(value: copyCopies, onChanged: _locked ? null : onCopyCopies),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              tr('Scans the original and prints it at 100 %. The copy is not added to the pages.'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}

class _Progress extends StatelessWidget {
  const _Progress({required this.title, required this.detail, required this.onCancel});

  final String title;
  final String detail;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 64,
      padding: const EdgeInsets.only(left: 16, right: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(32),
      ),
      child: Row(
        children: [
          const SizedBox.square(dimension: 24, child: CircularProgressIndicator(strokeWidth: 3)),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium, overflow: TextOverflow.ellipsis),
                Text(detail, style: theme.textTheme.bodySmall, overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
          if (onCancel != null)
          SizedBox(
            height: 52,
            child: OutlinedButton.icon(
              onPressed: onCancel,
              icon: const Icon(Icons.close),
              label: Text(tr('Cancel')),
            ),
          ),
        ],
      ),
    );
  }
}
