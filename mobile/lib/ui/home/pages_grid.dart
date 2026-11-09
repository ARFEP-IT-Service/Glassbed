import 'package:flutter/material.dart';

import '../../i18n.dart';
import '../page_item.dart';
import '../theme.dart';

enum PageAction { edit, rotateLeft, rotateRight, delete }

/// Thumbnails of all pages. Tap opens the editor, long-press and drag reorders.
class PagesGrid extends StatelessWidget {
  const PagesGrid({
    super.key,
    required this.pages,
    required this.onAction,
    required this.onMove,
  });

  final List<PageItem> pages;
  final void Function(PageItem page, PageAction action) onAction;

  /// Move the page at [from] to position [to].
  final void Function(int from, int to) onMove;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 200,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.66,
      ),
      itemCount: pages.length,
      itemBuilder: (context, i) => _DraggableTile(
        key: ValueKey(pages[i].id),
        index: i,
        page: pages[i],
        onAction: onAction,
        onMove: onMove,
      ),
    );
  }
}

class _DraggableTile extends StatelessWidget {
  const _DraggableTile({
    super.key,
    required this.index,
    required this.page,
    required this.onAction,
    required this.onMove,
  });

  final int index;
  final PageItem page;
  final void Function(PageItem page, PageAction action) onAction;
  final void Function(int from, int to) onMove;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final tile = _PageTile(index: index, page: page, onAction: onAction);
      return DragTarget<int>(
        onWillAcceptWithDetails: (d) => d.data != index,
        onAcceptWithDetails: (d) => onMove(d.data, index),
        builder: (context, candidates, _) {
          final hovering = candidates.isNotEmpty;
          return LongPressDraggable<int>(
            data: index,
            hapticFeedbackOnStart: true,
            feedback: Material(
              color: Colors.transparent,
              elevation: 8,
              borderRadius: BorderRadius.circular(12),
              child: SizedBox(
                width: box.maxWidth,
                height: box.maxHeight,
                child: Opacity(opacity: 0.9, child: tile),
              ),
            ),
            childWhenDragging: Opacity(opacity: 0.3, child: tile),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: hovering ? Theme.of(context).colorScheme.primary : Colors.transparent,
                  width: 3,
                ),
              ),
              child: tile,
            ),
          );
        },
      );
    });
  }
}

class _PageTile extends StatelessWidget {
  const _PageTile({required this.index, required this.page, required this.onAction});

  final int index;
  final PageItem page;
  final void Function(PageItem page, PageAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final theme = Theme.of(context);
    final thumb = page.thumbnail;
    return Material(
      color: p.surface,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onAction(page, PageAction.edit),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: thumb == null
                    ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                    : RawImage(image: thumb, fit: BoxFit.contain),
              ),
            ),
            SizedBox(
              height: 48,
              child: Row(
                children: [
                  const SizedBox(width: 10),
                  Text('${index + 1}', style: theme.textTheme.titleSmall),
                  if (!page.edits.isIdentity) ...[
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        tr('Edited'),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: p.accent, fontSize: 12),
                      ),
                    ),
                  ],
                  const Spacer(),
                  PopupMenuButton<PageAction>(
                    tooltip: tr('Page options'),
                    icon: const Icon(Icons.more_vert),
                    onSelected: (a) => onAction(page, a),
                    itemBuilder: (context) => [
                      _item(PageAction.edit, Icons.tune, tr('Edit page')),
                      _item(PageAction.rotateLeft, Icons.rotate_left, tr('Rotate left')),
                      _item(PageAction.rotateRight, Icons.rotate_right, tr('Rotate right')),
                      _item(PageAction.delete, Icons.delete_outline, tr('Delete')),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  PopupMenuItem<PageAction> _item(PageAction value, IconData icon, String text) =>
      PopupMenuItem(
        value: value,
        height: 52,
        child: Row(children: [Icon(icon), const SizedBox(width: 14), Text(text)]),
      );
}
