import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../core/edit.dart' as ed;
import '../../i18n.dart';
import '../dialogs.dart';
import '../image_work.dart';
import '../page_item.dart';
import 'crop_view.dart';
import 'preview_view.dart';
import 'redact_view.dart';

enum _Tab { crop, rotate, tone, redact }

/// Edits one page non-destructively. Returns the new [ed.Edits] on "Apply", null otherwise.
/// The preview is rendered from a downscaled copy; the export uses the full resolution.
class EditorScreen extends StatefulWidget {
  const EditorScreen({super.key, required this.page});

  final PageItem page;

  @override
  State<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends State<EditorScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: _Tab.values.length, vsync: this);
  late ed.Edits _e = widget.page.edits.copy();
  bool _changed = false;

  ui.Image? _preview;
  ed.Edits? _previewEdits; // the edits the shown preview was rendered with
  Timer? _debounce;
  int _generation = 0;

  final _zoom = ZoomController();
  ed.RedactStyle _style = ed.RedactStyle.black;
  int? _selected;

  _Tab get _tab => _Tab.values[_tabs.index];

  /// Crop and straighten work on the whole (uncropped) frame.
  bool get _showsWholeFrame => _tab == _Tab.crop || _tab == _Tab.rotate;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(() {
      if (_tabs.indexIsChanging) return;
      setState(() => _selected = null);
      _render();
    });
    widget.page.ensureBases().then((_) => _render());
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _generation++;
    _preview?.dispose();
    _tabs.dispose();
    _zoom.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- preview

  void _render({Duration delay = Duration.zero}) {
    _debounce?.cancel();
    _debounce = Timer(delay, _renderNow);
  }

  Future<void> _renderNow() async {
    final base = widget.page.preview;
    if (base == null) return;
    final generation = ++_generation;
    final edits = _e.copy();
    if (_showsWholeFrame) edits.crop = null;
    final pixels = await renderEdited(base, widget.page.original.width, edits);
    final image = await toUiImage(pixels);
    if (!mounted || generation != _generation) {
      image.dispose();
      return;
    }
    setState(() {
      _preview?.dispose();
      _preview = image;
      _previewEdits = edits;
    });
  }

  void _update(void Function(ed.Edits e) change, {Duration delay = Duration.zero}) {
    setState(() {
      change(_e);
      _changed = true;
    });
    _render(delay: delay);
  }

  // ---------------------------------------------------------------- redaction geometry

  Size get _outputSize {
    final box = ed.cropBox(widget.page.original, _e);
    return Size(box.width.toDouble(), box.height.toDouble());
  }

  /// Redactions as boxes in output pixels (they are stored in original pixels).
  List<RedactBox> get _boxes => [
        for (final r in _e.redactions)
          (rect: _bounds([for (final p in r.polygon) ed.toOutput(widget.page.original, _e, p)]), style: r.style),
      ];

  static Rect _bounds(List<ed.Point> pts) {
    var l = double.infinity, t = double.infinity, r = -double.infinity, b = -double.infinity;
    for (final p in pts) {
      if (p.x < l) l = p.x;
      if (p.y < t) t = p.y;
      if (p.x > r) r = p.x;
      if (p.y > b) b = p.y;
    }
    return Rect.fromLTRB(l, t, r, b);
  }

  ed.Redaction _toRedaction(Rect r, ed.RedactStyle style) {
    ed.Point back(Offset o) => ed.fromOutput(widget.page.original, _e, ed.Point(o.dx, o.dy));
    return ed.Redaction([
      back(r.topLeft),
      back(r.topRight),
      back(r.bottomRight),
      back(r.bottomLeft),
    ], style);
  }

  // ---------------------------------------------------------------- leaving

  Future<void> _onPopBlocked() async {
    final discard = await confirm(
      context,
      title: tr('Discard changes?'),
      message: tr('Your changes to this page will be lost.'),
      confirmLabel: tr('Discard'),
      destructive: true,
    );
    if (discard && mounted) {
      setState(() => _changed = false);
      Navigator.pop(context);
    }
  }

  // ---------------------------------------------------------------- UI

  @override
  Widget build(BuildContext context) {
    return PopScope<ed.Edits>(
      canPop: !_changed,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onPopBlocked();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('Edit page')),
          actions: [
            IconButton(
              tooltip: tr('Reset page'),
              icon: const Icon(Icons.restart_alt),
              onPressed: () => _update((e) {
                _e = ed.Edits();
                _selected = null;
              }),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilledButton(
                onPressed: () {
                  _changed = false;
                  Navigator.pop(context, _e);
                },
                child: Text(tr('Apply')),
              ),
            ),
          ],
          bottom: TabBar(
            controller: _tabs,
            tabs: [
              Tab(icon: const Icon(Icons.crop), text: tr('Crop')),
              Tab(icon: const Icon(Icons.rotate_right), text: tr('Rotate')),
              Tab(icon: const Icon(Icons.tune), text: tr('Tone')),
              Tab(icon: const Icon(Icons.format_color_fill), text: tr('Redact')),
            ],
          ),
        ),
        body: SafeArea(
          child: Column(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: _canvas(),
                ),
              ),
              Material(
                color: Theme.of(context).colorScheme.surface,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: _controls(),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _canvas() {
    // Crop and redact overlays need a preview with the current geometry; while a new one
    // is rendered (e.g. after switching tabs) they show a spinner instead of a wrong image.
    final p = _preview;
    final pe = _previewEdits;
    final geometryOk = pe != null &&
        pe.rotate == _e.rotate &&
        pe.angle == _e.angle &&
        (_showsWholeFrame ? pe.crop == null : pe.crop == _e.crop);
    final image = geometryOk ? p : null;
    switch (_tab) {
      case _Tab.crop:
        final c = _e.crop;
        return CropView(
          image: image,
          crop: c == null ? const Rect.fromLTRB(0, 0, 1, 1) : Rect.fromLTRB(c.left, c.top, c.right, c.bottom),
          onChanged: (r) => setState(() {
            _e.crop = ed.Rect(r.left, r.top, r.right, r.bottom);
            _changed = true;
          }),
          onChangeEnd: () {},
        );
      case _Tab.rotate:
        return PreviewView(image: p, grid: true);
      case _Tab.tone:
        return PreviewView(image: p);
      case _Tab.redact:
        return RedactView(
          image: image,
          outputSize: _outputSize,
          boxes: _boxes,
          selected: _selected,
          newStyle: _style,
          zoom: _zoom,
          onAdd: (r) {
            _update((e) => e.redactions = [...e.redactions, _toRedaction(r, _style)]);
            setState(() => _selected = _e.redactions.length - 1);
          },
          onChange: (i, r) => _update((e) {
            final list = [...e.redactions];
            list[i] = _toRedaction(r, list[i].style);
            e.redactions = list;
          }),
          onSelect: (i) => setState(() {
            _selected = i;
            if (i != null) _style = _e.redactions[i].style;
          }),
        );
    }
  }

  Widget _controls() {
    return switch (_tab) {
      _Tab.crop => _cropControls(),
      _Tab.rotate => _rotateControls(),
      _Tab.tone => _toneControls(),
      _Tab.redact => _redactControls(),
    };
  }

  Widget _cropControls() {
    return Row(
      children: [
        Expanded(
          child: Text(tr('Drag the corners or edges to crop.'),
              style: Theme.of(context).textTheme.bodySmall),
        ),
        const SizedBox(width: 12),
        SizedBox(
          height: 48,
          child: OutlinedButton.icon(
            onPressed: _e.crop == null ? null : () => _update((e) => e.crop = null),
            icon: const Icon(Icons.fullscreen),
            label: Text(tr('Whole page')),
          ),
        ),
      ],
    );
  }

  Widget _rotateControls() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () => _update((e) => e.rotateBy(-90)),
                  icon: const Icon(Icons.rotate_left),
                  label: Text(tr('Rotate left')),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: () => _update((e) => e.rotateBy(90)),
                  icon: const Icon(Icons.rotate_right),
                  label: Text(tr('Rotate right')),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        _SliderRow(
          label: tr('Straighten'),
          value: _e.angle,
          min: -10,
          max: 10,
          divisions: 200,
          display: '${_e.angle >= 0 ? '+' : ''}${_e.angle.toStringAsFixed(1)}°',
          reset: 0,
          onChanged: (v) => _update((e) => e.angle = v, delay: const Duration(milliseconds: 120)),
        ),
      ],
    );
  }

  Widget _toneControls() {
    String pct(double v) => '${((v - 1) * 100).round() >= 0 ? '+' : ''}${((v - 1) * 100).round()} %';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _SliderRow(
          label: tr('Brightness'),
          value: _e.brightness,
          min: 0.5,
          max: 1.5,
          divisions: 100,
          display: pct(_e.brightness),
          reset: 1,
          onChanged: (v) =>
              _update((e) => e.brightness = v, delay: const Duration(milliseconds: 120)),
        ),
        _SliderRow(
          label: tr('Contrast'),
          value: _e.contrast,
          min: 0.5,
          max: 1.5,
          divisions: 100,
          display: pct(_e.contrast),
          reset: 1,
          onChanged: (v) =>
              _update((e) => e.contrast = v, delay: const Duration(milliseconds: 120)),
        ),
      ],
    );
  }

  Widget _redactControls() {
    final theme = Theme.of(context);
    final count = _e.redactions.length;
    final sel = _selected;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<ed.RedactStyle>(
          segments: [
            ButtonSegment(value: ed.RedactStyle.black, label: Text(tr('Black'))),
            ButtonSegment(value: ed.RedactStyle.white, label: Text(tr('White'))),
            ButtonSegment(value: ed.RedactStyle.blur, label: Text(tr('Blur'))),
          ],
          selected: {_style},
          showSelectedIcon: false,
          onSelectionChanged: (v) {
            final style = v.first;
            setState(() => _style = style);
            if (sel != null && sel < count) {
              _update((e) {
                final list = [...e.redactions];
                list[sel] = ed.Redaction(list[sel].polygon, style);
                e.redactions = list;
              });
            }
          },
        ),
        const SizedBox(height: 6),
        Text(
          _style == ed.RedactStyle.blur
              ? tr('Blur suits faces and photos. For numbers like an IBAN, black is safer.')
              : tr('Draw a box with one finger. Pinch to zoom, move with two fingers.'),
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Expanded(
              child: Text(tr('{n} redaction(s) on this page', {'n': count}),
                  style: theme.textTheme.bodySmall),
            ),
            IconButton(
              tooltip: tr('Zoom out'),
              icon: const Icon(Icons.zoom_out),
              onPressed: () => _zoom.zoomBy(1 / 1.5),
            ),
            IconButton(
              tooltip: tr('Fit'),
              icon: const Icon(Icons.fit_screen),
              onPressed: _zoom.fit,
            ),
            IconButton(
              tooltip: tr('Zoom in'),
              icon: const Icon(Icons.zoom_in),
              onPressed: () => _zoom.zoomBy(1.5),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: sel == null || sel >= count
                      ? null
                      : () {
                          _update((e) => e.redactions = [...e.redactions]..removeAt(sel));
                          setState(() => _selected = null);
                        },
                  icon: const Icon(Icons.delete_outline),
                  label: Text(tr('Delete')),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: SizedBox(
                height: 48,
                child: OutlinedButton.icon(
                  onPressed: count == 0
                      ? null
                      : () {
                          _update((e) => e.redactions = []);
                          setState(() => _selected = null);
                        },
                  icon: const Icon(Icons.layers_clear_outlined),
                  label: Text(tr('Remove all')),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _SliderRow extends StatelessWidget {
  const _SliderRow({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.display,
    required this.reset,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String display;
  final double reset;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(width: 96, child: Text(label, overflow: TextOverflow.ellipsis)),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            onChanged: onChanged,
          ),
        ),
        // Tap the value to reset it.
        InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: value == reset ? null : () => onChanged(reset),
          child: Container(
            width: 64,
            height: 48,
            alignment: Alignment.center,
            child: Text(display, style: Theme.of(context).textTheme.labelLarge),
          ),
        ),
      ],
    );
  }
}
