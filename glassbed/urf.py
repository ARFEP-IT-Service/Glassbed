"""Apple raster (URF / "UNIRAST") encoder.

URF is the raster format every AirPrint printer must accept. A file is
``b"UNIRAST\\0"`` + page count, followed by pages that each have a 32-byte
header and PackBits-style compressed lines:

* every line starts with a line-repeat byte (number of extra copies of the line)
* then packets: ``0x00-0x7F`` -> next pixel repeated n+1 times,
  ``0x81-0xFF`` -> 257-n literal pixels follow, ``0x80`` -> rest of line is white.
"""
from __future__ import annotations

import struct
from typing import Callable, Iterable

import numpy as np
from PIL import Image

COLORSPACE_SGRAY = 0
COLORSPACE_SRGB = 1
QUALITY_NORMAL = 4
DUPLEX_SIMPLEX = 1


def file_header(page_count: int) -> bytes:
    return b"UNIRAST\x00" + struct.pack(">I", page_count)


def page_header(width: int, height: int, dpi: int, color: bool) -> bytes:
    return struct.pack(
        ">BBBBIIIIIII",
        24 if color else 8,
        COLORSPACE_SRGB if color else COLORSPACE_SGRAY,
        DUPLEX_SIMPLEX,
        QUALITY_NORMAL,
        0, 0,
        width, height, dpi,
        0, 0,
    )


def _encode_line(row: np.ndarray, keys: np.ndarray, white_key: int, bpp: int) -> bytes:
    """Encode the pixels of one line (no line-repeat byte)."""
    width = keys.shape[0]
    non_white = np.flatnonzero(keys != white_key)
    if non_white.size == 0:
        return b"\x80"
    end = int(non_white[-1]) + 1
    k = keys[:end]
    raw = row[:end].tobytes()
    out = bytearray()

    starts = np.flatnonzero(np.concatenate(([True], k[1:] != k[:-1])))
    if starts.size > end // 3:
        # Noisy line (photo): runs don't pay off, emit literal chunks.
        for s in range(0, end, 128):
            n = min(128, end - s)
            out.append(0 if n == 1 else 257 - n)
            out.extend(raw[s * bpp:(s + n) * bpp])
    else:
        lengths = np.diff(np.append(starts, end))
        lit_start = None

        def flush_literal(upto: int) -> None:
            nonlocal lit_start
            s = lit_start
            while s is not None and s < upto:
                n = min(128, upto - s)
                out.append(0 if n == 1 else 257 - n)
                out.extend(raw[s * bpp:(s + n) * bpp])
                s += n
            lit_start = None

        for s, n in zip(starts.tolist(), lengths.tolist()):
            if n == 1:
                if lit_start is None:
                    lit_start = s
                continue
            flush_literal(s)
            pixel = raw[s * bpp:(s + 1) * bpp]
            while n > 0:
                r = min(128, n)
                out.append(r - 1)
                out += pixel
                n -= r
        flush_literal(end)

    if end < width:
        out.append(0x80)
    return bytes(out)


def encode_page(img: Image.Image, dpi: int, color: bool) -> bytes:
    img = img.convert("RGB" if color else "L")
    arr = np.asarray(img)
    height, width = arr.shape[0], arr.shape[1]
    if color:
        a32 = arr.astype(np.uint32)
        keys = (a32[:, :, 0] << 16) | (a32[:, :, 1] << 8) | a32[:, :, 2]
        white_key, bpp = 0xFFFFFF, 3
    else:
        keys, white_key, bpp = arr, 255, 1

    out = bytearray(page_header(width, height, dpi, color))
    y = 0
    while y < height:
        repeat = 0
        while (repeat < 255 and y + repeat + 1 < height
               and np.array_equal(keys[y + repeat + 1], keys[y])):
            repeat += 1
        out.append(repeat)
        out += _encode_line(arr[y], keys[y], white_key, bpp)
        y += repeat + 1
    return bytes(out)


def encode_document(pages: Iterable[Image.Image], page_count: int, dpi: int, color: bool,
                    progress: Callable[[int], None] | None = None) -> bytes:
    out = bytearray(file_header(page_count))
    for i, page in enumerate(pages, 1):
        out += encode_page(page, dpi, color)
        if progress:
            progress(i)
    return bytes(out)


def decode_document(data: bytes) -> list[Image.Image]:
    """Decode URF back to images (used by the tests)."""
    if data[:8] != b"UNIRAST\x00":
        raise ValueError("not a URF file")
    count = struct.unpack(">I", data[8:12])[0]
    i, pages = 12, []
    for _ in range(count):
        bits, cs, _d, _q, _u0, _u1, w, h, _dpi, _u2, _u3 = struct.unpack(">BBBBIIIIIII", data[i:i + 32])
        i += 32
        bpp = bits // 8
        white = b"\xff" * bpp
        rows: list[bytes] = []
        while len(rows) < h:
            repeat = data[i]
            i += 1
            line = bytearray()
            while len(line) < w * bpp:
                c = data[i]
                i += 1
                if c == 0x80:
                    line += white * (w - len(line) // bpp)
                elif c < 0x80:
                    line += data[i:i + bpp] * (c + 1)
                    i += bpp
                else:
                    n = 257 - c
                    line += data[i:i + n * bpp]
                    i += n * bpp
            rows.extend([bytes(line)] * (repeat + 1))
        mode = "RGB" if bpp == 3 else "L"
        pages.append(Image.frombytes(mode, (w, h), b"".join(rows[:h])))
    return pages
