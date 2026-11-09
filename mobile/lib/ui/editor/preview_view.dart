import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// [image] size fitted into [box] (contain), centred.
Rect fitContain(Size box, Size image) {
  if (image.isEmpty || box.isEmpty) return Offset.zero & box;
  final s = (box.width / image.width) < (box.height / image.height)
      ? box.width / image.width
      : box.height / image.height;
  final w = image.width * s, h = image.height * s;
  return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
}

Size imageSize(ui.Image image) => Size(image.width.toDouble(), image.height.toDouble());

/// The preview image fitted into the available space, optionally with a straightening grid.
class PreviewView extends StatelessWidget {
  const PreviewView({super.key, required this.image, this.grid = false});

  final ui.Image? image;
  final bool grid;

  @override
  Widget build(BuildContext context) {
    final img = image;
    if (img == null) return const Center(child: CircularProgressIndicator());
    return CustomPaint(
      size: Size.infinite,
      painter: _PreviewPainter(img, grid, Theme.of(context).colorScheme.primary),
    );
  }
}

class _PreviewPainter extends CustomPainter {
  _PreviewPainter(this.image, this.grid, this.gridColor);

  final ui.Image image;
  final bool grid;
  final Color gridColor;

  @override
  void paint(Canvas canvas, Size size) {
    final dst = fitContain(size, imageSize(image));
    drawPreview(canvas, image, dst);
    if (!grid) return;
    final paint = Paint()
      ..color = gridColor.withValues(alpha: 0.55)
      ..strokeWidth = 1;
    const lines = 8;
    for (var i = 1; i < lines; i++) {
      final x = dst.left + dst.width * i / lines;
      final y = dst.top + dst.height * i / lines;
      canvas.drawLine(Offset(x, dst.top), Offset(x, dst.bottom), paint);
      canvas.drawLine(Offset(dst.left, y), Offset(dst.right, y), paint);
    }
  }

  @override
  bool shouldRepaint(_PreviewPainter old) =>
      old.image != image || old.grid != grid || old.gridColor != gridColor;
}

/// Draws [image] into [dst] with smooth scaling.
void drawPreview(Canvas canvas, ui.Image image, Rect dst) {
  canvas.drawImageRect(
    image,
    Offset.zero & imageSize(image),
    dst,
    Paint()..filterQuality = FilterQuality.medium,
  );
}
