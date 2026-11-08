# Builds the Windows release of Glassbed (requires: pip install -e ".[dev]" and NSIS 3):
#   dist/Glassbed/                                the program folder
#   dist/Glassbed-<version>-windows-portable.zip  portable ZIP
#   dist/Glassbed-<version>-setup.exe             per-user installer
#   *.sha256                                      checksums of both
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$version = python -c "import glassbed; print(glassbed.__version__)"
if ($LASTEXITCODE -ne 0 -or -not $version) { throw "could not read the version from glassbed/__init__.py" }

# NSIS compiler: PATH, the usual install locations, then a portable copy under %LOCALAPPDATA%\Programs
$makensis = (Get-Command makensis.exe -ErrorAction SilentlyContinue).Source
if (-not $makensis) {
    $makensis = @("${env:ProgramFiles(x86)}\NSIS\makensis.exe", "$env:ProgramFiles\NSIS\makensis.exe") +
                @(Get-ChildItem "$env:LOCALAPPDATA\Programs\nsis-*\makensis.exe" -ErrorAction SilentlyContinue |
                  Sort-Object FullName -Descending | ForEach-Object FullName) |
                Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
}
if (-not $makensis) { throw "NSIS 3 (makensis.exe) not found - install it from https://nsis.sourceforge.io/" }
$env:NSIS_VERSION = (& $makensis /VERSION).Trim().TrimStart("v")

Write-Host "Building Glassbed $version (NSIS $env:NSIS_VERSION)"

python -m PyInstaller --noconfirm --clean --windowed `
    --name Glassbed `
    --icon glassbed/assets/icon/glassbed.ico `
    --add-data "glassbed/assets;glassbed/assets" `
    --collect-all pypdfium2 `
    --collect-submodules zeroconf `
    --exclude-module tkinter `
    --exclude-module PySide6.QtWebEngineCore `
    --exclude-module PySide6.QtQuick `
    --exclude-module PySide6.QtQml `
    --exclude-module PySide6.Qt3DCore `
    --exclude-module pypdfium2_cli `
    --exclude-module tabulate `
    --exclude-module yaml `
    --exclude-module psutil `
    --exclude-module charset_normalizer `
    --exclude-module win32com `
    --exclude-module pythoncom `
    --exclude-module pywintypes `
    --exclude-module win32pdh `
    launcher.py
if ($LASTEXITCODE -ne 0) { throw "PyInstaller failed" }

# licenses travel with the program
python tools/third_party_notices.py
if ($LASTEXITCODE -ne 0) { throw "license collection failed" }
Copy-Item LICENSE, THIRD_PARTY_NOTICES.md dist/Glassbed/
Copy-Item licenses dist/Glassbed/licenses -Recurse -Force

# >>> SignPath: sign dist/Glassbed/Glassbed.exe here, before it is packaged (not set up yet) <<<

$zip = "dist/Glassbed-$version-windows-portable.zip"
$setup = "dist/Glassbed-$version-setup.exe"
python tools/package.py zip dist/Glassbed $zip
if ($LASTEXITCODE -ne 0) { throw "ZIP packaging failed" }

# /WX: any warning fails the build (a stray line continuation once dropped all files silently)
& $makensis /V2 /WX "/DVERSION=$version" installer\glassbed.nsi
if ($LASTEXITCODE -ne 0) { throw "NSIS failed" }

# >>> SignPath: sign the setup.exe here, before the checksums are written (not set up yet) <<<

python tools/package.py sha256 $zip $setup
if ($LASTEXITCODE -ne 0) { throw "checksum failed" }

Write-Host "Done: $zip, $setup"
