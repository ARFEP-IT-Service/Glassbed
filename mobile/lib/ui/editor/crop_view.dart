import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'preview_view.dart';

/// Smallest crop, as a fraction of the page.
const _minSize = 0.05;

/// Touch radius of the handles in logical pixels (large for fingers).
const _grab = 28.0;

enum _Hit { none, move, l, t, r, b, tl, tr, bl, br }

/// The uncropped page with a crop rectangle (normalised 0..1) that can be dragged at its
/// corners and edges or moved as a whole.
class CropView extends StatefulWidget {
  const CropView({
    super.key,
    required this.image,
    required this.crop,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final ui.Image? image;

  /// Current crop, normalised; [Rect.fromLTRB(0, 0, 1, 1)] for the whole page.
  final Rect crop;
  final ValueChanged<Rect> onChanged;
  final VoidCallback onChangeEnd;

  @override
  State<CropView> createState() => _CropViewState();
}

class _CropViewState extends State<CropView> {
  _Hit _hit = _Hit.none;
  Rect _start = Rect.zero;
  Offset _startPoint = Offset.zero;

  _Hit _hitTest(Rect c, Offset p) {
    bool near(double a, double b) => (a - b).abs() <= _grab;
    final inY = p.dy >= c.top - _grab && p.dy <= c.bottom + _grab;
    final inX = p.dx >= c.left - _grab && p.dx <= c.right + _grab;
    final l = near(p.dx, c.left) && inY, r = near(p.dx, c.right) && inY;
    final t = near(p.dy, c.top) && inX, b = near(p.dy, c.bottom) && inX;
    if (t && l) return _Hit.tl;
    if (t && r) return _Hit.tr;
    if (b && l) return _Hit.bl;
    if (b && r) return _Hit.br;
    if (l) return _Hit.l;
    if (r) return _Hit.r;
    if (t) return _Hit.t;
    if (b) return _Hit.b;
    if (c.contains(p)) return _Hit.move;
    return _Hit.none;
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    if (image == null) return const Center(child: CircularProgressIndicator());
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(builder: (context, box) {
      // Leave room so the handles at the page border stay reachable.
      final area = Size(box.maxWidth, box.maxHeight);
      final dst = fitContain(area.shrink(32), imageSize(image)).shift(const Offset(16, 16));
      Rect toScreen(Rect n) => Rect.fromLTRB(
            dst.left + n.left * dst.width,
            dst.top + n.top * dst.height,
            dst.left + n.right * dst.width,
            dst.top + n.bottom * dst.height,
          );
      return GestureDetector(
        onPanStart: (d) {
          _hit = _hitTest(toScreen(widget.crop), d.localPosition);
          _start = widget.crop;
          _startPoint = d.localPosition;
        },
        onPanUpdate: (d) {
          if (_hit == _Hit.none) return;
          final dx = (d.localPosition.dx - _startPoint.dx) / dst.width;
          final dy = (d.localPosition.dy - _startPoint.dy) / dst.height;
          widget.onChanged(_apply(_start, _hit, dx, dy));
        },
        onPanEnd: (_) {
          if (_hit != _Hit.none) widget.onChangeEnd();
          _hit = _Hit.none;
        },
        child: CustomPaint(
          size: area,
          painter: _CropPainter(image, dst, toScreen(widget.crop), accent),
        ),
      );
    });
  }

  static Rect _apply(Rect s, _Hit hit, double dx, double dy) {
    if (hit == _Hit.move) {
      final x = (s.left + dx).clamp(0.0, 1.0 - s.width);
      final y = (s.top + dy).clamp(0.0, 1.0 - s.height);
      return Rect.fromLTWH(x, y, s.width, s.height);
    }
    var l = s.left, t = s.top, r = s.right, b = s.bottom;
    if (hit == _Hit.l || hit == _Hit.tl || hit == _Hit.bl) {
      l = (l + dx).clamp(0.0, r - _minSize);
    }
    if (hit == _Hit.r || hit == _Hit.tr || hit == _Hit.br) {
      r = (r + dx).clamp(l + _minSize, 1.0);
    }
    if (hit == _Hit.t || hit == _Hit.tl || hit == _Hit.tr) {
      t = (t + dy).clamp(0.0, b - _minSize);
    }
    if (hit == _Hit.b || hit == _Hit.bl || hit == _Hit.br) {
      b = (b + dy).clamp(t + _minSize, 1.0);
    }
    return Rect.fromLTRB(l, t, r, b);
  }
}

extension on Size {
  Size shrink(double by) => Size((width - by).clamp(1, double.infinity), (height - by).clamp(1, double.infinity));
}

class _CropPainter extends CustomPainter {
  _CropPainter(this.image, this.dst, this.crop, this.accent);

  final ui.Image image;
  final Rect dst;
  final Rect crop;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    drawPreview(canvas, image, dst);
    // Dim everything outside the crop.
    final outside = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(dst)
      ..addRect(crop);
    canvas.drawPath(outside, Paint()..color = Colors.black.withValues(alpha: 0.55));
    canvas.drawRect(
      crop,
      Paint()
        ..color = accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
    // Thirds as orientation.
    final thin = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    for (var i = 1; i < 3; i++) {
      final x = crop.left + crop.width * i / 3, y = crop.top + crop.height * i / 3;
      canvas.drawLine(Offset(x, crop.top), Offset(x, crop.bottom), thin);
      canvas.drawLine(Offset(crop.left, y), Offset(crop.right, y), thin);
    }
    final handle = Paint()..color = accent;
    final ring = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    for (final p in [
      crop.topLeft, crop.topRight, crop.bottomLeft, crop.bottomRight,
      crop.centerLeft, crop.centerRight, crop.topCenter, crop.bottomCenter,
    ]) {
      canvas.drawCircle(p, 9, handle);
      canvas.drawCircle(p, 9, ring);
    }
  }

  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image || old.dst != dst || old.crop != crop || old.accent != accent;
}
