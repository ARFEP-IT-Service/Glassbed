"""Generate glassbed/assets/icon.png and icon.ico (run once, results are committed)."""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "glassbed" / "assets"
S = 1024


def draw() -> Image.Image:
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle((40, 40, S - 40, S - 40), radius=220, fill=(28, 86, 168))
    # paper sheet
    d.rounded_rectangle((300, 150, 724, 560), radius=30, fill=(255, 255, 255))
    for i, w in enumerate((300, 260, 320, 200)):
        y = 230 + i * 70
        d.rounded_rectangle((360, y, 360 + w, y + 30), radius=15, fill=(160, 180, 210))
    # printer body
    d.rounded_rectangle((170, 470, 854, 800), radius=70, fill=(240, 244, 250))
    d.rounded_rectangle((260, 560, 764, 600), radius=20, fill=(28, 86, 168))
    # colour dots (toner)
    for i, c in enumerate(((0, 180, 220), (230, 0, 140), (250, 210, 0), (30, 30, 30))):
        x = 290 + i * 90
        d.ellipse((x, 680, x + 54, 734), fill=c)
    return img


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    img = draw()
    img.resize((256, 256), Image.LANCZOS).save(OUT / "icon.png")
    img.save(OUT / "icon.ico", sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("written to", OUT)


if __name__ == "__main__":
    main()
