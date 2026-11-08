"""Collect the full license texts for the Windows build into licenses/.

Writes one file per bundled third-party component (version, license, full license text,
taken from the installed packages). THIRD_PARTY_NOTICES.md is the hand-written summary.
Run after changing dependencies:  python tools/third_party_notices.py
"""
from __future__ import annotations

import os
import platform
import re
import sys
from importlib import metadata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LICENSES = Path(__file__).resolve().parent / "licenses"
OUT_DIR = ROOT / "licenses"


def dist_files(name: str, extra_names: tuple[str, ...] = ()) -> list[tuple[str, str]]:
    """License-like files shipped in a distribution's metadata: (relative name, text)."""
    dist = metadata.distribution(name)
    out = []
    for f in dist.files or []:
        rel = str(f).replace("\\", "/")
        if "/licenses/" in rel or any(k in f.name.upper() for k in ("LICENSE", "COPYING", "NOTICE") + extra_names):
            if rel.endswith((".py", ".pyc", "RECORD")):
                continue
            text = Path(f.locate()).read_text(encoding="utf-8", errors="replace").strip()
            label = rel.split("/licenses/", 1)[-1] if "/licenses/" in rel else f.name
            out.append((label, text))
    return out


def version(name: str) -> str:
    return metadata.version(name)


def block(title: str, text: str) -> str:
    return f"<details>\n<summary>{title}</summary>\n\n```text\n{text}\n```\n\n</details>\n"


COMPONENTS = []


def component(name, ver, license_, url, texts, note=""):
    COMPONENTS.append(dict(name=name, version=ver, license=license_, url=url, texts=texts, note=note))


py_license = (Path(sys.base_prefix) / "LICENSE.txt").read_text(encoding="utf-8", errors="replace").strip()
component("Python", platform.python_version(), "PSF-2.0 (with the third-party licenses listed in it)",
          "https://www.python.org/",
          [("LICENSE.txt", py_license)],
          "The Python runtime (`python3*.dll`, standard library) is bundled. Its license file also covers "
          "further components of the Windows build of Python, among them libffi (`libffi-8.dll`).")

import ssl  # noqa: E402

component("OpenSSL", ssl.OPENSSL_VERSION.split()[1], "Apache-2.0", "https://www.openssl.org/",
          [("Apache License 2.0", (LICENSES / "Apache-2.0.txt").read_text(encoding="utf-8").strip())],
          "Bundled with the Python runtime as `libssl-3*.dll` and `libcrypto-3*.dll`.")

qt_ver = version("PySide6")
component("Qt for Python (PySide6, shiboken6) and the Qt 6 libraries", qt_ver,
          "LGPL-3.0-only (Glassbed uses Qt under the LGPL; Qt is also available under GPL and commercial terms)",
          "https://www.qt.io/qt-for-python",
          [("GNU Lesser General Public License v3.0", (LICENSES / "LGPL-3.0.txt").read_text(encoding="utf-8").strip()),
           ("GNU General Public License v3.0 (incorporated by the LGPL-3.0)",
            (LICENSES / "GPL-3.0.txt").read_text(encoding="utf-8").strip())],
          "Qt and PySide6 are shipped unmodified as separate libraries in `_internal/PySide6/` and "
          "`_internal/shiboken6/`; you may replace them with your own compatible build. Source code: "
          "https://code.qt.io/cgit/pyside/pyside-setup.git/ (PySide6) and https://download.qt.io/official_releases/qt/ (Qt). "
          "Qt itself contains further third-party components; their licenses are listed at "
          "https://doc.qt.io/qt-6/licenses-used-in-qt.html")

component("Pillow", version("pillow"), "MIT-CMU (HPND)", "https://python-pillow.org/",
          dist_files("pillow"),
          "The license file also lists the image libraries bundled with Pillow (libjpeg-turbo, libpng, zlib, "
          "FreeType, libtiff, libwebp, OpenJPEG, Little CMS, HarfBuzz, …).")

component("NumPy", version("numpy"), "BSD-3-Clause AND 0BSD AND MIT AND Zlib AND CC0-1.0", "https://numpy.org/",
          dist_files("numpy"),
          "Includes the licenses of the libraries bundled with NumPy (e.g. OpenBLAS).")

component("pypdfium2 and PDFium", version("pypdfium2"),
          "Apache-2.0 OR BSD-3-Clause (pypdfium2); BSD-3-Clause and others (PDFium and its dependencies)",
          "https://github.com/pypdfium2-team/pypdfium2",
          [(label, text) for label, text in dist_files("pypdfium2")
           if not label.startswith("data/") or label.startswith("data/windows_x64/")])

component("python-zeroconf", version("zeroconf"), "LGPL-2.1-or-later",
          "https://github.com/python-zeroconf/python-zeroconf",
          dist_files("zeroconf")
          + [("GNU Lesser General Public License v2.1 – complete official text (gnu.org)",
              (LICENSES / "LGPL-2.1.txt").read_text(encoding="utf-8").strip())],
          "Bundled unmodified. Source code: https://github.com/python-zeroconf/python-zeroconf. "
          "Glassbed's own source code is public, so the program can be rebuilt with a modified zeroconf.")

component("ifaddr", version("ifaddr"), "MIT", "https://github.com/ifaddr/ifaddr", dist_files("ifaddr"))

component("typing_extensions", version("typing_extensions"), "PSF-2.0",
          "https://github.com/python/typing_extensions", dist_files("typing_extensions"))

component("PyInstaller bootloader", version("pyinstaller"),
          "GPL-2.0-or-later with the PyInstaller bootloader exception",
          "https://pyinstaller.org/",
          dist_files("pyinstaller"),
          "`Glassbed.exe` starts through the PyInstaller bootloader. Its license explicitly allows "
          "distributing programs built with it under any license.")

component("NSIS (Nullsoft Scriptable Install System)", os.environ.get("NSIS_VERSION", "3"),
          "zlib/libpng; LZMA compression module: CPL-1.0 with linking exception",
          "https://nsis.sourceforge.io/",
          [("NSIS COPYING (zlib/libpng, bzip2 and CPL-1.0 incl. the LZMA exception)",
            (LICENSES / "NSIS-COPYING.txt").read_text(encoding="utf-8").strip())],
          "Used only to build the installer (Glassbed-<version>-setup.exe). The setup program and the "
          "uninstaller contain the NSIS installer stub and plug-ins (zlib/libpng license) and the LZMA "
          "decompressor, which is distributed under the Common Public License 1.0; thanks to its "
          "linking exception, Glassbed itself is not subject to the CPL. Source code of NSIS, including "
          "the LZMA module: https://sourceforge.net/projects/nsis/files/ . Not part of the portable ZIP.")

component("Microsoft Visual C++ Runtime", "14 (`VCRUNTIME140.dll`, `VCRUNTIME140_1.dll`)",
          "Microsoft Software License Terms (redistributable)",
          "https://learn.microsoft.com/cpp/windows/latest-supported-vc-redist",
          [],
          "Redistributed as part of the Python runtime under Microsoft's redistribution terms: "
          "https://visualstudio.microsoft.com/license-terms/")


def slug(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9]+", "-", name).strip("-")


def main() -> None:
    """Write one text file per component into licenses/ (THIRD_PARTY_NOTICES.md is maintained by hand)."""
    OUT_DIR.mkdir(exist_ok=True)
    for old in OUT_DIR.glob("*.txt"):
        old.unlink()
    for c in COMPONENTS:
        parts = [f"{c['name']} {c['version']}", f"License: {c['license']}", f"Website: {c['url']}"]
        if c["note"]:
            parts.append(f"Note: {c['note']}")
        text = "\n".join(parts) + "\n"
        rule = "=" * 78
        for label, body in c["texts"]:
            text += f"\n{rule}\n{label}\n{rule}\n\n{body}\n"
        (OUT_DIR / f"{slug(c['name'])}.txt").write_text(text, encoding="utf-8")
    print(f"wrote {len(COMPONENTS)} files to {OUT_DIR.name}/")


if __name__ == "__main__":
    main()
