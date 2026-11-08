# Builds the Windows release of Glassbed (requires: pip install -e ".[dev]" and Inno Setup 6):
#   dist/Glassbed/                                the program folder
#   dist/Glassbed-<version>-windows-portable.zip  portable ZIP
#   dist/Glassbed-<version>-setup.exe             per-user installer
#   *.sha256                                      checksums of both
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$version = python -c "import glassbed; print(glassbed.__version__)"
if ($LASTEXITCODE -ne 0 -or -not $version) { throw "could not read the version from glassbed/__init__.py" }

# Inno Setup compiler: PATH, then the usual per-user and per-machine locations
$iscc = (Get-Command ISCC.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe",
              "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
              "$env:ProgramFiles\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $iscc) { throw "Inno Setup 6 (ISCC.exe) not found - install it from https://jrsoftware.org/isinfo.php" }
# ISCC.exe carries no version number; Inno Setup's own uninstall entry does (per-user or per-machine)
$innoVersion = Get-ChildItem "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
                             "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
                             "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall" -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.DisplayName -like "Inno Setup*" } |
    Select-Object -ExpandProperty DisplayVersion -First 1
$env:INNO_SETUP_VERSION = if ($innoVersion) { $innoVersion } else { "6" }

Write-Host "Building Glassbed $version (Inno Setup $env:INNO_SETUP_VERSION)"

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

& $iscc /Q "/DAppVersion=$version" installer\glassbed.iss
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }

# >>> SignPath: sign the setup.exe here, before the checksums are written (not set up yet) <<<

python tools/package.py sha256 $zip $setup
if ($LASTEXITCODE -ne 0) { throw "checksum failed" }

Write-Host "Done: $zip, $setup"
