"""Offline tests for the protocol and rendering code (no printer needed)."""
import struct

import numpy as np
import pytest
from PIL import Image, ImageDraw

from glassbed import escl, ipp, urf
from glassbed.render import (PageRef, media_pixels, parse_page_range, prepare_page,
                            render_for_print, save_pages)


# -- URF ------------------------------------------------------------------
def _text_page(color=True):
    img = Image.new("RGB" if color else "L", (600, 800), "white")
    d = ImageDraw.Draw(img)
    for y in range(40, 760, 30):
        d.text((40, y), "Glassbed test line 0123456789", fill="black")
    d.rectangle((100, 500, 400, 700), fill=(200, 30, 60) if color else 90)
    return img


@pytest.mark.parametrize("color", [True, False])
def test_urf_roundtrip_text(color):
    img = _text_page(color)
    data = urf.encode_document([img], 1, 300, color)
    out = urf.decode_document(data)[0]
    assert out.tobytes() == img.convert("RGB" if color else "L").tobytes()


def test_urf_roundtrip_noise_and_edges():
    rng = np.random.default_rng(1)
    arr = rng.integers(0, 256, size=(50, 300, 3), dtype=np.uint8)
    arr[10:20] = 255                     # white lines (repeat + 0x80)
    arr[30, 299] = 0                     # dark last pixel
    arr[40, :] = (5, 6, 7)               # long run > 128
    img = Image.fromarray(arr)
    data = urf.encode_document([img, img], 2, 300, True)
    pages = urf.decode_document(data)
    assert len(pages) == 2 and all(p.tobytes() == img.tobytes() for p in pages)


def test_urf_headers():
    data = urf.encode_document([Image.new("L", (8, 4), "white")], 1, 300, False)
    assert data[:8] == b"UNIRAST\x00"
    assert struct.unpack(">I", data[8:12])[0] == 1
    bpp, cs, duplex, quality, _, _, w, h, dpi, _, _ = struct.unpack(">BBBBIIIIIII", data[12:44])
    assert (bpp, cs, duplex, quality, w, h, dpi) == (8, 0, 1, 4, 8, 4, 300)
    # 4 identical white lines -> one line with repeat=3 and "rest is white"
    assert data[44:] == b"\x03\x80"


# -- IPP ------------------------------------------------------------------
def test_ipp_request_roundtrip():
    req = ipp.encode_request(ipp.PRINT_JOB, "ipp://x/ipp/print",
                             op_attrs=[(ipp.TAG_MIME, "document-format", "image/urf")],
                             job_attrs=[(ipp.TAG_INTEGER, "copies", 3),
                                        (ipp.TAG_KEYWORD, "media", "iso_a4_210x297mm")],
                             request_id=7)
    assert req[:8] == struct.pack(">BBHI", 2, 0, ipp.PRINT_JOB, 7)
    status, attrs = ipp.decode_response(req)  # same wire format
    assert attrs["copies"] == [3]
    assert attrs["document-format"] == ["image/urf"]
    assert attrs["printer-uri"] == ["ipp://x/ipp/print"]


def test_ipp_multivalue():
    body = (struct.pack(">BBHI", 2, 0, 0, 1) + b"\x04"
            + b"\x44" + struct.pack(">H", 5) + b"sides" + struct.pack(">H", 9) + b"one-sided"
            + b"\x44" + struct.pack(">H", 0) + struct.pack(">H", 3) + b"two"
            + b"\x03")
    _, attrs = ipp.decode_response(body)
    assert attrs["sides"] == ["one-sided", "two"]


# -- eSCL -----------------------------------------------------------------
CAPS = b"""<?xml version="1.0"?>
<scan:ScannerCapabilities xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm"
  xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03">
<pwg:Version>2.63</pwg:Version><pwg:MakeAndModel>Test MFP</pwg:MakeAndModel>
<scan:Platen><scan:PlatenInputCaps><scan:MaxWidth>2550</scan:MaxWidth><scan:MaxHeight>3507</scan:MaxHeight>
<scan:SettingProfiles><scan:SettingProfile><scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode>
<scan:ColorMode>Grayscale8</scan:ColorMode></scan:ColorModes><scan:SupportedResolutions><scan:DiscreteResolutions>
<scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
<scan:DiscreteResolution><scan:XResolution>100</scan:XResolution><scan:YResolution>100</scan:YResolution></scan:DiscreteResolution>
</scan:DiscreteResolutions></scan:SupportedResolutions></scan:SettingProfile></scan:SettingProfiles>
</scan:PlatenInputCaps></scan:Platen></scan:ScannerCapabilities>"""


def test_escl_caps_and_settings():
    caps = escl.parse_capabilities(CAPS)
    assert caps.make_and_model == "Test MFP"
    assert list(caps.sources) == ["Platen"]
    assert caps.sources["Platen"].resolutions == [100, 300]
    xml = escl.build_scan_settings(escl.ScanSettings(color_mode="BlackAndWhite1", paper="A4"), caps).decode()
    assert "<scan:ColorMode>Grayscale8</scan:ColorMode>" in xml  # B/W is thresholded locally
    assert "<pwg:Width>2480</pwg:Width>" in xml


# -- rendering ------------------------------------------------------------
def test_page_range():
    assert parse_page_range("", 4) == [0, 1, 2, 3]
    assert parse_page_range("1-2, 4", 5) == [0, 1, 3]
    assert parse_page_range("3-", 5) == [2, 3, 4]
    with pytest.raises(ValueError):
        parse_page_range("0", 3)


def test_scan_copy_is_actual_size():
    scan = Image.new("RGB", (826, 1169), "black")       # A4 at 100 dpi
    page = render_for_print(PageRef(image=scan, dpi=100), "iso_a4_210x297mm", color=False)
    assert page.size == media_pixels("iso_a4_210x297mm") == (2480, 3508)
    assert page.getpixel((10, 10)) == 0                   # covers the page top-left


def test_save_pdf(tmp_path):
    pages = [(_text_page(), 300), (_text_page(False).convert("1"), 300)]
    out = save_pages(pages, tmp_path / "x.pdf", "pdf")
    assert out == [tmp_path / "x.pdf"] and out[0].read_bytes()[:5] == b"%PDF-"
    assert len(save_pages(pages, tmp_path / "y.png", "png")) == 2


def test_save_split(tmp_path):
    pages = [(_text_page(), 300)] * 5
    each = save_pages(pages, tmp_path / "a.pdf", "pdf", split=1)
    assert [p.name for p in each] == [f"a_{i:02d}.pdf" for i in range(1, 6)]
    pairs = save_pages(pages, tmp_path / "b.pdf", "pdf", split=2)
    assert len(pairs) == 3 and all(p.exists() for p in pairs)


def test_compact_is_smaller(tmp_path):
    rng = np.random.default_rng(0)
    photo = Image.fromarray(rng.integers(0, 255, (1200, 900, 3), np.uint8))
    high = save_pages([(photo, 300)], tmp_path / "h.pdf", "pdf", "high")[0].stat().st_size
    small = save_pages([(photo, 300)], tmp_path / "c.pdf", "pdf", "compact")[0].stat().st_size
    assert small < high / 4


def test_compact_turns_grey_pages_grey():
    page, dpi = prepare_page(_text_page(False).convert("RGB"), 300, "compact")
    assert page.mode == "L" and dpi == 150
    colour = Image.new("RGB", (300, 400), (200, 30, 60))
    assert prepare_page(colour, 300, "compact")[0].mode == "RGB"


# -- page edits -----------------------------------------------------------
def test_edits_crop_rotate_roundtrip():
    from glassbed.edit import Edits, apply, rotate_crop
    img = Image.new("RGB", (400, 200), "white")
    img.paste((255, 0, 0), (0, 0, 100, 100))          # red square top-left
    e = Edits(crop=(0, 0, 0.25, 0.5))
    assert apply(img, e).size == (100, 100)
    assert apply(img, e).getpixel((50, 50)) == (255, 0, 0)
    # the crop follows a quarter turn: the red square is still what we keep
    turned = e.rotated(90)
    out = apply(img, turned)
    assert out.size == (100, 100) and out.getpixel((50, 50)) == (255, 0, 0)
    assert rotate_crop((0.1, 0.2, 0.3, 0.4), 360) == (0.1, 0.2, 0.3, 0.4)


def test_content_box_finds_receipt():
    from glassbed.edit import content_box
    page = Image.new("L", (1000, 1400), 250)
    page.paste(30, (300, 200, 600, 900))              # a receipt on the glass
    l, t, r, b = content_box(page, margin=0)
    assert abs(l - 0.3) < 0.02 and abs(t - 200 / 1400) < 0.02
    assert abs(r - 0.6) < 0.02 and abs(b - 900 / 1400) < 0.02


def test_edits_keep_bw_pages_bw():
    from glassbed.edit import Edits, apply
    bw = Image.new("1", (100, 100), 1)
    assert apply(bw, Edits(angle=3, brightness=1.3)).mode == "1"


def test_redaction_follows_content_and_burns_in():
    from glassbed.edit import Edits, apply, from_frame, to_frame
    img = Image.new("RGB", (600, 400), "white")
    img.paste((255, 0, 0), (100, 80, 160, 120))         # "IBAN" – must disappear
    box = ((0.15, 0.18), (0.29, 0.18), (0.29, 0.32), (0.15, 0.32))
    for e in (Edits(redactions=((box, "black"),)),
              Edits(rotate=90, angle=4.0, redactions=((box, "black"),)),
              Edits(rotate=270, angle=-7.5, crop=(0.05, 0.05, 0.9, 0.95), contrast=0.6,
                    redactions=((box, "black"),))):
        out = np.asarray(apply(img, e).convert("RGB")).astype(int)
        red = (out[:, :, 0] > 150) & (out[:, :, 1] < 100) & (out[:, :, 2] < 100)
        assert not red.any(), e
        assert (out.sum(axis=2) == 0).any()                # pure black survives tone changes
    # drawing on the edited view and mapping back is lossless
    e = Edits(rotate=90, angle=3.0)
    pts = [(0.2, 0.3), (0.7, 0.9)]
    back = to_frame(from_frame(pts, (600, 400), e), (600, 400), e)
    assert all(abs(a - b) < 1e-9 for p, q in zip(pts, back) for a, b in zip(p, q))


def test_whiteout_on_bw_page():
    from glassbed.edit import Edits, apply
    bw = Image.new("1", (100, 100), 0)                    # all black
    out = apply(bw, Edits(redactions=((((0.1, 0.1), (0.5, 0.1), (0.5, 0.5), (0.1, 0.5)), "white"),)))
    assert out.mode == "1" and out.getpixel((30, 30)) == 255 and out.getpixel((80, 80)) == 0


def test_blur_destroys_text_detail():
    from glassbed.edit import Edits, apply
    rng = np.random.default_rng(3)
    img = Image.new("RGB", (800, 400), "white")
    d = ImageDraw.Draw(img)
    for x in range(60, 740, 22):                       # "characters": sharp random glyphs
        d.rectangle((x, 160, x + 4 + int(rng.integers(0, 12)), 200), fill=(0, 0, 0))
    box = ((0.05, 0.35), (0.95, 0.35), (0.95, 0.55), (0.05, 0.55))
    out = np.asarray(apply(img, Edits(redactions=((box, "blur"),))).convert("L")).astype(int)
    src = np.asarray(img.convert("L")).astype(int)
    region = (slice(150, 210), slice(60, 740))
    edges_before = np.abs(np.diff(src[region], axis=1)).mean()
    edges_after = np.abs(np.diff(out[region], axis=1)).mean()
    assert edges_after < edges_before * 0.05           # no sharp character edges left
    assert (out[:100] == src[:100]).all()              # outside the box untouched


def test_redacted_pdf_has_no_hidden_layer(tmp_path):
    """The saved PDF holds exactly one image per page and no text – and the embedded image
    itself (not just what a viewer renders) contains none of the covered content."""
    import pypdfium2 as pdfium
    import pypdfium2.raw as pdfium_c
    from glassbed.edit import Edits, apply

    page = Image.new("RGB", (1240, 1754), "white")
    page.paste((220, 20, 20), (120, 600, 1000, 640))          # the secret line
    box = ((0.08, 0.33), (0.83, 0.33), (0.83, 0.375), (0.08, 0.375))
    for e in (Edits(redactions=((box, "black"),)),
              Edits(rotate=90, angle=3.0, brightness=1.2, redactions=((box, "black"),))):
        out = save_pages([(apply(page, e), 150)], tmp_path / "r.pdf", "pdf", "high")[0]
        pdf = pdfium.PdfDocument(str(out))
        try:
            assert len(pdf) == 1
            p = pdf[0]
            objs = list(p.get_objects())
            kinds = [o.type for o in objs]
            assert kinds == [pdfium_c.FPDF_PAGEOBJ_IMAGE], kinds   # one image, nothing else
            assert p.get_textpage().count_chars() == 0               # no text layer
            embedded = np.asarray(objs[0].get_bitmap(render=False).to_pil().convert("RGB")).astype(int)
            red = (embedded[:, :, 0] > 150) & (embedded[:, :, 1] < 100) & (embedded[:, :, 2] < 100)
            assert not red.any()                                     # the stored pixels themselves
        finally:
            pdf.close()
