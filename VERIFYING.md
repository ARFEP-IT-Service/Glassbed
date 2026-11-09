# Verifying downloads

The Windows files of Glassbed (installer and portable ZIP) are currently **not code-signed**,
so Windows SmartScreen may show a warning.

Every file is built on GitHub from the source code in this public repository by the
[Release build](.github/workflows/release-build.yml) workflow. Its SHA-256 checksum is listed in
the release notes and published next to it as a `.sha256` file.

Compare the checksum of your download with the published one – they must be identical.

**Windows** (Command Prompt or PowerShell):

```
certutil -hashfile Glassbed-<version>-setup.exe SHA256
```

**Linux / macOS:**

```
sha256sum Glassbed-<version>-setup.exe
```

On macOS versions without `sha256sum`, use `shasum -a 256` instead.

With the `.sha256` file in the same folder, `sha256sum -c Glassbed-<version>-setup.exe.sha256`
checks it automatically. Use the same commands for `Glassbed-<version>-windows-portable.zip`.

## Android APKs

Each APK (`Glassbed-android-<version>-<processor>.apk`) has its SHA-256 in the release notes and in
a `.sha256` file; check it with the commands above. Before installing you can also check that the
APK is signed with Glassbed's release key – with the Android SDK's build tools:

```
apksigner verify --print-certs Glassbed-android-<version>-arm64-v8a.apk
```

The certificate SHA-256 digest must be

```
CE:27:CF:44:5F:13:47:06:89:68:E7:FF:DF:73:8A:37:92:7C:DE:AF:89:E5:56:44:AB:89:63:3D:2E:43:0F:DC
```

(Android itself refuses an update that is signed with a different key.)

## Updates from within the app

From version 0.3.0 on, Glassbed can tell you about new versions, but the app itself does not
download anything: *Update* opens the download (or the release page) in your browser. Before you
start the downloaded setup, compare its SHA-256 checksum with the one in the release notes (or in
the `.sha256` file) using the commands above.
