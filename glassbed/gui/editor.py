"""Page editor: crop, redact, rotate, straighten, brightness and contrast – page by page."""
from __future__ import annotations

from dataclasses import replace

from PIL import Image
from PySide6.QtCore import QPointF, QRectF, Qt, Signal
from PySide6.QtGui import (QColor, QKeySequence, QPainter, QPainterPath, QPen, QPixmap, QPolygonF,
                           QShortcut)
from PySide6.QtWidgets import (QHBoxLayout, QLabel, QPushButton, QSlider, QToolButton, QVBoxLayout,
                               QWidget)

from .. import edit
from ..edit import FULL, Edits
from ..i18n import tr
from . import theme
from .widgets import Segmented, eyebrow, pil_to_pixmap

PREVIEW_MAX = 1400      # editing happens on a downscaled copy; the result is applied at full size
HIRES_MAX = 3600        # sharper copy used once you zoom in
ZOOM_MAX = 8.0
HANDLE = 9
MIN_SIZE = 0.03         # smallest crop, as a fraction of the page


class CropView(QWidget):
    """Shows the page with the crop frame (tool "crop") or lets you draw redactions ("redact")."""

    cropChanged = Signal(tuple)
    redactionDrawn = Signal(tuple)      # (l, t, r, b) in frame coordinates
    redactionSelected = Signal(int)     # index, -1 = none
    redactionMoved = Signal(int, list)  # index, new corner points in frame coordinates
    redactionDragStarted = Signal(int)  # editor hides the baked-in box while it is dragged
    redactionDragEnded = Signal()
    zoomChanged = Signal(float)

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setMouseTracking(True)
        self.setMinimumSize(420, 420)
        self._pix = QPixmap()
        self._crop = FULL
        self._drag: str | None = None
        self._press = QPointF()
        self._start_crop = FULL
        self.tool = "crop"
        self._zoom = 1.0                # 1 = whole page fits
        self._pan = QPointF(0, 0)
        self._panning = False
        self._space = False
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self._polys: list[tuple[list, str]] = []    # redactions in frame coordinates
        self._selected = -1
        self._draw_rect: tuple | None = None
        self._rdrag: dict | None = None     # moving / resizing a redaction
        self._dragging_index = -1           # index whose live position is drawn as overlay

    def set_page(self, pix: QPixmap, crop) -> None:
        self._pix = pix
        self._crop = tuple(crop)
        self.update()

    def set_crop(self, crop) -> None:
        self._crop = tuple(crop)
        self.update()

    def set_tool(self, tool: str) -> None:
        self.tool = tool
        self._selected = -1
        self.setCursor(Qt.CursorShape.CrossCursor if tool == "redact" else Qt.CursorShape.ArrowCursor)
        self.update()

    def set_redactions(self, polys, selected: int = -1) -> None:
        self._polys = list(polys)
        self._selected = selected
        self.update()

    @staticmethod
    def _bbox(pts) -> tuple[float, float, float, float]:
        xs, ys = [x for x, _ in pts], [y for _, y in pts]
        return (min(xs), min(ys), max(xs), max(ys))

    def _norm_rect_widget(self, box) -> QRectF:
        img = self._image_rect()
        l, t, r, b = box
        return QRectF(img.x() + l * img.width(), img.y() + t * img.height(),
                      (r - l) * img.width(), (b - t) * img.height())

    def _edge_hit(self, rect: QRectF, p: QPointF) -> str:
        near = lambda a, b: abs(a - b) <= HANDLE  # noqa: E731
        inside_x = rect.left() - HANDLE <= p.x() <= rect.right() + HANDLE
        inside_y = rect.top() - HANDLE <= p.y() <= rect.bottom() + HANDLE
        return ("t" if near(p.y(), rect.top()) and inside_x else
                "b" if near(p.y(), rect.bottom()) and inside_x else "") + \
               ("l" if near(p.x(), rect.left()) and inside_y else
                "r" if near(p.x(), rect.right()) and inside_y else "")

    def _live_pts(self, i: int):
        if self._rdrag and self._rdrag["index"] == i and "pts" in self._rdrag:
            return self._rdrag["pts"]
        return self._polys[i][0]

    def nudge_selected(self, dx_px: float, dy_px: float) -> None:
        """Arrow keys: move the selected box by screen pixels."""
        if self._selected < 0:
            return
        img = self._image_rect()
        pts = self._polys[self._selected][0]
        l, t, r, b = self._bbox(pts)
        dx = min(max(dx_px / img.width(), -l), 1 - r)
        dy = min(max(dy_px / img.height(), -t), 1 - b)
        self.redactionMoved.emit(self._selected, [(x + dx, y + dy) for x, y in pts])

    def _poly_widget(self, pts) -> QPolygonF:
        img = self._image_rect()
        return QPolygonF([QPointF(img.x() + x * img.width(), img.y() + y * img.height()) for x, y in pts])

    # geometry helpers ------------------------------------------------------
    def _area(self) -> QRectF:
        return QRectF(self.rect()).adjusted(28, 28, -28, -28)

    def _image_rect(self) -> QRectF:
        if self._pix.isNull():
            return QRectF()
        area = self._area()
        f = min(area.width() / self._pix.width(), area.height() / self._pix.height()) * self._zoom
        w, h = self._pix.width() * f, self._pix.height() * f
        return QRectF(area.center().x() - w / 2 + self._pan.x(),
                      area.center().y() - h / 2 + self._pan.y(), w, h)

    # zoom & pan ------------------------------------------------------------
    def zoom(self) -> float:
        return self._zoom

    def displayed_scale(self) -> float:
        """Screen pixels per preview pixel – above 1 the preview gets blurry."""
        return self._image_rect().width() / self._pix.width() if not self._pix.isNull() else 1.0

    def zoom_at(self, factor: float, anchor: QPointF | None = None) -> None:
        if self._pix.isNull():
            return
        anchor = anchor if anchor is not None else self._area().center()
        before = self._image_rect()
        nx = (anchor.x() - before.x()) / before.width()
        ny = (anchor.y() - before.y()) / before.height()
        self._zoom = min(ZOOM_MAX, max(1.0, self._zoom * factor))
        after = self._image_rect()
        # keep the point under the mouse where it is
        self._pan += QPointF(anchor.x() - (after.x() + nx * after.width()),
                             anchor.y() - (after.y() + ny * after.height()))
        self._clamp_pan()
        self.update()
        self.zoomChanged.emit(self._zoom)

    def fit(self) -> None:
        self._zoom, self._pan = 1.0, QPointF(0, 0)
        self.update()
        self.zoomChanged.emit(self._zoom)

    def _clamp_pan(self) -> None:
        """No empty margin while zoomed in; centred when the page is smaller than the view."""
        if self._zoom <= 1.0:
            self._pan = QPointF(0, 0)
            return
        area, img = self._area(), self._image_rect()

        def axis(lo, hi, img_lo, img_hi, a_c, i_c):
            if img_hi - img_lo <= hi - lo:
                return a_c - i_c                     # smaller than the view: centre it
            if img_lo > lo:
                return lo - img_lo
            if img_hi < hi:
                return hi - img_hi
            return 0.0

        dx = axis(area.left(), area.right(), img.left(), img.right(), area.center().x(), img.center().x())
        dy = axis(area.top(), area.bottom(), img.top(), img.bottom(), area.center().y(), img.center().y())
        self._pan += QPointF(dx, dy)

    def wheelEvent(self, e) -> None:
        self.zoom_at(1.25 if e.angleDelta().y() > 0 else 0.8, e.position())

    def keyPressEvent(self, e) -> None:
        if e.key() == Qt.Key.Key_Space and not e.isAutoRepeat():
            self._space = True
            self.setCursor(Qt.CursorShape.OpenHandCursor)
        elif e.key() in (Qt.Key.Key_Plus, Qt.Key.Key_Equal):
            self.zoom_at(1.25)
        elif e.key() == Qt.Key.Key_Minus:
            self.zoom_at(0.8)
        elif e.key() == Qt.Key.Key_0:
            self.fit()
        elif self.tool == "redact" and self._selected >= 0 and e.key() in (
                Qt.Key.Key_Left, Qt.Key.Key_Right, Qt.Key.Key_Up, Qt.Key.Key_Down):
            step = 10 if e.modifiers() & Qt.KeyboardModifier.ShiftModifier else 1
            dx = {Qt.Key.Key_Left: -step, Qt.Key.Key_Right: step}.get(e.key(), 0)
            dy = {Qt.Key.Key_Up: -step, Qt.Key.Key_Down: step}.get(e.key(), 0)
            self.nudge_selected(dx, dy)
        else:
            super().keyPressEvent(e)

    def keyReleaseEvent(self, e) -> None:
        if e.key() == Qt.Key.Key_Space and not e.isAutoRepeat():
            self._space = False
            self.set_tool(self.tool)
        else:
            super().keyReleaseEvent(e)

    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        self._clamp_pan()

    def _crop_rect(self) -> QRectF:
        img = self._image_rect()
        l, t, r, b = self._crop
        return QRectF(img.x() + l * img.width(), img.y() + t * img.height(),
                      (r - l) * img.width(), (b - t) * img.height())

    def _to_norm(self, p: QPointF) -> tuple[float, float]:
        img = self._image_rect()
        return ((p.x() - img.x()) / img.width(), (p.y() - img.y()) / img.height())

    def _hit(self, p: QPointF) -> str | None:
        c = self._crop_rect()
        near = lambda a, b: abs(a - b) <= HANDLE + 3  # noqa: E731
        left, right = near(p.x(), c.left()), near(p.x(), c.right())
        top, bottom = near(p.y(), c.top()), near(p.y(), c.bottom())
        inside_x = c.left() - HANDLE <= p.x() <= c.right() + HANDLE
        inside_y = c.top() - HANDLE <= p.y() <= c.bottom() + HANDLE
        edge = ("t" if top and inside_x else "b" if bottom and inside_x else "") + \
               ("l" if left and inside_y else "r" if right and inside_y else "")
        if edge:
            return edge
        if c.contains(p):
            return "move"
        return "new" if self._image_rect().contains(p) else None

    # painting --------------------------------------------------------------
    def paintEvent(self, _e) -> None:
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        p.fillRect(self.rect(), QColor(theme.T["platen"]))
        if self._pix.isNull():
            return
        img = self._image_rect()
        p.drawPixmap(img, self._pix, QRectF(self._pix.rect()))
        c = self._crop_rect()

        shade = QPainterPath()
        shade.addRect(img)
        inner = QPainterPath()
        inner.addRect(c)
        p.fillPath(shade.subtracted(inner), QColor(0, 0, 0, 140 if self.tool == "crop" else 70))

        accent = QColor(theme.T["accent"])
        if self.tool == "redact":
            for i, (pts, color) in enumerate(self._polys):
                pts = self._live_pts(i)
                if i == self._dragging_index:       # live preview while moving / resizing
                    fill = {"black": QColor(0, 0, 0), "white": QColor(255, 255, 255)}.get(
                        color, QColor(150, 150, 150, 200))
                    p.setPen(Qt.PenStyle.NoPen)
                    p.setBrush(fill)
                    p.drawPolygon(self._poly_widget(pts))
                pen = QPen(accent, 3 if i == self._selected else 1)
                if i != self._selected:
                    pen.setStyle(Qt.PenStyle.DashLine)
                p.setPen(pen)
                p.setBrush(Qt.BrushStyle.NoBrush)
                p.drawPolygon(self._poly_widget(pts))
            if 0 <= self._selected < len(self._polys):     # handles on the selected box
                box = self._norm_rect_widget(self._bbox(self._live_pts(self._selected)))
                p.setBrush(QColor("#FFFFFF"))
                p.setPen(QPen(accent, 2))
                for x in (box.left(), box.center().x(), box.right()):
                    for y in (box.top(), box.center().y(), box.bottom()):
                        if x == box.center().x() and y == box.center().y():
                            continue
                        p.drawRect(QRectF(x - HANDLE / 2, y - HANDLE / 2, HANDLE, HANDLE))
            if self._draw_rect:
                l, t, r, b = self._draw_rect
                p.setPen(QPen(accent, 2))
                p.setBrush(QColor(0, 0, 0, 170))
                p.drawPolygon(self._poly_widget([(l, t), (r, t), (r, b), (l, b)]))
            p.end()
            return
        if self._drag:                                     # rule of thirds while dragging
            guide = QColor(255, 255, 255, 90)
            p.setPen(QPen(guide, 1))
            for i in (1, 2):
                x = c.left() + c.width() * i / 3
                y = c.top() + c.height() * i / 3
                p.drawLine(QPointF(x, c.top()), QPointF(x, c.bottom()))
                p.drawLine(QPointF(c.left(), y), QPointF(c.right(), y))
        p.setPen(QPen(accent, 2))
        p.setBrush(Qt.BrushStyle.NoBrush)
        p.drawRect(c)
        p.setBrush(QColor("#FFFFFF"))
        p.setPen(QPen(accent, 2))
        for x in (c.left(), c.center().x(), c.right()):
            for y in (c.top(), c.center().y(), c.bottom()):
                if x == c.center().x() and y == c.center().y():
                    continue
                p.drawRect(QRectF(x - HANDLE / 2, y - HANDLE / 2, HANDLE, HANDLE))
        p.end()

    # interaction -----------------------------------------------------------
    CURSORS = {"t": Qt.CursorShape.SizeVerCursor, "b": Qt.CursorShape.SizeVerCursor,
               "l": Qt.CursorShape.SizeHorCursor, "r": Qt.CursorShape.SizeHorCursor,
               "tl": Qt.CursorShape.SizeFDiagCursor, "br": Qt.CursorShape.SizeFDiagCursor,
               "tr": Qt.CursorShape.SizeBDiagCursor, "bl": Qt.CursorShape.SizeBDiagCursor,
               "move": Qt.CursorShape.SizeAllCursor, "new": Qt.CursorShape.CrossCursor}

    def _redaction_at(self, pos: QPointF) -> int:
        for i in range(len(self._polys) - 1, -1, -1):
            if self._poly_widget(self._polys[i][0]).containsPoint(pos, Qt.FillRule.OddEvenFill):
                return i
        return -1

    def mousePressEvent(self, e) -> None:
        self.setFocus()
        pan_button = e.button() in (Qt.MouseButton.MiddleButton, Qt.MouseButton.RightButton)
        if pan_button or (self._space and e.button() == Qt.MouseButton.LeftButton):
            self._panning = True
            self._press = e.position()
            self._pan_start = QPointF(self._pan)
            self.setCursor(Qt.CursorShape.ClosedHandCursor)
            return
        if e.button() != Qt.MouseButton.LeftButton:
            return
        if self.tool == "redact":
            pos = e.position()
            # 1. a handle of the selected box → resize
            if 0 <= self._selected < len(self._polys):
                pts = self._polys[self._selected][0]
                edge = self._edge_hit(self._norm_rect_widget(self._bbox(pts)), pos)
                if edge:
                    self._rdrag = {"index": self._selected, "mode": edge, "box": self._bbox(pts),
                                   "press": pos, "started": False}
                    return
            # 2. a box → select it and get ready to move it
            hit = self._redaction_at(pos)
            self._selected = hit
            self.redactionSelected.emit(hit)
            if hit >= 0:
                self._rdrag = {"index": hit, "mode": "move", "start": list(self._polys[hit][0]),
                               "press": pos, "started": False}
                self.setCursor(Qt.CursorShape.SizeAllCursor)
                self.update()
                return
            # 3. empty page → draw a new box
            if self._image_rect().contains(pos):
                x, y = self._to_norm(e.position())
                self._draw_rect = (x, y, x, y)
                self._press = e.position()
            self.update()
            return
        self._drag = self._hit(e.position())
        self._press = e.position()
        self._start_crop = self._crop
        if self._drag == "new":
            x, y = self._to_norm(e.position())
            self._start_crop = (x, y, x, y)
            self._drag = "br"

    def mouseMoveEvent(self, e) -> None:
        if self._panning:
            self._pan = self._pan_start + (e.position() - self._press)
            self._clamp_pan()
            self.update()
            return
        if self.tool == "redact" and self._rdrag:
            d = self._rdrag
            if not d["started"]:
                if (e.position() - d["press"]).manhattanLength() < 3:
                    return
                d["started"] = True
                self._dragging_index = d["index"]
                self.redactionDragStarted.emit(d["index"])
            x, y = self._to_norm(e.position())
            px, py = self._to_norm(d["press"])
            if d["mode"] == "move":
                l, t, r, b = self._bbox(d["start"])
                dx = min(max(x - px, -l), 1 - r)
                dy = min(max(y - py, -t), 1 - b)
                d["pts"] = [(sx + dx, sy + dy) for sx, sy in d["start"]]
            else:
                l, t, r, b = d["box"]
                x, y = min(max(x, 0.0), 1.0), min(max(y, 0.0), 1.0)
                if "l" in d["mode"]:
                    l = min(x, r - 0.004)
                if "r" in d["mode"]:
                    r = max(x, l + 0.004)
                if "t" in d["mode"]:
                    t = min(y, b - 0.003)
                if "b" in d["mode"]:
                    b = max(y, t + 0.003)
                d["pts"] = [(l, t), (r, t), (r, b), (l, b)]
            self.update()
            return
        if self.tool == "redact":
            if self._draw_rect:
                x0, y0 = self._to_norm(self._press)
                x, y = self._to_norm(e.position())
                x, y = min(max(x, 0.0), 1.0), min(max(y, 0.0), 1.0)
                self._draw_rect = (min(x0, x), min(y0, y), max(x0, x), max(y0, y))
                self.update()
            else:
                cursor = Qt.CursorShape.CrossCursor
                if 0 <= self._selected < len(self._polys):
                    edge = self._edge_hit(self._norm_rect_widget(self._bbox(self._polys[self._selected][0])),
                                          e.position())
                    if edge:
                        cursor = self.CURSORS[edge]
                if cursor == Qt.CursorShape.CrossCursor and self._redaction_at(e.position()) >= 0:
                    cursor = Qt.CursorShape.SizeAllCursor
                self.setCursor(cursor)
            return
        if not self._drag:
            hit = self._hit(e.position())
            self.setCursor(self.CURSORS.get(hit, Qt.CursorShape.ArrowCursor))
            return
        x, y = self._to_norm(e.position())
        px, py = self._to_norm(self._press)
        l, t, r, b = self._start_crop
        if self._drag == "move":
            dx = min(max(x - px, -l), 1 - r)
            dy = min(max(y - py, -t), 1 - b)
            crop = (l + dx, t + dy, r + dx, b + dy)
        else:
            x, y = min(max(x, 0.0), 1.0), min(max(y, 0.0), 1.0)
            if "l" in self._drag:
                l = min(x, r - MIN_SIZE)
            if "r" in self._drag:
                r = max(x, l + MIN_SIZE)
            if "t" in self._drag:
                t = min(y, b - MIN_SIZE)
            if "b" in self._drag:
                b = max(y, t + MIN_SIZE)
            crop = (l, t, min(r, 1.0), min(b, 1.0))
        self._crop = crop
        self.update()

    def mouseReleaseEvent(self, _e) -> None:
        if self._panning:
            self._panning = False
            self.setCursor(Qt.CursorShape.OpenHandCursor if self._space else Qt.CursorShape.ArrowCursor)
            if not self._space:
                self.set_tool(self.tool)
            return
        if self.tool == "redact" and self._rdrag:
            d, self._rdrag = self._rdrag, None
            self._dragging_index = -1
            if d["started"] and "pts" in d:
                self.redactionMoved.emit(d["index"], d["pts"])
            elif d["started"]:
                self.redactionDragEnded.emit()
            self.update()
            return
        if self.tool == "redact":
            rect, self._draw_rect = self._draw_rect, None
            if rect and (rect[2] - rect[0]) > 0.004 and (rect[3] - rect[1]) > 0.002:
                self.redactionDrawn.emit(rect)
            self.update()
            return
        if self._drag:
            self._drag = None
            self.cropChanged.emit(self._crop)
            self.update()

    def mouseDoubleClickEvent(self, _e) -> None:        # double-click: whole page
        if self.tool == "redact":
            return
        self._crop = FULL
        self.cropChanged.emit(self._crop)
        self.update()


class _Slider(QWidget):
    """Labelled slider with a value readout; double-click resets to neutral."""

    valueChanged = Signal(float)

    def __init__(self, title: str, lo: float, hi: float, neutral: float, scale: float, fmt):
        super().__init__()
        self.neutral, self.scale, self.fmt = neutral, scale, fmt
        head = QHBoxLayout()
        head.setContentsMargins(0, 0, 0, 0)
        head.addWidget(eyebrow(title))
        head.addStretch()
        self.readout = QLabel()
        self.readout.setObjectName("count")
        head.addWidget(self.readout)
        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(round(lo * scale), round(hi * scale))
        self.slider.valueChanged.connect(self._changed)
        self.slider.setCursor(Qt.CursorShape.PointingHandCursor)
        self.slider.setToolTip(tr("Double-click to reset"))
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(4)
        lay.addLayout(head)
        lay.addWidget(self.slider)
        self.setValue(neutral)

    def value(self) -> float:
        return self.slider.value() / self.scale

    def setValue(self, v: float) -> None:
        self.slider.blockSignals(True)
        self.slider.setValue(round(v * self.scale))
        self.slider.blockSignals(False)
        self.readout.setText(self.fmt(self.value()))

    def _changed(self, _v) -> None:
        self.readout.setText(self.fmt(self.value()))
        self.valueChanged.emit(self.value())

    def mouseDoubleClickEvent(self, _e) -> None:
        self.setValue(self.neutral)
        self.valueChanged.emit(self.neutral)


def _signed(v: float, unit: str, digits: int = 0) -> str:
    text = f"{v:+.{digits}f}{unit}"
    return text.replace(".", ",") if tr("Save") != "Save" else text


class PageEditor(QWidget):
    """Edit several pages inside the main window.

    Emits ``applied(list[Edits])`` on "Apply" and ``closed`` when the view should go away.
    """

    applied = Signal(list)
    closed = Signal()

    def __init__(self, originals: list[Image.Image], edits: list[Edits], start: int = 0,
                 parent: QWidget | None = None):
        super().__init__(parent)
        self.setObjectName("editor")
        self._originals = originals
        self._edits = list(edits)
        self._previews: dict[int, Image.Image] = {}
        self._index = start
        self._geo_cache: tuple | None = None

        self.view = CropView()
        self.view.cropChanged.connect(self._crop_changed)
        self.view.redactionDrawn.connect(self._add_redaction)
        self.view.redactionSelected.connect(self._select_redaction)
        self.view.redactionMoved.connect(self._redaction_moved)
        self.view.redactionDragStarted.connect(self._redaction_drag_started)
        self.view.redactionDragEnded.connect(self._redaction_drag_ended)
        self._selected = -1
        self._exclude = -1          # redaction hidden from the rendered page while being dragged

        self.tool = Segmented([(tr("Crop"), "crop"), (tr("Redact"), "redact")])
        self.tool.currentIndexChanged.connect(lambda _: self._set_tool(self.tool.currentData()))
        self.redact_color = Segmented([(tr("Black"), "black"), (tr("White"), "white"), (tr("Blur"), "blur")])
        self.redact_color.currentIndexChanged.connect(lambda _: self._recolor_selected())
        self.redact_color.currentIndexChanged.connect(
            lambda _: self.blur_hint.setVisible(self.redact_color.currentData() == "blur"))
        self.del_redaction = QPushButton(tr("Delete"))
        self.del_redaction.clicked.connect(self._delete_redaction)
        self.clear_redactions = QPushButton(tr("Remove all"))
        self.clear_redactions.clicked.connect(self._clear_redactions)
        self.redact_count = QLabel()
        self.redact_count.setObjectName("count")

        auto = QPushButton(tr("Auto"))
        auto.setToolTip(tr("Find the document on the scanner glass"))
        auto.clicked.connect(self._auto_crop)
        whole = QPushButton(tr("Whole page"))
        whole.clicked.connect(lambda: self._crop_changed(FULL))
        rot_l = QPushButton("↺  90°")
        rot_l.clicked.connect(lambda: self._rotate(90))
        rot_r = QPushButton("↻  90°")
        rot_r.clicked.connect(lambda: self._rotate(-90))

        self.straighten = _Slider(tr("Straighten"), -10, 10, 0.0, 10, lambda v: _signed(v, "°", 1))
        self.brightness = _Slider(tr("Brightness"), 0.5, 1.5, 1.0, 100,
                                  lambda v: _signed((v - 1) * 100, " %"))
        self.contrast = _Slider(tr("Contrast"), 0.5, 1.8, 1.0, 100,
                                lambda v: _signed((v - 1) * 100, " %"))
        self.straighten.valueChanged.connect(lambda v: self._set(angle=v))
        self.brightness.valueChanged.connect(lambda v: self._set(brightness=v))
        self.contrast.valueChanged.connect(lambda v: self._set(contrast=v))

        reset = QPushButton(tr("Reset page"))
        reset.clicked.connect(self._reset)
        self.prev_btn = QPushButton("‹")
        self.next_btn = QPushButton("›")
        for b in (self.prev_btn, self.next_btn):
            b.setFixedWidth(40)
        self.prev_btn.clicked.connect(lambda: self._go(self._index - 1))
        self.next_btn.clicked.connect(lambda: self._go(self._index + 1))
        self.page_lbl = QLabel()
        self.page_lbl.setObjectName("status")
        self.page_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        cancel = QPushButton(tr("Cancel"))
        cancel.clicked.connect(self.closed.emit)
        ok = QPushButton(tr("Apply"))
        ok.setObjectName("primary")
        ok.clicked.connect(self._apply)

        def row(*widgets):
            r = QHBoxLayout()
            r.setSpacing(6)
            for w in widgets:
                r.addWidget(w, 1)
            return r

        side = QVBoxLayout()
        side.setContentsMargins(20, 22, 20, 20)
        side.setSpacing(6)
        title = QLabel(tr("Edit page"))
        title.setObjectName("wordmark")
        side.addWidget(title)
        side.addSpacing(14)
        side.addWidget(eyebrow(tr("Tool")))
        side.addWidget(self.tool)
        side.addSpacing(10)

        crop_lay = QVBoxLayout()
        crop_lay.setContentsMargins(0, 0, 0, 0)
        crop_lay.setSpacing(6)
        crop_lay.addLayout(row(auto, whole))
        hint = QLabel(tr("Drag the frame or its handles. Double-click: whole page."))
        hint.setObjectName("hint")
        hint.setWordWrap(True)
        crop_lay.addWidget(hint)
        self.crop_box = QWidget()
        self.crop_box.setLayout(crop_lay)

        red_lay = QVBoxLayout()
        red_lay.setContentsMargins(0, 0, 0, 0)
        red_lay.setSpacing(6)
        red_lay.addWidget(self.redact_color)
        red_lay.addLayout(row(self.del_redaction, self.clear_redactions))
        red_hint = QLabel(tr("Drag a box over what should disappear. Click a box to select it, Del removes it. "
                             "It is burned into the saved file and cannot be undone there."))
        self.blur_hint = QLabel(tr("Blur suits faces and photos. For numbers like an IBAN, black is safer."))
        self.blur_hint.setObjectName("hint")
        self.blur_hint.setWordWrap(True)
        self.blur_hint.hide()
        red_hint.setObjectName("hint")
        red_hint.setWordWrap(True)
        red_lay.addWidget(red_hint)
        red_lay.addWidget(self.blur_hint)
        red_lay.addWidget(self.redact_count)
        self.redact_box = QWidget()
        self.redact_box.setLayout(red_lay)
        self.redact_box.hide()

        side.addWidget(self.crop_box)
        side.addWidget(self.redact_box)
        side.addSpacing(12)
        side.addWidget(eyebrow(tr("Rotate")))
        side.addLayout(row(rot_l, rot_r))
        side.addSpacing(12)
        for s in (self.straighten, self.brightness, self.contrast):
            side.addWidget(s)
            side.addSpacing(10)
        side.addWidget(reset)
        side.addStretch()
        nav = QHBoxLayout()
        nav.addWidget(self.prev_btn)
        nav.addWidget(self.page_lbl, 1)
        nav.addWidget(self.next_btn)
        side.addLayout(nav)
        side.addSpacing(10)
        side.addLayout(row(cancel, ok))
        panel = QWidget()
        panel.setObjectName("sidebar_r")
        panel.setLayout(side)
        panel.setFixedWidth(272)

        # zoom bar floating over the page (bottom left)
        self.zoom_bar = QWidget(self.view)
        self.zoom_bar.setObjectName("zoombar")
        zl = QHBoxLayout(self.zoom_bar)
        zl.setContentsMargins(6, 4, 6, 4)
        zl.setSpacing(2)
        z_out, z_in, z_fit = QToolButton(), QToolButton(), QToolButton()
        z_out.setText("−")
        z_in.setText("+")
        z_fit.setText(tr("Fit"))
        z_out.setToolTip(tr("Zoom out") + "  (−)")
        z_in.setToolTip(tr("Zoom in") + "  (+)")
        z_fit.setToolTip(tr("Whole page") + "  (0)")
        self.zoom_lbl = QLabel("100 %")
        self.zoom_lbl.setObjectName("count")
        self.zoom_lbl.setFixedWidth(52)
        self.zoom_lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
        z_out.clicked.connect(lambda: self.view.zoom_at(0.8))
        z_in.clicked.connect(lambda: self.view.zoom_at(1.25))
        z_fit.clicked.connect(self.view.fit)
        for wdg in (z_out, self.zoom_lbl, z_in, z_fit):
            zl.addWidget(wdg)
        self.view.zoomChanged.connect(self._zoom_changed)
        pan_hint = QLabel(tr("Mouse wheel: zoom · Space or right mouse button + drag: move"))
        pan_hint.setObjectName("hint")
        zl.addSpacing(10)
        zl.addWidget(pan_hint)
        self.zoom_bar.adjustSize()
        self._hires = False

        root = QHBoxLayout(self)
        root.setContentsMargins(0, 0, 0, 0)
        root.setSpacing(0)
        root.addWidget(self.view, 1)
        root.addWidget(panel)

        QShortcut(QKeySequence(Qt.Key.Key_PageUp), self, lambda: self._go(self._index - 1))
        QShortcut(QKeySequence(Qt.Key.Key_PageDown), self, lambda: self._go(self._index + 1))
        QShortcut(QKeySequence("Ctrl+Z"), self, self._reset)
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, self.closed.emit)
        QShortcut(QKeySequence(Qt.Key.Key_Delete), self, self._delete_redaction)
        QShortcut(QKeySequence("S"), self, lambda: self.tool.setCurrentIndex(1))
        QShortcut(QKeySequence("C"), self, lambda: self.tool.setCurrentIndex(0))
        self._load()

    # state -----------------------------------------------------------------
    @property
    def _e(self) -> Edits:
        return self._edits[self._index]

    def _preview_source(self) -> Image.Image:
        key = (self._index, self._hires)
        if key not in self._previews:
            img = self._originals[self._index].copy()
            if img.mode == "1":
                img = img.convert("L")
            img.thumbnail((HIRES_MAX, HIRES_MAX) if self._hires else (PREVIEW_MAX, PREVIEW_MAX))
            self._previews[key] = img
        return self._previews[key]

    def _zoom_changed(self, zoom: float) -> None:
        self.zoom_lbl.setText(f"{round(zoom * 100)} %")
        if not self._hires and self.view.displayed_scale() > 1.15 and \
                max(self._originals[self._index].size) > PREVIEW_MAX:
            self._hires = True                  # zoomed in: switch to the sharp copy
            self._geo_cache = None
            self._render()

    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        self.zoom_bar.adjustSize()
        self.zoom_bar.move(14, self.view.height() - self.zoom_bar.height() - 14)

    def _render(self) -> None:
        e = self._e
        src = self._preview_source()
        painted = tuple(rd for i, rd in enumerate(e.redactions) if i != self._exclude)
        key = (self._index, e.rotate, round(e.angle, 2), painted)
        if self._geo_cache is None or self._geo_cache[0] != key:
            self._geo_cache = (key, edit.geometry(edit.paint_redactions(src, painted), e))
        shown = edit.tone(self._geo_cache[1], e)
        self.view.set_page(pil_to_pixmap(shown), e.crop)
        polys = [(edit.to_frame(poly, src.size, e), color) for poly, color in e.redactions]
        if self._selected >= len(polys):
            self._selected = -1
        self.view.set_redactions(polys, self._selected)
        n = len(polys)
        self.redact_count.setText(tr("{n} redaction(s) on this page", n=n) if n else "")
        self.del_redaction.setEnabled(self._selected >= 0)
        self.clear_redactions.setEnabled(n > 0)

    def _load(self) -> None:
        e = self._e
        self.straighten.setValue(e.angle)
        self.brightness.setValue(e.brightness)
        self.contrast.setValue(e.contrast)
        n = len(self._originals)
        self.page_lbl.setText(f"{self._index + 1} / {n}")
        self.prev_btn.setEnabled(self._index > 0)
        self.next_btn.setEnabled(self._index < n - 1)
        self.prev_btn.setVisible(n > 1)
        self.next_btn.setVisible(n > 1)
        self._render()

    def _set(self, **changes) -> None:
        self._edits[self._index] = replace(self._e, **changes)
        self._render()

    def _crop_changed(self, crop) -> None:
        self._edits[self._index] = replace(self._e, crop=tuple(crop))
        self.view.set_crop(crop)

    def _rotate(self, degrees: int) -> None:
        self._edits[self._index] = self._e.rotated(degrees)
        self._render()

    def _auto_crop(self) -> None:
        geo = edit.geometry(self._preview_source(), self._e)
        self._crop_changed(edit.content_box(geo))

    def _reset(self) -> None:
        self._edits[self._index] = Edits()
        self._load()

    def _go(self, index: int) -> None:
        if 0 <= index < len(self._originals):
            self._index = index
            self._selected = -1
            self._hires = False
            self._geo_cache = None
            self._load()
            self.view.fit()

    # redaction -------------------------------------------------------------
    def _set_tool(self, tool: str) -> None:
        self.view.set_tool(tool)
        self.crop_box.setVisible(tool == "crop")
        self.redact_box.setVisible(tool == "redact")
        self._selected = -1
        self._render()

    def _add_redaction(self, rect) -> None:
        l, t, r, b = rect
        poly = tuple(edit.from_frame([(l, t), (r, t), (r, b), (l, b)], self._preview_source().size, self._e))
        e = self._e
        self._edits[self._index] = replace(e, redactions=e.redactions + ((poly, self.redact_color.currentData()),))
        self._selected = -1        # the colour buttons now apply to the next box, not this one
        self._render()

    def _redaction_drag_started(self, index: int) -> None:
        self._exclude = index
        self._selected = index
        self._render()

    def _redaction_drag_ended(self) -> None:
        self._exclude = -1
        self._render()

    def _redaction_moved(self, index: int, frame_pts: list) -> None:
        reds = list(self._e.redactions)
        if not 0 <= index < len(reds):
            return
        poly = tuple(edit.from_frame(frame_pts, self._preview_source().size, self._e))
        reds[index] = (poly, reds[index][1])
        self._edits[self._index] = replace(self._e, redactions=tuple(reds))
        self._exclude = -1
        self._selected = index
        self._render()

    def _select_redaction(self, index: int) -> None:
        self._selected = index
        if index >= 0:
            color = self._e.redactions[index][1]
            self.redact_color.blockSignals(True)
            self.redact_color.setCurrentIndex(self.redact_color.findData(color))
            self.redact_color.blockSignals(False)
        self.del_redaction.setEnabled(index >= 0)

    def _recolor_selected(self) -> None:
        if self._selected < 0:
            return
        reds = list(self._e.redactions)
        poly, _ = reds[self._selected]
        reds[self._selected] = (poly, self.redact_color.currentData())
        self._edits[self._index] = replace(self._e, redactions=tuple(reds))
        self._render()

    def _delete_redaction(self) -> None:
        if self._selected < 0:
            return
        reds = list(self._e.redactions)
        del reds[self._selected]
        self._selected = -1
        self._edits[self._index] = replace(self._e, redactions=tuple(reds))
        self._render()

    def _clear_redactions(self) -> None:
        self._selected = -1
        self._edits[self._index] = replace(self._e, redactions=())
        self._render()

    def result_edits(self) -> list[Edits]:
        return self._edits

    def _apply(self) -> None:
        self.applied.emit(self._edits)
        self.closed.emit()
