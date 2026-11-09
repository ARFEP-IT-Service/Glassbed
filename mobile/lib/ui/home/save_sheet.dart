import 'package:flutter/material.dart';

import '../../core/export.dart';
import '../../i18n.dart';

/// What the user chose in the save/share sheet.
typedef SaveOptions = ({ExportFormat format, bool splitPdf, String baseName});

/// Default file name "Scan_YYYY-MM-DD_HH-mm".
String defaultBaseName([DateTime? now]) {
  final t = now ?? DateTime.now();
  String two(int v) => v.toString().padLeft(2, '0');
  return 'Scan_${t.year}-${two(t.month)}-${two(t.day)}_${two(t.hour)}-${two(t.minute)}';
}

/// Characters that are not allowed in file names on common file systems.
String _cleanName(String name) {
  final cleaned = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_');
  return cleaned.isEmpty ? defaultBaseName() : cleaned;
}

/// Bottom sheet with format, PDF splitting and file name. [actionLabel] is "Save" or "Share".
Future<SaveOptions?> showSaveSheet(
  BuildContext context, {
  required String actionLabel,
  required IconData actionIcon,
  required int pageCount,
  ExportFormat initialFormat = ExportFormat.pdf,
}) {
  return showModalBottomSheet<SaveOptions>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) => _SaveSheet(
      actionLabel: actionLabel,
      actionIcon: actionIcon,
      pageCount: pageCount,
      initialFormat: initialFormat,
    ),
  );
}

class _SaveSheet extends StatefulWidget {
  const _SaveSheet({
    required this.actionLabel,
    required this.actionIcon,
    required this.pageCount,
    required this.initialFormat,
  });

  final String actionLabel;
  final IconData actionIcon;
  final int pageCount;
  final ExportFormat initialFormat;

  @override
  State<_SaveSheet> createState() => _SaveSheetState();
}

class _SaveSheetState extends State<_SaveSheet> {
  late ExportFormat _format = widget.initialFormat;
  bool _split = false;
  late final _name = TextEditingController(text: defaultBaseName());

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.pop<SaveOptions>(context, (
      format: _format,
      splitPdf: _format == ExportFormat.pdf && _split,
      baseName: _cleanName(_name.text),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final perPage = _format != ExportFormat.pdf || _split;
    return Padding(
      // keyboard and the system navigation bar must not cover the button
      padding: EdgeInsets.fromLTRB(20, 0, 20,
          20 + MediaQuery.viewInsetsOf(context).bottom + MediaQuery.viewPaddingOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(tr('Format'), style: theme.textTheme.labelLarge),
          const SizedBox(height: 6),
          SegmentedButton<ExportFormat>(
            segments: const [
              ButtonSegment(value: ExportFormat.pdf, label: Text('PDF')),
              ButtonSegment(value: ExportFormat.jpg, label: Text('JPG')),
              ButtonSegment(value: ExportFormat.png, label: Text('PNG')),
            ],
            selected: {_format},
            showSelectedIcon: false,
            onSelectionChanged: (v) => setState(() => _format = v.first),
          ),
          if (_format == ExportFormat.pdf && widget.pageCount > 1) ...[
            const SizedBox(height: 14),
            Text(tr('Files'), style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: false, label: Text(tr('One file'))),
                ButtonSegment(value: true, label: Text(tr('Per page'))),
              ],
              selected: {_split},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => _split = v.first),
            ),
          ],
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            autocorrect: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              labelText: tr('File name'),
              helperText: perPage && widget.pageCount > 1
                  ? tr('One file per page: name_001, name_002, …')
                  : null,
            ),
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 56,
            child: FilledButton.icon(
              onPressed: _submit,
              icon: Icon(widget.actionIcon),
              label: Text(widget.actionLabel),
            ),
          ),
        ],
      ),
    );
  }
}
