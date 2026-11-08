# Builds the Windows release of Glassbed in a fixed, freshly created environment:
#   Python   exactly the version in .python-version (must be installed; the venv is based on it)
#   packages exactly build-requirements.txt, installed into a new .venv-build on every run
#   NSIS     3.13 from the official ZIP, verified by its SHA-256
# Output:
#   dist/Glassbed/                                the program folder
#   dist/Glassbed-<version>-windows-portable.zip  portable ZIP
#   dist/Glassbed-<version>-setup.exe             per-user installer
#   *.sha256                                      checksums of both
#   build/bundled-components.md                   what PyInstaller bundled, with versions and licenses
$ErrorActionPreference = "Stop"
Set-Location $PSScriptRoot

$NsisVersion = "3.13"
$NsisUrl     = "https://downloads.sourceforge.net/project/nsis/NSIS%203/$NsisVersion/nsis-$NsisVersion.zip"
$NsisSha256  = "ba63dffc4410ee89193e1cb5a41989991bd77c61068da17e3156d136b7b0b3d8"

function Invoke-Checked([string]$what, [scriptblock]$cmd) {
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$what failed (exit code $LASTEXITCODE)" }
}

# ---------------------------------------------------------------- Python
$pyVersion = (Get-Content .python-version -TotalCount 1).Trim()
$minor = ($pyVersion -split "\.")[0..1] -join "."
$basePython = $null
foreach ($candidate in @(@("python"), @("py", "-V:$minor"))) {
    if (-not (Get-Command $candidate[0] -ErrorAction SilentlyContinue)) { continue }
    $args_ = @($candidate | Select-Object -Skip 1)
    $found = & $candidate[0] @args_ -c "import platform, sys; print(platform.python_version(), sys.maxsize > 2**32)" 2>$null
    if ($LASTEXITCODE -eq 0 -and $found -eq "$pyVersion True") { $basePython = $candidate; break }
}
if (-not $basePython) { throw "Python $pyVersion (64-bit) not found - install exactly this version (see .python-version)" }

# never inherit packages or paths from the global environment
$env:PYTHONNOUSERSITE = "1"
Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue

$venv = Join-Path $PSScriptRoot ".venv-build"
if (Test-Path $venv) { Remove-Item $venv -Recurse -Force }
$baseArgs = @($basePython | Select-Object -Skip 1)
Invoke-Checked "creating the build venv" { & $basePython[0] @baseArgs -m venv $venv }
$py = Join-Path $venv "Scripts\python.exe"

$pipPin = (Select-String build-requirements.txt -Pattern "^pip==" | Select-Object -First 1).Line
Invoke-Checked "installing $pipPin" { & $py -m pip install --disable-pip-version-check --no-input --quiet $pipPin }
Invoke-Checked "installing build-requirements.txt" {
    & $py -m pip install --disable-pip-version-check --no-input --quiet --only-binary ":all:" -r build-requirements.txt
}
Invoke-Checked "pip check" { & $py -m pip check --disable-pip-version-check }

# the venv must contain exactly the pinned packages - nothing more, nothing less
function Get-Pins([string[]]$lines) {
    $lines | Where-Object { $_ -match "^[A-Za-z0-9]" } |
        ForEach-Object { ($_ -split "\s*#")[0].Trim() } |
        ForEach-Object { $n, $v = $_ -split "=="; "{0}=={1}" -f ($n.ToLower() -replace "[-_.]+", "-"), $v } |
        Sort-Object
}
$expected = Get-Pins (Get-Content build-requirements.txt)
$installed = Get-Pins (& $py -m pip freeze --all --disable-pip-version-check)
$diff = Compare-Object $expected $installed
if ($diff) {
    $diff | ForEach-Object { Write-Host ("  {0} {1}" -f $_.SideIndicator, $_.InputObject) }
    throw "the build venv does not match build-requirements.txt (<= missing, => extra)"
}

$version = & $py -c "import glassbed; print(glassbed.__version__)"
if ($LASTEXITCODE -ne 0 -or -not $version) { throw "could not read the version from glassbed/__init__.py" }

# ---------------------------------------------------------------- NSIS
$nsisCache = Join-Path $env:LOCALAPPDATA "Glassbed-build"
$nsisZip = Join-Path $nsisCache "nsis-$NsisVersion.zip"
New-Item -ItemType Directory -Force $nsisCache | Out-Null
if (-not (Test-Path $nsisZip) -or (Get-FileHash $nsisZip -Algorithm SHA256).Hash -ne $NsisSha256) {
    Write-Host "Downloading NSIS $NsisVersion"
    Invoke-WebRequest $NsisUrl -OutFile $nsisZip -UserAgent "Wget" -MaximumRedirection 10
}
if ((Get-FileHash $nsisZip -Algorithm SHA256).Hash -ne $NsisSha256) { throw "NSIS ZIP has the wrong SHA-256" }
$nsisDir = Join-Path $PSScriptRoot "build\nsis-$NsisVersion"
if (Test-Path $nsisDir) { Remove-Item $nsisDir -Recurse -Force }
Expand-Archive $nsisZip -DestinationPath (Join-Path $PSScriptRoot "build")
$makensis = Join-Path $nsisDir "makensis.exe"
$nsisFound = (& $makensis /VERSION).Trim()
if ($nsisFound -ne "v$NsisVersion") { throw "expected NSIS v$NsisVersion, got $nsisFound" }

Write-Host "Building Glassbed $version (Python $pyVersion, NSIS $NsisVersion)"

# ---------------------------------------------------------------- tests and program
# PyInstaller resolves DLL dependencies through PATH; with the full PATH it once picked up the
# OpenSSL DLLs of an unrelated program (XAMPP's PHP) for Qt's TLS plugin. Only Windows and the
# build venv are visible from here on, so local builds and the workflow see the same files.
$env:PATH = @((Join-Path $venv "Scripts"), "$env:SystemRoot\System32", $env:SystemRoot,
              "$env:SystemRoot\System32\Wbem", "$env:SystemRoot\System32\WindowsPowerShell\v1.0") -join ";"

Invoke-Checked "tests" { & $py -m pytest -q }

Invoke-Checked "PyInstaller" {
    & $py -m PyInstaller --noconfirm --clean --windowed `
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
        launcher.py
}

# licenses of exactly what PyInstaller bundled; stops on anything without a license entry
Invoke-Checked "license collection" {
    & $py tools/third_party_notices.py --toc build/Glassbed/Analysis-00.toc --nsis-version $NsisVersion
}
Copy-Item LICENSE, THIRD_PARTY_NOTICES.md dist/Glassbed/
Copy-Item licenses dist/Glassbed/licenses -Recurse -Force

# >>> SignPath: sign dist/Glassbed/Glassbed.exe here, before it is packaged (not set up yet) <<<

$zip = "dist/Glassbed-$version-windows-portable.zip"
$setup = "dist/Glassbed-$version-setup.exe"
Invoke-Checked "ZIP packaging" { & $py tools/package.py zip dist/Glassbed $zip }

# /WX: any warning fails the build (a stray line continuation once dropped all files silently)
Invoke-Checked "NSIS" { & $makensis /V2 /WX "/DVERSION=$version" installer\glassbed.nsi }

# >>> SignPath: sign the setup.exe here, before the checksums are written (not set up yet) <<<

Invoke-Checked "checksum" { & $py tools/package.py sha256 $zip $setup }

Write-Host "Done: $zip, $setup"
