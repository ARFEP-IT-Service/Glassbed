"""Release packaging helpers used by build.ps1.

  python tools/package.py zip <source folder> <target.zip>   portable ZIP (folder contents at the top level)
  python tools/package.py sha256 <file> [<file> ...]           write <file>.sha256 next to each file
"""
from __future__ import annotations

import hashlib
import sys
import zipfile
from pathlib import Path


def make_zip(src: Path, target: Path) -> None:
    files = sorted(p for p in src.rglob("*") if p.is_file())
    target.unlink(missing_ok=True)
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for p in files:
            z.write(p, p.relative_to(src).as_posix())
    with zipfile.ZipFile(target) as z:
        if z.testzip() is not None or len(z.namelist()) != len(files):
            sys.exit(f"ZIP check failed: {target}")
    print(f"{target.name}: {len(files)} files, {target.stat().st_size / 1024 / 1024:.1f} MB")


def write_sha256(path: Path) -> str:
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    Path(f"{path}.sha256").write_text(f"{digest}  {path.name}\n", encoding="ascii", newline="\n")
    print(f"{digest}  {path.name}")
    return digest


def main(argv: list[str]) -> None:
    if len(argv) >= 3 and argv[0] == "zip":
        make_zip(Path(argv[1]), Path(argv[2]))
    elif len(argv) >= 2 and argv[0] == "sha256":
        for name in argv[1:]:
            write_sha256(Path(name))
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv[1:])
