# Third-party notices

Glassbed itself is licensed under the MIT License (see `LICENSE`).
It uses the following third-party software, which remains under its own license.
The Windows release bundles these components; their full license texts are
included in the `licenses/` folder next to `Glassbed.exe`.

| Component | Used for | License |
|---|---|---|
| [Python](https://www.python.org/) | runtime (bundled in the Windows release) | PSF License |
| [PySide6 / Qt for Python](https://www.qt.io/qt-for-python) incl. shiboken6 and Qt libraries | user interface | LGPL-3.0-only (also GPL-2.0/3.0) |
| [Pillow](https://python-pillow.org/) | image processing | MIT-CMU (plus licenses of bundled image libraries) |
| [NumPy](https://numpy.org/) | image processing | BSD-3-Clause (plus 0BSD, MIT, Zlib, CC0-1.0 for bundled parts) |
| [pypdfium2](https://github.com/pypdfium2-team/pypdfium2) and [PDFium](https://pdfium.googlesource.com/pdfium/) | PDF rendering | BSD-3-Clause / Apache-2.0 (plus licenses of PDFium's dependencies) |
| [python-zeroconf](https://github.com/python-zeroconf/python-zeroconf) | printer discovery (mDNS) | LGPL-2.1-or-later |
| [ifaddr](https://github.com/pydron/ifaddr) | network interfaces (used by zeroconf) | MIT |
| [OpenSSL](https://www.openssl.org/) (bundled with Python) | encrypted connections | Apache-2.0 |
| [typing_extensions](https://github.com/python/typing_extensions) | required by the libraries above | PSF-2.0 |
| Microsoft Visual C++ Runtime | Windows runtime (Windows build only) | Microsoft Software License Terms (redistributable) |
| [PyInstaller](https://pyinstaller.org/) bootloader | Windows build only | GPL-2.0-or-later with bootloader exception |

## LGPL components (Qt / PySide6, python-zeroconf)

These libraries are used unmodified. In the Windows release the Qt libraries are
separate files in the program folder and can be replaced by compatible versions.
The complete source code of Glassbed and the build script (`build.ps1`) are
published in this repository, so you can rebuild the application with a modified
version of any LGPL component. Source code of the LGPL components is available at
the links above.

## Trademarks

HP is a trademark of HP Inc. AirPrint and Bonjour are trademarks of Apple Inc.
Microsoft 365 is a trademark of Microsoft Corporation. Glassbed is not affiliated
with or endorsed by HP, Apple or Microsoft.
