"""Writes the URF fixtures for test/urf_test.dart with the Windows app's encoder.

Run from the repository root:  .venv-build/Scripts/python.exe mobile/test/fixtures/urf_fixture.py
The pixel pattern is mirrored in urf_test.dart (patternPixel) – keep both in sync.
"""
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path.cwd()))
from glassbed import urf  # noqa: E402

OUT = Path(__file__).resolve().parent


def pattern_pixel(x: int, y: int, c: int, seed: int) -> int:
    """Deterministic test pattern: white lines, long runs, noise, text-like runs, edges."""
    band = (y // 3) % 8
    if band == 0:
        return 255                                  # white (repeat + 0x80)
    if band == 1:
        return (5 + c + seed) & 0xFF                # one long run (> 128)
    if band == 2:                                   # noise
        v = (x * 2654435761 + y * 40503 + c * 977 + seed * 7919) & 0xFFFFFFFF
        return (v >> 13) & 0xFF
    if band == 3:                                   # dark last pixel only
        return 0 if x == WIDTH - 1 else 255
    if band == 4:                                   # text-like runs + short literals, white tail
        if x >= 400:
            return 255
        if 200 <= x < 206:
            return (x * 5 + c + seed) & 0xFF
        if x % 37 == 0:
            return 128
        return 0 if (x // 8 + seed) % 3 == 0 else 255
    if band == 5:                                   # 130 literals, then runs of 10
        if x < 130:
            return (x * 3 + c + seed) & 0xFF
        return ((x // 10) * 17 + c * 40 + seed) & 0xFF
    if band == 6:                                   # gradient: all literals, > 128 wide
        return (x + y + c * 60) & 0xFF
    return 255 if x < 150 else (y * 9 + c) & 0xFF   # white head, run tail


WIDTH = 600


def make(height: int, color: bool, seed: int) -> Image.Image:
    channels = 3 if color else 1
    data = bytearray()
    for y in range(height):
        for x in range(WIDTH):
            for c in range(channels):
                data.append(pattern_pixel(x, y, c, seed))
    return Image.frombytes("RGB" if color else "L", (WIDTH, height), bytes(data))


def main() -> None:
    color_pages = [make(48, True, 0), make(48, True, 1)]
    (OUT / "urf_color.urf").write_bytes(urf.encode_document(color_pages, 2, 300, True))
    # Tall grey page: more than 256 identical white lines in a row (repeat byte cap).
    grey = make(48, False, 2)
    tall = Image.new("L", (WIDTH, 600), 255)
    tall.paste(grey, (0, 0))
    tall.paste(grey, (0, 552))
    (OUT / "urf_gray.urf").write_bytes(urf.encode_document([tall], 1, 600, False))


if __name__ == "__main__":
    main()
