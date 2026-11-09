import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../image_work.dart';
import '../theme.dart';
import 'copies_stepper.dart';
import 'print_model.dart';

/// The Print section below the printer card: files with page thumbnails and the options.
class PrintSection extends StatelessWidget {
  const PrintSection({super.key, required this.model, required this.onAddFiles});

  final PrintModel model;
  final VoidCallback onAddFiles;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _FilesCard(model: model, onAddFiles: onAddFiles),
          const SizedBox(height: 12),
          _OptionsCard(model: model),
        ],
      ),
    );
  }
}

class _FilesCard extends StatelessWidget {
  const _FilesCard({required this.model, required this.onAddFiles});

  final PrintModel model;
  final VoidCallback onAddFiles;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final busy = model.busy;
    final selected = model.selectedPages;
    // Page numbers continue across files, like the page range counts them.
    final firstPages = <int>[];
    var offset = 0;
    for (final d in model.docs) {
      firstPages.add(offset);
      offset += d.pageCount;
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 52,
                    child: FilledButton.tonalIcon(
                      onPressed: busy || model.opening ? null : onAddFiles,
                      icon: model.opening
                          ? const SizedBox.square(
                              dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.note_add_outlined),
                      label: Text(tr('Add files…')),
                    ),
                  ),
                ),
                if (model.docs.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: busy ? null : model.clear,
                    icon: const Icon(Icons.delete_sweep_outlined),
                    label: Text(tr('Clear all')),
                  ),
                ],
              ],
            ),
            if (model.docs.isEmpty && !model.opening) ...[
              const SizedBox(height: 12),
              Text(
                tr('Add PDFs or images to print. You can also share them to Glassbed from another app.'),
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (model.opening && model.docs.isEmpty) ...[
              const SizedBox(height: 12),
              Text(tr('Loading pages…'), style: theme.textTheme.bodySmall),
            ],
            for (final (i, doc) in model.docs.indexed) ...[
              const SizedBox(height: 14),
              _DocTile(
                model: model,
                doc: doc,
                firstPage: firstPages[i],
                selected: selected,
                enabled: !busy,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DocTile extends StatelessWidget {
  const _DocTile({
    required this.model,
    required this.doc,
    required this.firstPage,
    required this.selected,
    required this.enabled,
  });

  final PrintModel model;
  final PrintDoc doc;

  /// Index of this file's first page in the whole print list (page numbers continue).
  final int firstPage;
  final Set<int>? selected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(doc.kind == DocKind.pdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
                color: p.muted),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(doc.name, maxLines: 1, overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall),
                  Text(tr('{n} page(s)', {'n': doc.pageCount}), style: theme.textTheme.bodySmall),
                ],
              ),
            ),
            IconButton(
              tooltip: tr('Remove'),
              onPressed: enabled ? () => model.remove(doc) : null,
              icon: const Icon(Icons.close),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 150,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: doc.pageCount,
            separatorBuilder: (_, _) => const SizedBox(width: 10),
            itemBuilder: (context, i) {
              final number = firstPage + i;
              return _PageThumb(
                image: doc.thumbs[i],
                number: number + 1,
                dimmed: selected != null && !selected!.contains(number),
                onTap: () => showDialog<void>(
                  context: context,
                  builder: (_) => _PreviewDialog(model: model, ref: (doc: doc, index: i)),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _PageThumb extends StatelessWidget {
  const _PageThumb({
    required this.image,
    required this.number,
    required this.dimmed,
    required this.onTap,
  });

  final ui.Image? image;
  final int number;
  final bool dimmed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    return Opacity(
      opacity: dimmed ? 0.35 : 1,
      child: Material(
        color: p.raised,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            width: 100,
            child: Column(
              children: [
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(6, 6, 6, 0),
                    child: image == null
                        ? const Center(
                            child: SizedBox.square(
                                dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)))
                        : RawImage(image: image, fit: BoxFit.contain),
                  ),
                ),
                SizedBox(
                  height: 26,
                  child: Center(child: Text('$number', style: theme.textTheme.labelMedium)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The page as it will land on the paper (current paper size and colour mode).
class _PreviewDialog extends StatefulWidget {
  const _PreviewDialog({required this.model, required this.ref});

  final PrintModel model;
  final PrintPageRef ref;

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  ui.Image? _image;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final image = await toUiImage(await widget.model.preview(widget.ref));
      if (!mounted) {
        image.dispose();
        return;
      }
      setState(() => _image = image);
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: _failed
                  ? Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(tr('Could not open file'), textAlign: TextAlign.center),
                    )
                  : image == null
                      ? const SizedBox(
                          height: 240, child: Center(child: CircularProgressIndicator()))
                      : InteractiveViewer(
                          maxScale: 5,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border.all(color: Palette.of(context).line),
                            ),
                            child: AspectRatio(
                              aspectRatio: image.width / image.height,
                              child: RawImage(image: image, fit: BoxFit.contain),
                            ),
                          ),
                        ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(tr('Done')),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _OptionsCard extends StatelessWidget {
  const _OptionsCard({required this.model});

  final PrintModel model;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = !model.busy;
    final rangeValid = model.selectedPages != null || model.pageRange.text.trim().isEmpty;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(tr('Copies'), style: theme.textTheme.labelLarge)),
                CopiesStepper(value: model.copies, onChanged: enabled ? model.setCopies : null),
              ],
            ),
            const SizedBox(height: 14),
            OptionLabel(tr('Color mode')),
            SegmentedButton<bool>(
              segments: [
                ButtonSegment(value: true, label: Text(tr('Color'))),
                ButtonSegment(value: false, label: Text(tr('B/W'))),
              ],
              selected: {model.color},
              showSelectedIcon: false,
              onSelectionChanged: enabled ? (v) => model.setColor(v.first) : null,
            ),
            const SizedBox(height: 14),
            OptionLabel(tr('Paper')),
            SegmentedButton<String>(
              segments: [
                for (final m in model.mediaChoices)
                  ButtonSegment(value: m, label: Text(mediaLabels[m] ?? m)),
              ],
              selected: {model.media},
              showSelectedIcon: false,
              onSelectionChanged: enabled ? (v) => model.setMedia(v.first) : null,
            ),
            const SizedBox(height: 14),
            OptionLabel(tr('Pages')),
            TextField(
              controller: model.pageRange,
              enabled: enabled,
              keyboardType: TextInputType.visiblePassword, // digits, "-" and "," without autocorrect
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                hintText: '${tr('All')} – ${tr('e.g. 1-3, 5')}',
                errorText: rangeValid ? null : tr('Invalid page range.'),
                suffixIcon: model.pageRange.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: tr('All'),
                        icon: const Icon(Icons.clear),
                        onPressed: enabled ? model.pageRange.clear : null,
                      ),
              ),
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(tr('Manual duplex')),
              subtitle: Text(tr('Print both sides by reinserting the stack')),
              value: model.manualDuplex,
              onChanged: enabled ? model.setManualDuplex : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// Small heading above an option, like in the scan card.
class OptionLabel extends StatelessWidget {
  const OptionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(text, style: Theme.of(context).textTheme.labelLarge),
      );
}
