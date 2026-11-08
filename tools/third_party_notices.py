"""Collect the license texts for exactly what the Windows build contains.

Reads PyInstaller's analysis (build/Glassbed/Analysis-00.toc), assigns every bundled file to its
origin (an installed distribution via its RECORD, the Python runtime, or Glassbed itself) and
writes one file per bundled component into licenses/. It stops with an error when

  * a bundled file cannot be assigned to an origin,
  * a bundled distribution has no entry in COMPONENTS below,
  * a bundled Python runtime binary is not covered by the Python license texts, or
  * THIRD_PARTY_NOTICES.md lists a component that is not bundled, or misses one that is.

Components that are not bundled are never written. Run with the build venv's Python after
PyInstaller (build.ps1 does this):

    python tools/third_party_notices.py --toc build/Glassbed/Analysis-00.toc --nsis-version 3.13
"""
from __future__ import annotations

import argparse
import ast
import re
import ssl
import sys
from collections import defaultdict
from importlib import metadata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LICENSES = Path(__file__).resolve().parent / "licenses"
OUT_DIR = ROOT / "licenses"
NOTICES = ROOT / "THIRD_PARTY_NOTICES.md"
BASE = Path(sys.base_prefix).resolve()      # the Python installation the build venv is based on
SITE = Path(sys.prefix).resolve() / "Lib" / "site-packages"


def norm(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def text(path: Path) -> str:
    return path.read_text(encoding="utf-8", errors="replace").strip()


def dist_license_files(name: str) -> list[tuple[str, str]]:
    """License-like files shipped in a distribution's metadata: (label, text)."""
    out = []
    for f in metadata.distribution(name).files or []:
        rel = str(f).replace("\\", "/")
        if "/licenses/" in rel or any(k in f.name.upper() for k in ("LICENSE", "COPYING", "NOTICE")):
            if rel.endswith((".py", ".pyc", "RECORD")):
                continue
            label = rel.split("/licenses/", 1)[-1] if "/licenses/" in rel else f.name
            out.append((label, text(Path(f.locate()))))
    if not out:
        sys.exit(f"ERROR: {name} has no license file in its metadata")
    return out


# --------------------------------------------------------------------------- catalog
# Every component that may be bundled. "dists" are the distributions whose files belong to it,
# "row" is how its row in THIRD_PARTY_NOTICES.md starts. Texts are only read for bundled ones.

def _python_texts():
    return [("LICENSE.txt (Python " + sys.version.split()[0] + ")", text(BASE / "LICENSE.txt")),
            ("History and License – licenses of the incorporated software (Python 3.14 documentation)",
             text(LICENSES / "Python-3.14-history-and-license.txt")),
            ("Further libraries built into the Windows build of Python 3.14",
             text(LICENSES / "Python-3.14-additional-libraries.txt"))]


COMPONENTS = {
    "python": dict(
        name="Python", version=sys.version.split()[0], row="[Python]",
        license="PSF-2.0 (with the licenses of the software incorporated into Python)",
        url="https://www.python.org/", texts=_python_texts,
        note="The Python runtime (`python3*.dll`, standard library, extension modules) is bundled. "
             "Python's Windows build contains further libraries, among them expat, libffi, "
             "zlib-ng, libmpdec, mimalloc, HACL*, bzip2, XZ (liblzma) and Zstandard; their "
             "licenses follow below."),
    "openssl": dict(
        name="OpenSSL", version=ssl.OPENSSL_VERSION.split()[1], row="[OpenSSL]",
        license="Apache-2.0", url="https://www.openssl.org/",
        texts=lambda: [("Apache License 2.0", text(LICENSES / "Apache-2.0.txt"))],
        note="Bundled with the Python runtime as `libssl-3*.dll` and `libcrypto-3*.dll`."),
    "msvc": dict(
        name="Microsoft Visual C++ Runtime", version="14 (`VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`)",
        row="Microsoft Visual C++ Runtime",
        license="Microsoft Software License Terms (redistributable)",
        url="https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist", texts=lambda: [],
        note="Redistributed as part of the Python runtime under Microsoft's redistribution terms: "
             "https://visualstudio.microsoft.com/license-terms/"),
    "qt": dict(
        name="Qt for Python (PySide6, shiboken6) and the Qt 6 libraries", dist="PySide6",
        dists=("PySide6", "PySide6_Essentials", "PySide6_Addons", "PySide6_Pdf", "PySide6_WebEngine",
               "shiboken6"), row="[PySide6",
        license="LGPL-3.0-only (Glassbed uses Qt under the LGPL; Qt is also available under GPL and "
                "commercial terms)",
        url="https://www.qt.io/qt-for-python",
        texts=lambda: [("GNU Lesser General Public License v3.0", text(LICENSES / "LGPL-3.0.txt")),
                       ("GNU General Public License v3.0 (incorporated by the LGPL-3.0)",
                        text(LICENSES / "GPL-3.0.txt"))],
        note="Qt and PySide6 are shipped unmodified as separate libraries in `_internal/PySide6/` and "
             "`_internal/shiboken6/`; you may replace them with your own compatible build. Source code: "
             "https://code.qt.io/cgit/pyside/pyside-setup.git/ (PySide6) and "
             "https://download.qt.io/official_releases/qt/ (Qt). Qt itself contains further third-party "
             "components; their licenses are listed at https://doc.qt.io/qt-6/licenses-used-in-qt.html"),
    "pillow": dict(
        name="Pillow", dist="pillow", row="[Pillow]", license="MIT-CMU (HPND)",
        url="https://python-pillow.org/", texts=lambda: dist_license_files("pillow"),
        note="The license file also lists the image libraries bundled with Pillow (libjpeg-turbo, "
             "libpng, zlib, FreeType, libtiff, libwebp, OpenJPEG, Little CMS, HarfBuzz, …)."),
    "numpy": dict(
        name="NumPy", dist="numpy", row="[NumPy]",
        license="BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0", url="https://numpy.org/",
        texts=lambda: dist_license_files("numpy"),
        note="Includes the licenses of the libraries bundled with NumPy (e.g. OpenBLAS)."),
    "pypdfium2": dict(
        name="pypdfium2 and PDFium", dist="pypdfium2", row="[pypdfium2]",
        license="Apache-2.0 OR BSD-3-Clause (pypdfium2); BSD-3-Clause and others (PDFium and its "
                "dependencies)",
        url="https://github.com/pypdfium2-team/pypdfium2",
        texts=lambda: [(label, body) for label, body in dist_license_files("pypdfium2")
                       if not label.startswith("data/") or label.startswith("data/windows_x64/")]),
    "zeroconf": dict(
        name="python-zeroconf", dist="zeroconf", row="[python-zeroconf]", license="LGPL-2.1-or-later",
        url="https://github.com/python-zeroconf/python-zeroconf",
        texts=lambda: dist_license_files("zeroconf") + [
            ("GNU Lesser General Public License v2.1 – complete official text (gnu.org)",
             text(LICENSES / "LGPL-2.1.txt"))],
        note="Bundled unmodified. Source code: https://github.com/python-zeroconf/python-zeroconf. "
             "Glassbed's own source code is public, so the program can be rebuilt with a modified "
             "zeroconf."),
    "ifaddr": dict(
        name="ifaddr", dist="ifaddr", row="[ifaddr]", license="MIT",
        url="https://github.com/ifaddr/ifaddr", texts=lambda: dist_license_files("ifaddr")),
    "pyinstaller": dict(
        name="PyInstaller bootloader", dist="pyinstaller",
        dists=("pyinstaller", "pyinstaller-hooks-contrib"), row="[PyInstaller]",
        license="GPL-2.0-or-later with the PyInstaller bootloader exception", url="https://pyinstaller.org/",
        texts=lambda: dist_license_files("pyinstaller"),
        note="`Glassbed.exe` starts through the PyInstaller bootloader, and PyInstaller's runtime hooks "
             "are bundled. Its license explicitly allows distributing programs built with it under "
             "any license."),
    "nsis": dict(
        name="NSIS (Nullsoft Scriptable Install System)", row="[NSIS]",
        license="zlib/libpng; LZMA compression module: CPL-1.0 with linking exception",
        url="https://nsis.sourceforge.io/",
        texts=lambda: [("NSIS COPYING (zlib/libpng, bzip2 and CPL-1.0 incl. the LZMA exception)",
                        text(LICENSES / "NSIS-COPYING.txt"))],
        note="Used only to build the installer (Glassbed-<version>-setup.exe). The setup program and "
             "the uninstaller contain the NSIS installer stub and plug-ins (zlib/libpng license) and "
             "the LZMA decompressor, which is distributed under the Common Public License 1.0; thanks "
             "to its linking exception, Glassbed itself is not subject to the CPL. Source code of "
             "NSIS, including the LZMA module: https://sourceforge.net/projects/nsis/files/ . Not "
             "part of the portable ZIP."),
}

# Binaries of the Python runtime: which component covers them, and which words must appear in
# that component's license texts (so a new Python build with a new library is noticed).
PY_BINARIES = {
    "python3.dll": ("python", ()),
    "python314.dll": ("python", ("PYTHON SOFTWARE FOUNDATION LICENSE", "zlib-ng", "HACL*", "mimalloc",
                                 "SipHash", "dtoa")),
    "vcruntime140.dll": ("msvc", ()),
    "vcruntime140_1.dll": ("msvc", ()),
    "libcrypto-3.dll": ("openssl", ()), "libcrypto-3-x64.dll": ("openssl", ()),
    "libssl-3.dll": ("openssl", ()), "libssl-3-x64.dll": ("openssl", ()),
    "libffi-8.dll": ("python", ("libffi",)),
    "_ctypes.pyd": ("python", ("libffi",)),
    "_ssl.pyd": ("python", ()), "_hashlib.pyd": ("python", ()),
    "_bz2.pyd": ("python", ("bzip2",)),
    "_lzma.pyd": ("python", ("XZ Utils",)),
    "_zstd.pyd": ("python", ("Zstandard",)),
    "_decimal.pyd": ("python", ("libmpdec",)),
    "pyexpat.pyd": ("python", ("expat",)),
    "_elementtree.pyd": ("python", ("expat",)),
    "unicodedata.pyd": ("python", ("Unicode Character Database",)),
    "_asyncio.pyd": ("python", ()), "_multiprocessing.pyd": ("python", ()),
    "_overlapped.pyd": ("python", ()), "_queue.pyd": ("python", ()), "_socket.pyd": ("python", ()),
    "_uuid.pyd": ("python", ()), "_wmi.pyd": ("python", ()), "select.pyd": ("python", ()),
}


# --------------------------------------------------------------------------- analysis
def toc_entries(node):
    """All (dest, source, typecode) tuples anywhere in the analysis TOC."""
    if isinstance(node, (list, tuple)):
        if len(node) == 3 and all(isinstance(x, str) for x in node) and node[2].isupper():
            yield node
        else:
            for item in node:
                yield from toc_entries(item)


def record_owners() -> dict[Path, str]:
    """Absolute file path → distribution name, from the RECORD of every installed distribution."""
    owners = {}
    for dist in metadata.distributions():
        for f in dist.files or []:
            owners[Path(f.locate()).resolve()] = dist.metadata["Name"]
    return owners


def classify(toc: Path):
    """Map every bundled source file to a component key; abort on anything unknown."""
    entries = list(toc_entries(ast.literal_eval(toc.read_text(encoding="utf-8"))))
    owners = record_owners()
    dist_to_key = {}
    for key, c in COMPONENTS.items():
        for d in c.get("dists", (c["dist"],) if "dist" in c else ()):
            dist_to_key[norm(d)] = key
    found = defaultdict(set)            # component key → bundled files (dest names)
    dists = defaultdict(set)            # component key → distributions seen
    errors = []
    for dest, src, typecode in entries:
        if not src or typecode in ("OPTION",) or src == "-":
            continue
        path = Path(src).resolve()
        if not path.exists():
            errors.append(f"bundled file does not exist: {src}")
            continue
        if path.is_relative_to(ROOT / "glassbed") or path == ROOT / "launcher.py":
            continue                    # Glassbed itself
        if path.is_relative_to(toc.resolve().parent):
            continue                    # generated by PyInstaller; base_library.zip modules are listed separately
        if path.is_relative_to(SITE):
            owner = owners.get(path)
            if owner is None:
                errors.append(f"no distribution owns {path.relative_to(SITE)} (bundled as {dest})")
                continue
            key = dist_to_key.get(norm(owner))
            if key is None:
                errors.append(f"distribution {owner} is bundled ({dest}) but has no license entry")
                continue
            found[key].add(dest)
            dists[key].add(f"{owner}=={metadata.version(owner)}")
        elif path.is_relative_to(BASE):
            if path.suffix.lower() in (".dll", ".pyd"):
                spec = PY_BINARIES.get(path.name.lower())
                if spec is None:
                    errors.append(f"Python runtime binary {path.name} is not in PY_BINARIES – check its "
                                  f"license and add it")
                    continue
                found[spec[0]].add(dest)
            else:
                found["python"].add(dest)
        else:
            errors.append(f"bundled file outside the build environment: {src}")
    if errors:
        sys.exit("ERROR: license collection failed\n  " + "\n  ".join(sorted(set(errors))))
    found["pyinstaller"].add("Glassbed.exe (bootloader)")
    return found, dists


def check_python_coverage(found) -> None:
    corpus = "\n".join(body for _, body in COMPONENTS["python"]["texts"]())
    missing = []
    for dest in sorted(set().union(*found.values())):
        name = Path(dest).name.lower()
        for word in PY_BINARIES.get(name, (None, ()))[1]:
            if word.lower() not in corpus.lower():
                missing.append(f"{name}: '{word}'")
    if missing:
        sys.exit("ERROR: Python license texts do not cover: " + ", ".join(missing))


def check_notices(keys: list[str]) -> None:
    rows = [line for line in NOTICES.read_text(encoding="utf-8").splitlines()
            if line.startswith("| ") and not line.startswith(("| Component", "|---"))]
    problems = []
    for key in keys:
        if not any(r[2:].startswith(COMPONENTS[key]["row"]) for r in rows):
            problems.append(f"bundled, but no row in THIRD_PARTY_NOTICES.md: {COMPONENTS[key]['name']}")
    for r in rows:
        if not any(r[2:].startswith(COMPONENTS[k]["row"]) for k in keys):
            problems.append(f"listed in THIRD_PARTY_NOTICES.md, but not bundled: {r[:60]}…")
    if problems:
        sys.exit("ERROR: THIRD_PARTY_NOTICES.md does not match the build\n  " + "\n  ".join(problems))


def slug(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--toc", type=Path, default=ROOT / "build" / "Glassbed" / "Analysis-00.toc")
    ap.add_argument("--nsis-version", help="NSIS version used for the installer (omit: no installer)")
    ap.add_argument("--list", type=Path, default=ROOT / "build" / "bundled-components.md",
                    help="where to write the table of bundled components")
    args = ap.parse_args()

    found, dists = classify(args.toc)
    check_python_coverage(found)
    if args.nsis_version:
        COMPONENTS["nsis"]["version"] = args.nsis_version
        found["nsis"].add("setup.exe / uninstall.exe (installer stub)")
    keys = [k for k in COMPONENTS if found.get(k)]
    check_notices(keys)

    OUT_DIR.mkdir(exist_ok=True)
    for old in OUT_DIR.glob("*.txt"):
        old.unlink()
    rule = "=" * 78
    table = ["| Component | Version | Distributions (pinned) | License | Files |", "|---|---|---|---|---|"]
    for key in keys:
        c = COMPONENTS[key]
        ver = c.get("version") or metadata.version(c["dist"])
        parts = [f"{c['name']} {ver}", f"License: {c['license']}", f"Website: {c['url']}"]
        if c.get("note"):
            parts.append(f"Note: {c['note']}")
        body = "\n".join(parts) + "\n"
        for label, t in c["texts"]():
            body += f"\n{rule}\n{label}\n{rule}\n\n{t}\n"
        (OUT_DIR / f"{slug(c['name'])}.txt").write_text(body, encoding="utf-8", newline="\n")
        table.append(f"| {c['name']} | {ver} | {', '.join(sorted(dists.get(key, ()))) or '–'} | "
                     f"{c['license']} | {len(found[key])} |")
    args.list.parent.mkdir(parents=True, exist_ok=True)
    args.list.write_text("\n".join(table) + "\n", encoding="utf-8", newline="\n")
    print("\n".join(table))
    print(f"wrote {len(keys)} files to {OUT_DIR.name}/ and {args.list.name}")


if __name__ == "__main__":
    main()
