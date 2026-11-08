# Builds dist/Glassbed/Glassbed.exe (Windows). Requires: pip install -e ".[dev]"
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

python -m PyInstaller --noconfirm --clean --windowed `
    --name Glassbed `
    --icon glassbed/assets/icon.ico `
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

# licenses travel with the program
python tools/third_party_notices.py
Copy-Item LICENSE, THIRD_PARTY_NOTICES.md dist/Glassbed/
Copy-Item licenses dist/Glassbed/licenses -Recurse -Force

Write-Host "Done: dist/Glassbed/Glassbed.exe"
