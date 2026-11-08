"""Reusable widgets for the proof-sheet look."""
from __future__ import annotations

from pathlib import Path

from PIL import Image
from html import escape

from PySide6.QtCore import QRect, QRectF, QSize, Qt, QUrl, Signal
from PySide6.QtGui import (QColor, QDesktopServices, QFont, QImage, QPainter, QPen, QPixmap,
                           QTextOption)
from PySide6.QtWidgets import (QAbstractItemView, QButtonGroup, QHBoxLayout, QLabel,
                               QListView, QListWidget, QPlainTextEdit, QPushButton, QScrollArea,
                               QSizePolicy, QSlider, QStyledItemDelegate, QStyle, QVBoxLayout,
                               QWidget)

from . import theme

THUMB = 150          # default longest side of a page thumbnail on screen
THUMB_MIN, THUMB_MAX = 90, 360
THUMB_SOURCE = 360   # thumbnails are rendered at this size and scaled down for display


def cell_size(thumb: int) -> QSize:
    return QSize(thumb + 44, thumb + 54)


def pil_to_pixmap(img: Image.Image) -> QPixmap:
    img = img.convert("RGB")
    data = img.tobytes("raw", "RGB")
    qimg = QImage(data, img.width, img.height, img.width * 3, QImage.Format.Format_RGB888)
    return QPixmap.fromImage(qimg.copy())


def thumb_pixmap(img: Image.Image, size: int = THUMB_SOURCE) -> QPixmap:
    small = img.copy()
    small.thumbnail((size, size))
    return pil_to_pixmap(small)


def svg_pixmap(path, height: int, ratio: float = 2.0) -> QPixmap:
    """Render an SVG crisply at the given display height."""
    from PySide6.QtSvg import QSvgRenderer
    renderer = QSvgRenderer(str(path))
    box = renderer.viewBoxF()
    width = round(height * box.width() / box.height())
    pix = QPixmap(round(width * ratio), round(height * ratio))
    pix.fill(Qt.GlobalColor.transparent)
    painter = QPainter(pix)
    renderer.render(painter)
    painter.end()
    pix.setDevicePixelRatio(ratio)
    return pix


class LinkLabel(QLabel):
    """A text link that opens ``url`` in the browser – only when it is clicked, nothing before."""

    def __init__(self, text: str, url: str, parent=None):
        super().__init__(parent)
        self.url = url
        self.setObjectName("link")
        self.setTextFormat(Qt.TextFormat.RichText)
        self.setText(f'<a href="{escape(url, quote=True)}" style="color: {theme.T["accent"]}; '
                     f'text-decoration: none;">{escape(text)}</a>')
        self.setTextInteractionFlags(Qt.TextInteractionFlag.LinksAccessibleByMouse)
        self.setOpenExternalLinks(False)
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setToolTip(url)
        self.linkActivated.connect(self.open)

    def open(self, *_args) -> None:
        QDesktopServices.openUrl(QUrl(self.url))


def eyebrow(text: str) -> QLabel:
    label = QLabel(text.upper())
    label.setObjectName("eyebrow")
    return label


def _registration_mark(p: QPainter, cx: float, cy: float, r: float) -> None:
    p.drawEllipse(QRectF(cx - r * 0.55, cy - r * 0.55, r * 1.1, r * 1.1))
    p.drawLine(int(cx - r), int(cy), int(cx + r), int(cy))
    p.drawLine(int(cx), int(cy - r), int(cx), int(cy + r))


class PaperDelegate(QStyledItemDelegate):
    """Draws each page as a sheet of paper lying on the platen, number set in mono below."""

    def __init__(self, grid: "PageGrid"):
        super().__init__(grid)
        self.grid = grid

    def sizeHint(self, option, index) -> QSize:
        return cell_size(self.grid.thumb)

    def paint(self, p: QPainter, option, index) -> None:
        p.save()
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform)
        t = self.grid.thumb
        icon = index.data(Qt.ItemDataRole.DecorationRole)
        pix: QPixmap = icon.pixmap(THUMB_SOURCE, THUMB_SOURCE) if icon is not None else QPixmap()
        cell = option.rect
        if pix.isNull():
            w, h = round(t * 0.707), t
        else:
            f = t / max(pix.width(), pix.height())
            w, h = max(1, round(pix.width() * f)), max(1, round(pix.height() * f))
        x = cell.x() + (cell.width() - w) // 2
        y = cell.y() + 12 + (t - h)
        sheet = QRect(x, y, w, h)

        # soft shadow: a few stacked translucent offsets
        shadow = QColor(theme.T["shadow"])
        for i, alpha in enumerate((50, 32, 18, 9)):
            shadow.setAlpha(alpha)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(shadow)
            p.drawRoundedRect(sheet.adjusted(-i, -i + 2, i, i + 3), 2 + i, 2 + i)

        p.setBrush(QColor(theme.T["paper"]))
        p.drawRect(sheet)
        if not pix.isNull():
            p.drawPixmap(sheet, pix)

        selected = bool(option.state & QStyle.StateFlag.State_Selected)
        if selected:
            p.setBrush(Qt.BrushStyle.NoBrush)
            p.setPen(QPen(QColor(theme.T["accent"]), 3))
            p.drawRoundedRect(sheet.adjusted(-5, -5, 5, 5), 4, 4)

        text = index.data(Qt.ItemDataRole.DisplayRole) or ""
        p.setFont(theme.mono_font(9))
        p.setPen(QColor(theme.T["accent"] if selected else theme.T["muted"]))
        p.drawText(QRect(cell.x(), sheet.bottom() + 10, cell.width(), 18),
                   Qt.AlignmentFlag.AlignHCenter, text)
        p.restore()


class PageGrid(QListWidget):
    """The platen: a grid of paper sheets with registration marks in the corners."""

    zoomChanged = Signal(int)

    def __init__(self, hint: str, reorderable: bool = True, parent: QWidget | None = None):
        super().__init__(parent)
        self.hint = hint
        self.thumb = THUMB
        self.setItemDelegate(PaperDelegate(self))
        self.setViewMode(QListView.ViewMode.IconMode)
        self.setIconSize(QSize(THUMB, THUMB))
        self.setGridSize(cell_size(THUMB))
        self.setResizeMode(QListView.ResizeMode.Adjust)
        self.setMovement(QListView.Movement.Snap if reorderable else QListView.Movement.Static)
        self.setSelectionMode(QAbstractItemView.SelectionMode.ExtendedSelection)
        self.setUniformItemSizes(True)
        self.setSpacing(8)
        self.setViewportMargins(18, 18, 18, 18)
        self.setFrameShape(QListWidget.Shape.NoFrame)
        if reorderable:
            self.setDragDropMode(QAbstractItemView.DragDropMode.InternalMove)
            self.setDefaultDropAction(Qt.DropAction.MoveAction)
        else:
            self.setDragDropMode(QAbstractItemView.DragDropMode.NoDragDrop)

    def set_thumb_size(self, size: int) -> None:
        size = max(THUMB_MIN, min(THUMB_MAX, int(size)))
        if size == self.thumb:
            return
        self.thumb = size
        self.setIconSize(QSize(size, size))
        self.setGridSize(cell_size(size))
        self.doItemsLayout()
        self.viewport().update()
        self.zoomChanged.emit(size)

    def wheelEvent(self, e) -> None:
        if e.modifiers() & Qt.KeyboardModifier.ControlModifier:     # Ctrl + wheel = zoom
            self.set_thumb_size(self.thumb + (20 if e.angleDelta().y() > 0 else -20))
            e.accept()
            return
        super().wheelEvent(e)

    def ordered_items(self):
        return [self.item(i) for i in range(self.count())]

    def renumber(self) -> None:
        for i, item in enumerate(self.ordered_items(), 1):
            item.setText(f"{i:02d}")

    def paintEvent(self, event) -> None:
        super().paintEvent(event)
        p = QPainter(self.viewport())
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        r = self.viewport().rect().adjusted(6, 6, -7, -7)
        line = QColor(theme.T["muted"])
        line.setAlpha(110)
        p.setPen(QPen(line, 1))
        p.setBrush(Qt.BrushStyle.NoBrush)
        for cx, cy in ((r.left(), r.top()), (r.right(), r.top()),
                       (r.left(), r.bottom()), (r.right(), r.bottom())):
            _registration_mark(p, cx, cy, 7)
        if self.count() == 0:
            p.setPen(QColor(theme.T["muted"]))
            p.setFont(theme.display_font(13, QFont.Weight.Normal))
            p.drawText(self.viewport().rect(), Qt.AlignmentFlag.AlignCenter, self.hint)
        p.end()


class Segmented(QWidget):
    """A row of exclusive buttons with a QComboBox-like API (data per item)."""

    currentIndexChanged = Signal(int)

    def __init__(self, items: list[tuple[str, object]] = (), parent: QWidget | None = None):
        super().__init__(parent)
        self._lay = QHBoxLayout(self)
        self._lay.setContentsMargins(0, 0, 0, 0)
        self._lay.setSpacing(0)
        self._group = QButtonGroup(self)
        self._group.setExclusive(True)
        self._group.idToggled.connect(lambda i, on: on and self.currentIndexChanged.emit(i))
        self._data: list[object] = []
        for label, data in items:
            self.addItem(label, data)

    def addItem(self, label: str, data: object = None) -> None:
        b = QPushButton(label)
        b.setCheckable(True)
        b.setCursor(Qt.CursorShape.PointingHandCursor)
        self._group.addButton(b, len(self._data))
        self._lay.addWidget(b, 1)
        self._data.append(data)
        if len(self._data) == 1:
            b.setChecked(True)
        self._restyle()

    def _restyle(self) -> None:
        buttons = self._group.buttons()
        for i, b in enumerate(buttons):
            pos = "only" if len(buttons) == 1 else "first" if i == 0 else "last" if i == len(buttons) - 1 else "mid"
            b.setProperty("seg", pos)
            b.style().unpolish(b)
            b.style().polish(b)

    def count(self) -> int:
        return len(self._data)

    def itemData(self, i: int):
        return self._data[i]

    def currentIndex(self) -> int:
        return self._group.checkedId()

    def currentData(self):
        i = self.currentIndex()
        return self._data[i] if i >= 0 else None

    def findData(self, data) -> int:
        return self._data.index(data) if data in self._data else -1

    def setCurrentIndex(self, i: int) -> None:
        b = self._group.button(i)
        if b:
            b.setChecked(True)

    def setItemEnabled(self, i: int, enabled: bool) -> None:
        self._group.button(i).setEnabled(enabled)


class CmykStripe(QWidget):
    """Registration stripe in the four process colours – the app's signature."""

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setFixedHeight(3)

    def paintEvent(self, _event) -> None:
        p = QPainter(self)
        w = self.width()
        colors = (theme.CYAN, theme.MAGENTA, theme.YELLOW, theme.T["text"] if theme.dark() else theme.KEY)
        seg = 56
        for i, c in enumerate(colors):
            p.fillRect(i * seg, 0, seg, 3, QColor(c))
        p.fillRect(4 * seg, 0, w - 4 * seg, 3, QColor(theme.T["line"]))
        p.end()


def _channel(color: str) -> str:
    c = QColor(color)
    r, g, b = c.red(), c.green(), c.blue()
    if r < 60 and g < 60 and b < 60:
        return "K"
    if r < 80 and g > 150 and b > 150:
        return "C"
    if r > 150 and g < 80 and b > 100:
        return "M"
    if r > 150 and g > 150 and b < 80:
        return "Y"
    return "•"


class TonerBar(QWidget):
    """Four slim toner gauges; exact levels are in the tooltip."""

    BAR_W, GAP, BAR_H = 5, 4, 16

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self._markers: list[tuple[str, int, str]] = []
        self.setFixedHeight(self.BAR_H)

    def set_markers(self, markers) -> None:
        self._markers = [(m.name, m.level, m.color) for m in markers]
        self.setToolTip("\n".join(
            f"{_channel(c)}  {l:>3} %   {n}" if l >= 0 else f"{_channel(c)}    ?    {n}"
            for n, l, c in self._markers))
        self.setFixedWidth(max(1, len(self._markers)) * (self.BAR_W + self.GAP))
        self.update()

    def paintEvent(self, _event) -> None:
        if not self._markers:
            return
        p = QPainter(self)
        p.setRenderHint(QPainter.RenderHint.Antialiasing)
        p.setPen(Qt.PenStyle.NoPen)
        h, w = self.BAR_H, self.BAR_W
        for i, (_name, level, color) in enumerate(self._markers):
            x = i * (w + self.GAP)
            col = QColor(color)
            if _channel(color) == "K" and theme.dark():
                col = QColor(theme.T["text"])         # black toner shown light on dark
            frac = max(0, min(100, level)) / 100 if level >= 0 else 0
            p.setBrush(QColor(theme.T["line"]))
            p.drawRoundedRect(QRectF(x, 0, w, h), 2, 2)
            p.setBrush(col)
            p.drawRoundedRect(QRectF(x, h * (1 - frac), w, h * frac), 2, 2)
        p.end()


class PreviewPage(QWidget):
    """Full-size look at one page, shown inside the main window."""

    closed = Signal()

    def __init__(self, img: Image.Image, title: str, back: str, parent: QWidget | None = None):
        super().__init__(parent)
        back_btn = QPushButton("←  " + back)
        back_btn.clicked.connect(self.closed.emit)
        label = QLabel(title)
        label.setObjectName("count")
        bar = QHBoxLayout()
        bar.setContentsMargins(14, 10, 20, 6)
        bar.addWidget(back_btn)
        bar.addSpacing(12)
        bar.addWidget(label)
        bar.addStretch()
        self._img = img
        self._label = QLabel()
        self._label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        area = QScrollArea()
        area.setWidget(self._label)
        area.setWidgetResizable(True)
        area.setFrameShape(QScrollArea.Shape.NoFrame)
        area.setStyleSheet("background: transparent;")
        lay = QVBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.addLayout(bar)
        lay.addWidget(area, 1)
        from PySide6.QtGui import QKeySequence, QShortcut
        QShortcut(QKeySequence(Qt.Key.Key_Escape), self, self.closed.emit)

    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        pix = pil_to_pixmap(self._img)
        h = max(200, self.height() - 80)
        if pix.height() > h:
            pix = pix.scaledToHeight(h, Qt.TransformationMode.SmoothTransformation)
        self._label.setPixmap(pix)


class Stepper(QWidget):
    """[ − ]  n  [ + ] – a number control that reads clearly at a glance."""

    valueChanged = Signal(int)

    def __init__(self, minimum: int = 1, maximum: int = 99, value: int = 1,
                 parent: QWidget | None = None):
        super().__init__(parent)
        self._min, self._max, self._value = minimum, maximum, value
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(0)
        self._minus = QPushButton("−")
        self._plus = QPushButton("+")
        self._label = QLabel()
        self._label.setObjectName("stepvalue")
        self._label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self._minus.setObjectName("stepbtn")
        self._plus.setObjectName("stepbtn")
        self._minus.setProperty("seg", "first")
        self._plus.setProperty("seg", "last")
        for b, step in ((self._minus, -1), (self._plus, 1)):
            b.setFixedWidth(34)
            b.setAutoRepeat(True)
            b.setCursor(Qt.CursorShape.PointingHandCursor)
            b.clicked.connect(lambda _=False, s=step: self.setValue(self._value + s))
        lay.addWidget(self._minus)
        lay.addWidget(self._label, 1)
        lay.addWidget(self._plus)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)
        self._refresh()

    def value(self) -> int:
        return self._value

    def setValue(self, value: int) -> None:
        value = max(self._min, min(self._max, int(value)))
        if value != self._value:
            self._value = value
            self.valueChanged.emit(value)
        self._refresh()

    def _refresh(self) -> None:
        self._label.setText(str(self._value))
        self._minus.setEnabled(self._value > self._min)
        self._plus.setEnabled(self._value < self._max)

    def keyPressEvent(self, e) -> None:
        if e.key() in (Qt.Key.Key_Up, Qt.Key.Key_Plus, Qt.Key.Key_Right):
            self.setValue(self._value + 1)
        elif e.key() in (Qt.Key.Key_Down, Qt.Key.Key_Minus, Qt.Key.Key_Left):
            self.setValue(self._value - 1)
        else:
            super().keyPressEvent(e)

    def wheelEvent(self, e) -> None:
        self.setValue(self._value + (1 if e.angleDelta().y() > 0 else -1))


class FileNameEdit(QPlainTextEdit):
    """Single-line value that wraps, so long file names stay fully visible."""

    INVALID = '<>:"/\\|?*'

    def __init__(self, parent: QWidget | None = None):
        super().__init__(parent)
        self.setObjectName("filename")
        self.setTabChangesFocus(True)
        self.setLineWrapMode(QPlainTextEdit.LineWrapMode.WidgetWidth)
        self.setWordWrapMode(QTextOption.WrapMode.WrapAtWordBoundaryOrAnywhere)
        self.setVerticalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        self.document().setDocumentMargin(2)
        self.textChanged.connect(self._fit)

    def text(self) -> str:
        return self.toPlainText().strip()

    def setText(self, text: str) -> None:
        self.setPlainText(text)

    def keyPressEvent(self, e) -> None:
        if e.key() in (Qt.Key.Key_Return, Qt.Key.Key_Enter):
            e.ignore()
            return
        if e.text() and e.text() in self.INVALID:
            return                                  # characters Windows forbids in names
        super().keyPressEvent(e)

    def insertFromMimeData(self, source) -> None:
        text = " ".join(source.text().split())
        for ch in self.INVALID:
            text = text.replace(ch, "_")
        self.insertPlainText(text)

    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        self._fit()

    def _fit(self) -> None:
        lines = max(1, min(4, round(self.document().size().height())))
        self.setFixedHeight(int(lines * self.fontMetrics().lineSpacing() + 18))


class FolderPicker(QPushButton):
    """Shows the target folder's name prominently and its path below, elided in the middle."""

    def __init__(self, placeholder: str, parent: QWidget | None = None):
        super().__init__(parent)
        self.setObjectName("picker")
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self._placeholder = placeholder
        self._path: Path | None = None
        lay = QVBoxLayout(self)
        lay.setContentsMargins(10, 6, 10, 6)
        lay.setSpacing(1)
        self._name = QLabel()
        self._name.setObjectName("pickername")
        self._sub = QLabel()
        self._sub.setObjectName("pickerpath")
        for label in (self._name, self._sub):
            label.setAttribute(Qt.WidgetAttribute.WA_TransparentForMouseEvents)
            lay.addWidget(label)
        self.setMinimumHeight(50)
        self.setSizePolicy(QSizePolicy.Policy.Ignored, QSizePolicy.Policy.Fixed)
        self.set_path(None)

    def path(self) -> Path | None:
        return self._path

    def set_path(self, path: Path | None) -> None:
        self._path = path
        self.setProperty("missing", path is None)
        self.style().unpolish(self)
        self.style().polish(self)
        for label in (self._name, self._sub):
            label.style().unpolish(label)
            label.style().polish(label)
        self.setToolTip(str(path) if path else self._placeholder)
        self._elide()

    def resizeEvent(self, e) -> None:
        super().resizeEvent(e)
        self._elide()

    def _elide(self) -> None:
        width = max(40, self.width() - 22)
        if self._path is None:
            self._name.setText(self._placeholder)
            self._sub.hide()
            return
        name = self._path.name or str(self._path)
        self._name.setText(self._name.fontMetrics().elidedText(name, Qt.TextElideMode.ElideRight, width))
        self._sub.show()
        parent = str(self._path.parent) if self._path.name else ""
        self._sub.setText(self._sub.fontMetrics().elidedText(parent, Qt.TextElideMode.ElideMiddle, width))


class ZoomControl(QWidget):
    """Small  ▫ ——●—— ▣  slider that sets the thumbnail size of a PageGrid."""

    def __init__(self, grid: PageGrid, settings, key: str, parent: QWidget | None = None):
        super().__init__(parent)
        self.grid, self.settings, self.key = grid, settings, key
        self.setSizePolicy(QSizePolicy.Policy.Fixed, QSizePolicy.Policy.Fixed)
        lay = QHBoxLayout(self)
        lay.setContentsMargins(0, 0, 0, 0)
        lay.setSpacing(6)
        small, big = QLabel("▫"), QLabel("▣")
        for lbl in (small, big):
            lbl.setObjectName("zoomicon")
        self.slider = QSlider(Qt.Orientation.Horizontal)
        self.slider.setRange(THUMB_MIN, THUMB_MAX)
        self.slider.setSingleStep(10)
        self.slider.setPageStep(40)
        self.slider.setFixedWidth(110)
        self.slider.setCursor(Qt.CursorShape.PointingHandCursor)
        lay.addWidget(small)
        lay.addWidget(self.slider)
        lay.addWidget(big)
        size = int(settings.value(key, THUMB))
        self.slider.setValue(size)
        grid.set_thumb_size(size)
        self.slider.valueChanged.connect(grid.set_thumb_size)
        grid.zoomChanged.connect(self._sync)

    def _sync(self, size: int) -> None:
        self.slider.blockSignals(True)
        self.slider.setValue(size)
        self.slider.blockSignals(False)
        self.settings.setValue(self.key, size)
