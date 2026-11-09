import 'package:flutter/material.dart';

import '../../core/device.dart';
import '../../core/ipp.dart';
import '../../device_texts.dart';
import '../../i18n.dart';
import '../print/print_runner.dart' show problemText;
import '../theme.dart';

/// Connection state of the selected printer.
enum Link { none, connecting, online, offline }

/// Below this level (percent) a toner is shown as low, like in the Windows app.
const tonerLowThreshold = 15;

/// Compact buttons next to the address field (a full IPv4 address must stay readable on a
/// 360 dp wide screen).
const _fieldButton = BoxConstraints.tightFor(width: 40, height: 48);

/// Printer address, search, found devices and status with toner levels.
class PrinterCard extends StatelessWidget {
  const PrinterCard({
    super.key,
    required this.hostController,
    required this.searching,
    required this.devices,
    required this.selected,
    required this.link,
    required this.info,
    this.scanner,
    required this.onConnect,
    required this.onSearch,
    required this.onPick,
    this.onCheck,
  });

  final TextEditingController hostController;
  final bool searching;
  final List<Device>? devices; // null = not searched yet
  final Device? selected;
  final Link link;
  final PrinterInfo? info;

  /// Whether the selected device scans, from its capabilities (null: not known yet).
  final bool? scanner;
  final VoidCallback onConnect;
  final VoidCallback onSearch;
  final ValueChanged<Device> onPick;

  /// "Check device" for the entered or selected host (no menu if null).
  final VoidCallback? onCheck;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final markers = link == Link.online && info != null
        ? info!.markers.where((m) => m.level >= 0).toList()
        : const <Marker>[];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey('printer-host'),
                    controller: hostController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => onConnect(),
                    decoration: InputDecoration(
                      isDense: true,
                      labelText: tr('IP address or host name'),
                      hintText: '192.168.1.20',
                      suffixIconConstraints: _fieldButton,
                      suffixIcon: IconButton(
                        tooltip: tr('Connect'),
                        constraints: _fieldButton,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: onConnect,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                IconButton(
                  key: const ValueKey('printer-search'),
                  tooltip: tr('Search'),
                  constraints: _fieldButton,
                  padding: EdgeInsets.zero,
                  style: IconButton.styleFrom(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  onPressed: searching ? null : onSearch,
                  // the tooltip is also the label for screen readers, while searching too
                  icon: searching
                      ? const SizedBox.square(
                          dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi_find),
                ),
                if (onCheck != null)
                  PopupMenuButton<VoidCallback>(
                    key: const ValueKey('printer-menu'),
                    icon: const Icon(Icons.more_vert),
                    padding: EdgeInsets.zero,
                    style: IconButton.styleFrom(
                      fixedSize: const Size(40, 48),
                      minimumSize: const Size(40, 48),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onSelected: (action) => action(),
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: onCheck,
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.troubleshoot),
                          title: Text(tr('Check device')),
                        ),
                      ),
                    ],
                  ),
              ],
            ),
            if (searching) ...[
              const SizedBox(height: 8),
              Text(tr('Searching for devices…'), style: theme.textTheme.bodySmall),
            ] else if (devices != null) ...[
              const SizedBox(height: 8),
              Text(
                devices!.isEmpty
                    ? tr('No devices found. Enter the IP address manually.')
                    : tr('Found {n} device(s).', {'n': devices!.length}),
                style: theme.textTheme.bodySmall,
              ),
              for (final d in devices!)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  minTileHeight: 56,
                  leading: Icon(
                    d.host == selected?.host ? Icons.radio_button_checked : Icons.radio_button_off,
                    color: d.host == selected?.host ? theme.colorScheme.primary : null,
                  ),
                  title: Text(d.name),
                  subtitle: Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(d.host),
                      // the connected device: what it really can, else what it announced
                      ?_kindLabel(
                          context, d.host == selected?.host ? scanner ?? d.scanner : d.scanner),
                    ],
                  ),
                  onTap: () => onPick(d),
                ),
            ],
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _StatusLine(link: link, info: info, device: selected),
            ),
            if (link == Link.online && scanner == false)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 18, color: Palette.of(context).muted),
                    const SizedBox(width: 8),
                    Expanded(child: Text(tr(noScannerHint), style: theme.textTheme.bodyMedium)),
                  ],
                ),
              ),
            if (markers.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10, right: 4),
                child: TonerRow(markers: markers),
              ),
          ],
        ),
      ),
    );
  }
}

/// "Scanner + printer" or "Printer only" with an icon; nothing if not known.
Widget? _kindLabel(BuildContext context, bool? scanner) {
  if (scanner == null) return null;
  final muted = Palette.of(context).muted;
  return Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(scanner ? Icons.document_scanner_outlined : Icons.print_outlined, size: 14, color: muted),
      const SizedBox(width: 4),
      Flexible(
        child: Text(
          tr(scanner ? 'Scanner + printer' : 'Printer only'),
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: muted),
        ),
      ),
    ],
  );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine({required this.link, required this.info, required this.device});

  final Link link;
  final PrinterInfo? info;
  final Device? device;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (String text, Color color) = switch (link) {
      Link.none => (tr('No printer selected.'), p.muted),
      Link.connecting => (tr('Connecting…'), p.muted),
      Link.offline => (tr('Offline'), p.danger),
      Link.online => switch (info?.state) {
          'processing' => (tr('Busy'), const Color(0xFFE0A100)),
          'stopped' => (tr('Stopped'), p.danger),
          _ => (tr('Ready'), const Color(0xFF2DB56B)),
        },
    };
    // jam, open door, empty paper or toner: say so under the status
    final problem = link == Link.online && info != null ? problemFromReasons(info!.stateReasons) : null;
    final model = info?.makeAndModel ?? '';
    final name = device == null
        ? ''
        : (model.isNotEmpty && model != device!.name ? '$model · ${device!.host}' : device!.name);
    final row = Row(
      children: [
        if (link == Link.connecting)
          const SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 2))
        else
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        const SizedBox(width: 10),
        Text(text, maxLines: 1, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        if (name.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted),
            ),
          ),
        ],
      ],
    );
    if (problem == null || problem == PrintProblem.busy) return row;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        row,
        const SizedBox(height: 6),
        Text(problemText(problem), style: TextStyle(color: p.danger, fontWeight: FontWeight.w600)),
      ],
    );
  }
}

/// Toner/ink levels in one row: per marker a short bar in its colour with the percentage
/// under it. The full sentence is the tooltip and what a screen reader says.
class TonerRow extends StatelessWidget {
  const TonerRow({super.key, required this.markers});

  final List<Marker> markers;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final low = markers.any((m) => m.level < tonerLowThreshold);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (i, m) in markers.indexed) ...[
          if (i > 0) const SizedBox(width: 10),
          // narrow screens and many markers: the items shrink instead of overflowing
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 56),
              child: _TonerItem(marker: m),
            ),
          ),
        ],
        if (low) ...[
          const SizedBox(width: 12),
          Flexible(
            flex: 2,
            child: Text(
              tr('Toner low'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.danger, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ],
    );
  }
}

/// "60 %" (Turkish: "%60", like the full sentence).
String _percent(int level) => currentLanguage == 'tr' ? '%$level' : '$level %';

class _TonerItem extends StatelessWidget {
  const _TonerItem({required this.marker});

  final Marker marker;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final low = marker.level < tonerLowThreshold;
    final level = marker.level.clamp(0, 100);
    final color = _markerColor(marker.color, p.accent);
    final outline = tonerOutline(color, Theme.of(context).brightness, p.muted);
    var label = tr('{name}: {level} % left', {'name': marker.name, 'level': level});
    if (low) label = '$label – ${tr('Toner low')}';
    return Tooltip(
      message: label,
      excludeFromSemantics: true,
      child: Semantics(
        container: true,
        label: label,
        excludeSemantics: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 6,
              // a dark toner (black) on the dark theme gets a light outline so the bar stays visible
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                border: outline == null ? null : Border.all(color: outline, width: 1),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: level / 100,
                  minHeight: 6,
                  color: color,
                  backgroundColor: p.line,
                ),
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                _percent(level),
                maxLines: 1,
                style: TextStyle(
                  fontSize: 11,
                  color: low ? p.danger : p.muted,
                  fontWeight: low ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Outline for a toner bar: only when the toner colour is too dark for the dark theme.
Color? tonerOutline(Color toner, Brightness brightness, Color light) =>
    brightness == Brightness.dark && toner.computeLuminance() < 0.1 ? light : null;

/// IPP marker colours look like "#00FFFF" (several joined for mixed markers: take the first).
Color _markerColor(String value, Color fallback) {
  final m = RegExp(r'#([0-9a-fA-F]{6})').firstMatch(value);
  if (m == null) return fallback;
  return Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}
