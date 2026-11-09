"""Command line interface: ``glassbed scan`` / ``glassbed print`` / ``glassbed status``."""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .discovery import Device, discover
from .escl import EsclScanner, ScanSettings
from .ipp import IppPrinter
from .printing import print_pages
from .render import MEDIA, open_document, parse_page_range, save_pages

MEDIA_ALIASES = {"a4": "iso_a4_210x297mm", "letter": "na_letter_8.5x11in",
                 "legal": "na_legal_8.5x14in", "a5": "iso_a5_148x210mm"}


def _device(args) -> Device:
    if args.host:
        return Device.from_host(args.host)
    devices = discover(3.0)
    if not devices:
        sys.exit("No device found – pass --host <ip>")
    return devices[0]


def cmd_list(_args) -> None:
    for d in discover(3.0):
        print(f"{d.host:16} {d.name}")


def cmd_status(args) -> None:
    dev = _device(args)
    info = IppPrinter(dev.ipp_uri).get_info()
    print(f"{info.make_and_model} @ {dev.host}: {info.state} {' '.join(info.state_reasons)}")
    for m in info.markers:
        print(f"  {m.name:20} {m.level:4d} %")


def cmd_scan(args) -> None:
    dev = _device(args)
    mode = {"color": "RGB24", "gray": "Grayscale8", "bw": "BlackAndWhite1"}[args.mode]
    settings = ScanSettings(source="Feeder" if args.adf else "Platen", color_mode=mode,
                            resolution=args.dpi, paper=args.paper)
    pages = EsclScanner(dev.escl_url).scan(
        settings, on_page=lambda _img: print("page scanned", file=sys.stderr))
    out = Path(args.output)
    fmt = out.suffix.lstrip(".").lower() or "pdf"
    for p in save_pages([(im, args.dpi) for im in pages], out, fmt, args.quality, args.split):
        print(p)


def cmd_print(args) -> None:
    dev = _device(args)
    refs = [r for f in args.files for r in open_document(f)]
    refs = [refs[i] for i in parse_page_range(args.pages or "", len(refs))]
    media = MEDIA_ALIASES.get(args.media.lower(), args.media)
    if media not in MEDIA:
        sys.exit(f"Unknown media: {args.media}")
    print_pages(dev.ipp_uri, refs, media=media, color=not args.mono, copies=args.copies,
                job_name=Path(args.files[0]).name,
                progress=lambda i, n: print(f"page {i}/{n}", file=sys.stderr))
    print("sent")


def cmd_check(args) -> None:
    from .device_check import build_report, run_check
    if not args.host:
        sys.exit("Pass --host <ip> for the device to check")
    print(build_report(run_check(args.host)))


def main(argv: list[str] | None = None) -> None:
    ap = argparse.ArgumentParser(prog="glassbed", description="Scan and print over the network (eSCL/IPP).")
    ap.add_argument("--host", help="printer IP or host name (default: auto-discover)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list", help="find devices on the network").set_defaults(fn=cmd_list)
    sub.add_parser("status", help="show printer state and toner").set_defaults(fn=cmd_status)
    sub.add_parser("check", help="report what a device offers (ports, Bonjour, IPP, eSCL, WSD)"
                   ).set_defaults(fn=cmd_check)

    s = sub.add_parser("scan", help="scan to a PDF/JPG/PNG file")
    s.add_argument("output")
    s.add_argument("--adf", action="store_true", help="use the document feeder")
    s.add_argument("--mode", choices=["color", "gray", "bw"], default="color")
    s.add_argument("--dpi", type=int, default=300)
    s.add_argument("--paper", default="A4", choices=["A4", "Letter", "A5", "Max"])
    s.add_argument("--quality", default="normal", choices=["high", "normal", "compact"],
                   help="output size/quality (compact = ~150 dpi, smallest files)")
    s.add_argument("--split", type=int, default=0, metavar="N",
                   help="PDF only: 1 = one file per page, N = one file per N pages")
    s.set_defaults(fn=cmd_scan)

    p = sub.add_parser("print", help="print PDFs and images")
    p.add_argument("files", nargs="+")
    p.add_argument("--copies", type=int, default=1)
    p.add_argument("--mono", action="store_true")
    p.add_argument("--media", default="a4")
    p.add_argument("--pages", help="e.g. 1-3,5")
    p.set_defaults(fn=cmd_print)

    args = ap.parse_args(argv)
    args.fn(args)


if __name__ == "__main__":
    main()
