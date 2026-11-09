import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/edit.dart' as ed;
import 'preview_view.dart';

/// A redaction box in output pixels of the edited page (full resolution).
typedef RedactBox = ({Rect rect, ed.RedactStyle style});

/// Zoom state of [RedactView], so buttons outside can zoom and fit.
class ZoomController extends ChangeNotifier {
  double scale = 1;
  Offset offset = Offset.zero;
  Size _view = Size.zero;

  static const maxScale = 8.0;

  void fit() {
    scale = 1;
    offset = Offset.zero;
    notifyListeners();
  }

  void zoomBy(double factor) {
    final center = _view.center(Offset.zero);
    _zoomAround(center, (scale * factor).clamp(1.0, maxScale), scale, offset);
    notifyListeners();
  }

  void _zoomAround(Offset focal, double newScale, double fromScale, Offset fromOffset) {
    final content = (focal - fromOffset) / fromScale;
    scale = newScale;
    offset = _clamp(focal - content * newScale);
  }

  /// Keeps the zoomed content covering the view (no empty space when zoomed in).
  Offset _clamp(Offset o) {
    final minX = _view.width - _view.width * scale, minY = _view.height - _view.height * scale;
    return Offset(o.dx.clamp(math.min(minX, 0), 0), o.dy.clamp(math.min(minY, 0), 0));
  }
}

enum _Mode { idle, draw, move, resize, zoom }

/// The edited page with redaction boxes. One finger draws a new box, or moves/resizes the
/// selected one; two fingers zoom and pan without drawing.
class RedactView extends StatefulWidget {
  const RedactView({
    super.key,
    required this.image,
    required this.outputSize,
    required this.boxes,
    required this.selected,
    required this.newStyle,
    required this.zoom,
    required this.onAdd,
    required this.onChange,
    required this.onSelect,
  });

  final ui.Image? image;

  /// Size of the edited page at full resolution (the box coordinate space).
  final Size outputSize;
  final List<RedactBox> boxes;
  final int? selected;
  final ed.RedactStyle newStyle;
  final ZoomController zoom;
  final ValueChanged<Rect> onAdd;
  final void Function(int index, Rect rect) onChange;
  final ValueChanged<int?> onSelect;

  @override
  State<RedactView> createState() => _RedactViewState();
}

class _RedactViewState extends State<RedactView> {
  _Mode _mode = _Mode.idle;
  bool _zoomedInGesture = false; // ignore the last finger after a pinch until all are up
  Offset _startOut = Offset.zero; // gesture start in output pixels
  Rect? _draft; // box being drawn
  Rect? _editing; // selected box while being moved/resized
  Rect _editStart = Rect.zero;
  int _corner = 0; // 0 tl, 1 tr, 2 br, 3 bl
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;
  Rect _base = Rect.zero; // fitted page in unzoomed view coordinates

  ZoomController get _z => widget.zoom;

  @override
  void initState() {
    super.initState();
    _z.addListener(_onZoom);
  }

  @override
  void didUpdateWidget(RedactView old) {
    super.didUpdateWidget(old);
    if (old.zoom != widget.zoom) {
      old.zoom.removeListener(_onZoom);
      widget.zoom.addListener(_onZoom);
    }
  }

  @override
  void dispose() {
    _z.removeListener(_onZoom);
    super.dispose();
  }

  void _onZoom() => setState(() {});

  /// The page on screen (zoom applied).
  Rect get _pageRect => Rect.fromLTWH(
        _z.offset.dx + _base.left * _z.scale,
        _z.offset.dy + _base.top * _z.scale,
        _base.width * _z.scale,
        _base.height * _z.scale,
      );

  double get _outToScreen => _pageRect.width / widget.outputSize.width;

  Offset _toOut(Offset screen) => (screen - _pageRect.topLeft) / _outToScreen;

  Rect _rectToScreen(Rect r) => Rect.fromLTRB(
        _pageRect.left + r.left * _outToScreen,
        _pageRect.top + r.top * _outToScreen,
        _pageRect.left + r.right * _outToScreen,
        _pageRect.top + r.bottom * _outToScreen,
      );

  Offset _clampOut(Offset p) => Offset(
        p.dx.clamp(0, widget.outputSize.width),
        p.dy.clamp(0, widget.outputSize.height),
      );

  int? _boxAt(Offset out) {
    for (var i = widget.boxes.length - 1; i >= 0; i--) {
      if (widget.boxes[i].rect.contains(out)) return i;
    }
    return null;
  }

  /// Corner of the selected box under [screen], or null.
  int? _cornerAt(Offset screen) {
    final sel = widget.selected;
    if (sel == null || sel >= widget.boxes.length) return null;
    final r = _rectToScreen(widget.boxes[sel].rect);
    final corners = [r.topLeft, r.topRight, r.bottomRight, r.bottomLeft];
    for (var i = 0; i < 4; i++) {
      if ((corners[i] - screen).distance <= 28) return i;
    }
    return null;
  }

  void _onStart(ScaleStartDetails d) {
    if (d.pointerCount >= 2) {
      _cancelEdit();
      _mode = _Mode.zoom;
      _zoomedInGesture = true;
      _startScale = _z.scale;
      _startOffset = _z.offset;
      _startFocal = d.localFocalPoint;
      return;
    }
    if (_zoomedInGesture) {
      _mode = _Mode.idle;
      return;
    }
    final out = _toOut(d.localFocalPoint);
    _startOut = out;
    final corner = _cornerAt(d.localFocalPoint);
    if (corner != null) {
      _mode = _Mode.resize;
      _corner = corner;
      _editStart = widget.boxes[widget.selected!].rect;
      return;
    }
    final hit = _boxAt(out);
    if (hit != null) {
      if (hit != widget.selected) widget.onSelect(hit);
      _mode = _Mode.move;
      _editStart = widget.boxes[hit].rect;
      return;
    }
    _mode = _Mode.draw;
    _draft = Rect.fromPoints(_clampOut(out), _clampOut(out));
  }

  void _onUpdate(ScaleUpdateDetails d) {
    switch (_mode) {
      case _Mode.zoom:
        final newScale = (_startScale * d.scale).clamp(1.0, ZoomController.maxScale);
        final content = (_startFocal - _startOffset) / _startScale;
        _z.scale = newScale;
        _z.offset = _z._clamp(d.localFocalPoint - content * newScale);
        setState(() {});
      case _Mode.draw:
        setState(() => _draft = Rect.fromPoints(_clampOut(_startOut), _clampOut(_toOut(d.localFocalPoint))));
      case _Mode.move:
        final delta = _toOut(d.localFocalPoint) - _startOut;
        final s = _editStart;
        final dx = delta.dx.clamp(-s.left, widget.outputSize.width - s.right);
        final dy = delta.dy.clamp(-s.top, widget.outputSize.height - s.bottom);
        setState(() => _editing = s.shift(Offset(dx, dy)));
      case _Mode.resize:
        final p = _clampOut(_toOut(d.localFocalPoint));
        final s = _editStart;
        final opposite = [s.bottomRight, s.bottomLeft, s.topLeft, s.topRight][_corner];
        setState(() => _editing = Rect.fromPoints(opposite, p));
      case _Mode.idle:
        break;
    }
  }

  void _onEnd(ScaleEndDetails d) {
    // The recognizer restarts when a finger is added: that is not the end of a drawing.
    if (d.pointerCount > 0 && _mode != _Mode.zoom) {
      _cancelEdit();
      return;
    }
    if (d.pointerCount == 0) _zoomedInGesture = false;
    final minSize = 12 / _outToScreen; // at least 12 logical pixels on screen
    switch (_mode) {
      case _Mode.draw:
        final r = _draft;
        if (r != null && r.width >= minSize && r.height >= minSize) widget.onAdd(r);
      case _Mode.move:
      case _Mode.resize:
        final r = _editing;
        final sel = widget.selected;
        if (r != null && sel != null && r.width >= minSize && r.height >= minSize) {
          widget.onChange(sel, r);
        }
      case _Mode.zoom:
      case _Mode.idle:
        break;
    }
    _mode = _Mode.idle;
    setState(() {
      _draft = null;
      _editing = null;
    });
  }

  void _cancelEdit() {
    _mode = _Mode.idle;
    setState(() {
      _draft = null;
      _editing = null;
    });
  }

  void _onTap(TapUpDetails d) {
    widget.onSelect(_boxAt(_toOut(d.localPosition)));
  }

  @override
  Widget build(BuildContext context) {
    final image = widget.image;
    if (image == null || widget.outputSize.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(builder: (context, box) {
      final view = Size(box.maxWidth, box.maxHeight);
      _z._view = view;
      _base = fitContain(view, widget.outputSize);
      final boxes = <(Rect, ed.RedactStyle, bool)>[
        for (var i = 0; i < widget.boxes.length; i++)
          (
            _rectToScreen(i == widget.selected && _editing != null ? _editing! : widget.boxes[i].rect),
            widget.boxes[i].style,
            i == widget.selected,
          ),
      ];
      return ClipRect(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: _onTap,
          onScaleStart: _onStart,
          onScaleUpdate: _onUpdate,
          onScaleEnd: _onEnd,
          child: CustomPaint(
            size: view,
            painter: _RedactPainter(
              image: image,
              page: _pageRect,
              boxes: boxes,
              draft: _draft == null ? null : (_rectToScreen(_draft!), widget.newStyle),
              moving: _editing != null,
              accent: accent,
            ),
          ),
        ),
      );
    });
  }
}

Color _styleColor(ed.RedactStyle s) => switch (s) {
      ed.RedactStyle.black => Colors.black,
      ed.RedactStyle.white => Colors.white,
      ed.RedactStyle.blur => const Color(0xFF7F8A96),
    };

class _RedactPainter extends CustomPainter {
  _RedactPainter({
    required this.image,
    required this.page,
    required this.boxes,
    required this.draft,
    required this.moving,
    required this.accent,
  });

  final ui.Image image;
  final Rect page;
  final List<(Rect, ed.RedactStyle, bool)> boxes;
  final (Rect, ed.RedactStyle)? draft;
  final bool moving;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    drawPreview(canvas, image, page);
    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = accent.withValues(alpha: 0.8);
    for (final (rect, style, selected) in boxes) {
      // The preview already shows committed redactions burned in; a box being moved
      // is drawn as a translucent stand-in until the preview is rendered again.
      if (selected && moving) {
        canvas.drawRect(rect, Paint()..color = _styleColor(style).withValues(alpha: 0.6));
      }
      canvas.drawRect(rect, selected ? (Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = accent) : outline);
      if (selected) {
        final fill = Paint()..color = accent;
        final ring = Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2;
        for (final c in [rect.topLeft, rect.topRight, rect.bottomRight, rect.bottomLeft]) {
          canvas.drawCircle(c, 10, fill);
          canvas.drawCircle(c, 10, ring);
        }
      }
    }
    final d = draft;
    if (d != null) {
      canvas.drawRect(d.$1, Paint()..color = _styleColor(d.$2).withValues(alpha: 0.6));
      canvas.drawRect(
        d.$1,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = accent,
      );
    }
  }

  @override
  bool shouldRepaint(_RedactPainter old) => true;
}
