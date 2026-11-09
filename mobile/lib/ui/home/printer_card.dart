import 'package:flutter/material.dart';

import '../../core/device.dart';
import '../../core/ipp.dart';
import '../../i18n.dart';
import '../theme.dart';

/// Connection state of the selected printer.
enum Link { none, connecting, online, offline }

/// Below this level (percent) a toner is shown as low, like in the Windows app.
const tonerLowThreshold = 15;

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
    required this.onConnect,
    required this.onSearch,
    required this.onPick,
  });

  final TextEditingController hostController;
  final bool searching;
  final List<Device>? devices; // null = not searched yet
  final Device? selected;
  final Link link;
  final PrinterInfo? info;
  final VoidCallback onConnect;
  final VoidCallback onSearch;
  final ValueChanged<Device> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: hostController,
                    keyboardType: TextInputType.url,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.go,
                    onSubmitted: (_) => onConnect(),
                    decoration: InputDecoration(
                      labelText: tr('IP address or host name'),
                      hintText: '192.168.1.20',
                      prefixIcon: const Icon(Icons.print_outlined),
                      suffixIcon: IconButton(
                        tooltip: tr('Connect'),
                        icon: const Icon(Icons.arrow_forward),
                        onPressed: onConnect,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: FilledButton.tonalIcon(
                    onPressed: searching ? null : onSearch,
                    icon: searching
                        ? const SizedBox.square(
                            dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.wifi_find),
                    label: Text(tr('Search')),
                  ),
                ),
              ],
            ),
            if (searching) ...[
              const SizedBox(height: 12),
              Text(tr('Searching for devices…'), style: theme.textTheme.bodySmall),
            ] else if (devices != null) ...[
              const SizedBox(height: 12),
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
                  subtitle: Text(d.host),
                  onTap: () => onPick(d),
                ),
            ],
            const SizedBox(height: 12),
            _StatusLine(link: link, info: info, device: selected),
            if (link == Link.online && info != null)
              for (final m in info!.markers.where((m) => m.level >= 0)) _TonerBar(marker: m),
          ],
        ),
      ),
    );
  }
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
    final model = info?.makeAndModel ?? '';
    final name = device == null
        ? ''
        : (model.isNotEmpty && model != device!.name ? '$model · ${device!.host}' : device!.name);
    return Row(
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
        Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
        if (name.isNotEmpty) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              name,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: p.muted),
            ),
          ),
        ],
      ],
    );
  }
}

class _TonerBar extends StatelessWidget {
  const _TonerBar({required this.marker});

  final Marker marker;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final low = marker.level < tonerLowThreshold;
    final level = marker.level.clamp(0, 100);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  tr('{name}: {level} % left', {'name': marker.name, 'level': level}),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              if (low)
                Text(
                  tr('Toner low'),
                  style: TextStyle(color: p.danger, fontSize: 12, fontWeight: FontWeight.w600),
                ),
            ],
          ),
          const SizedBox(height: 4),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: level / 100,
              minHeight: 8,
              color: _markerColor(marker.color, p.accent),
              backgroundColor: p.line,
            ),
          ),
        ],
      ),
    );
  }
}

/// IPP marker colours look like "#00FFFF" (several joined for mixed markers: take the first).
Color _markerColor(String value, Color fallback) {
  final m = RegExp(r'#([0-9a-fA-F]{6})').firstMatch(value);
  if (m == null) return fallback;
  return Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}
